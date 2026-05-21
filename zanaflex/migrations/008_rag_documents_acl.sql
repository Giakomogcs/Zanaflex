-- =============================================
-- Zanaflex — 008: RAG schema + ACL-aware match
-- Creates the pgvector-backed tables mirroring the Aspiramaq pattern,
-- plus a category_id FK on document_metadata so we can JOIN ACL.
-- Provides zanaflex_match_documents() that:
--   - filters chunks by allowed categories (admin → all)
--   - returns (id, content, metadata, similarity)
-- Run AFTER 007_teams_and_acl.sql
-- =============================================

-- =======  UP  ========

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 1) Per-file metadata
--    file_id is the stable external id (Drive id, hash, etc.) used by the
--    RAG pipeline. Chunks in zanaflex_documents.metadata link back via
--    metadata->>'file_id'.
-- ============================================================
CREATE TABLE IF NOT EXISTS zanaflex_document_metadata (
  file_id      TEXT PRIMARY KEY,
  title        TEXT,
  code         TEXT,                -- canonical doc code (e.g. IT-18.05)
  url          TEXT,                -- link to open the original file
  source       TEXT,                -- "drive" | "upload" | "webhook"
  mime_type    TEXT,
  schema       JSONB,               -- column schema for tabular sources
  category_id  UUID REFERENCES zanaflex_document_categories(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_meta_category ON zanaflex_document_metadata(category_id);
CREATE INDEX IF NOT EXISTS idx_zanaflex_meta_code     ON zanaflex_document_metadata(code);

-- ============================================================
-- 2) Tabular rows (for csv/xlsx ingestions)
-- ============================================================
CREATE TABLE IF NOT EXISTS zanaflex_document_rows (
  id          BIGSERIAL PRIMARY KEY,
  dataset_id  TEXT NOT NULL REFERENCES zanaflex_document_metadata(file_id) ON DELETE CASCADE,
  row_data    JSONB NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_rows_dataset ON zanaflex_document_rows(dataset_id);

-- ============================================================
-- 3) Vector chunks (LangChain Supabase vector store shape)
-- ============================================================
CREATE TABLE IF NOT EXISTS zanaflex_documents (
  id        BIGSERIAL PRIMARY KEY,
  content   TEXT,
  metadata  JSONB,                  -- must include file_id
  embedding vector(1536)
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_docs_file_id
  ON zanaflex_documents ( (metadata->>'file_id') );

-- HNSW index for fast cosine search (Postgres 16+ / pgvector >= 0.5)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'zanaflex_documents_embedding_hnsw'
  ) THEN
    EXECUTE 'CREATE INDEX zanaflex_documents_embedding_hnsw
             ON zanaflex_documents
             USING hnsw (embedding vector_cosine_ops)';
  END IF;
EXCEPTION WHEN OTHERS THEN
  -- HNSW not available (older pgvector) → fall back to ivfflat
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'zanaflex_documents_embedding_ivfflat'
  ) THEN
    EXECUTE 'CREATE INDEX zanaflex_documents_embedding_ivfflat
             ON zanaflex_documents
             USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)';
  END IF;
END $$;

-- ============================================================
-- 4) ACL-aware similarity search
--    Signature compatible with LangChain Supabase vector store nodes
--    (query_embedding vector, match_count int, filter jsonb).
--    Filter is a jsonb subset match against metadata (e.g. {"file_id":"..."}).
-- ============================================================
DROP FUNCTION IF EXISTS zanaflex_match_documents(vector, int, jsonb);
CREATE OR REPLACE FUNCTION zanaflex_match_documents(
  query_embedding vector(1536),
  match_count     int     DEFAULT 6,
  filter          jsonb   DEFAULT '{}'::jsonb
)
RETURNS TABLE(
  id         bigint,
  content    text,
  metadata   jsonb,
  similarity float
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  is_admin_caller BOOLEAN := zanaflex_is_admin();
BEGIN
  -- A non-admin caller must be a Zanaflex member; otherwise return nothing.
  IF NOT is_admin_caller AND NOT zanaflex_is_member() THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.content,
      d.metadata,
      1 - (d.embedding <=> query_embedding) AS similarity
    FROM zanaflex_documents d
    LEFT JOIN zanaflex_document_metadata m
           ON m.file_id = d.metadata->>'file_id'
    WHERE d.metadata @> filter
      -- ACL: admin sees everything; everyone else only sees chunks whose
      -- metadata file_id resolves to a category they're allowed to see.
      -- Chunks whose metadata has no file_id, or whose file_id has no
      -- category_id, are hidden for non-admins.
      AND (
        is_admin_caller
        OR m.category_id IN (SELECT zanaflex_user_allowed_categories())
      )
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

GRANT SELECT ON zanaflex_document_metadata TO authenticated;
GRANT SELECT ON zanaflex_document_rows     TO authenticated;
GRANT SELECT ON zanaflex_documents         TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_match_documents(vector, int, jsonb) TO authenticated;

-- Service-role n8n agent will use the service key; no extra grant needed
-- because service_role bypasses RLS, but we keep the function SECURITY DEFINER
-- so a regular authenticated caller (e.g. the frontend during testing) also gets ACL.

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_match_documents(vector, int, jsonb);
-- DROP INDEX IF EXISTS zanaflex_documents_embedding_hnsw;
-- DROP INDEX IF EXISTS zanaflex_documents_embedding_ivfflat;
-- DROP TABLE IF EXISTS zanaflex_documents;
-- DROP TABLE IF EXISTS zanaflex_document_rows;
-- DROP TABLE IF EXISTS zanaflex_document_metadata;
-- NOTIFY pgrst, 'reload schema';
