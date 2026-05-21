-- =============================================
-- Zanaflex (clean) — 004: RAG schema + upsert atômico por arquivo
-- Consolida: 008 + 009 do conjunto original (+ trigger updated_at de 016).
--
-- - Extensões pgvector / pgcrypto
-- - Tabelas: zanaflex_document_metadata, zanaflex_document_rows, zanaflex_documents
-- - Índice HNSW (fallback ivfflat) em embedding
-- - RPCs: rag_upsert_metadata, rag_purge_file, admin_rag_delete_file,
--          admin_list_rag_documents, list_rag_documents
-- Rode APÓS 003_teams_and_acl.sql
-- =============================================

-- =======  UP  ========

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- metadata por arquivo ----------
CREATE TABLE IF NOT EXISTS zanaflex_document_metadata (
  file_id      TEXT PRIMARY KEY,
  title        TEXT,
  code         TEXT,
  url          TEXT,
  source       TEXT,
  mime_type    TEXT,
  schema       JSONB,
  category_id  UUID REFERENCES zanaflex_document_categories(id) ON DELETE SET NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_meta_category ON zanaflex_document_metadata(category_id);
CREATE INDEX IF NOT EXISTS idx_zanaflex_meta_code     ON zanaflex_document_metadata(code);

CREATE OR REPLACE FUNCTION zanaflex_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_zanaflex_meta_updated_at ON zanaflex_document_metadata;
CREATE TRIGGER trg_zanaflex_meta_updated_at
  BEFORE UPDATE ON zanaflex_document_metadata
  FOR EACH ROW EXECUTE FUNCTION zanaflex_set_updated_at();

-- ---------- linhas tabulares (csv/xlsx) ----------
CREATE TABLE IF NOT EXISTS zanaflex_document_rows (
  id          BIGSERIAL PRIMARY KEY,
  dataset_id  TEXT NOT NULL REFERENCES zanaflex_document_metadata(file_id) ON DELETE CASCADE,
  row_data    JSONB NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_rows_dataset ON zanaflex_document_rows(dataset_id);

-- ---------- chunks vetoriais (LangChain Supabase vector store) ----------
CREATE TABLE IF NOT EXISTS zanaflex_documents (
  id        BIGSERIAL PRIMARY KEY,
  content   TEXT,
  metadata  JSONB,
  embedding vector(1536)
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_docs_file_id
  ON zanaflex_documents ( (metadata->>'file_id') );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'zanaflex_documents_embedding_hnsw'
  ) THEN
    EXECUTE 'CREATE INDEX zanaflex_documents_embedding_hnsw
             ON zanaflex_documents USING hnsw (embedding vector_cosine_ops)';
  END IF;
EXCEPTION WHEN OTHERS THEN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND indexname = 'zanaflex_documents_embedding_ivfflat'
  ) THEN
    EXECUTE 'CREATE INDEX zanaflex_documents_embedding_ivfflat
             ON zanaflex_documents USING ivfflat (embedding vector_cosine_ops)
             WITH (lists = 100)';
  END IF;
END $$;

-- ---------- upsert atômico ----------
CREATE OR REPLACE FUNCTION zanaflex_rag_upsert_metadata(
  p_file_id       TEXT,
  p_title         TEXT,
  p_code          TEXT  DEFAULT NULL,
  p_url           TEXT  DEFAULT NULL,
  p_source        TEXT  DEFAULT 'webhook',
  p_mime_type     TEXT  DEFAULT NULL,
  p_schema        JSONB DEFAULT NULL,
  p_category_id   UUID  DEFAULT NULL,
  p_category_code TEXT  DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  resolved_cat UUID := p_category_id;
BEGIN
  IF resolved_cat IS NULL AND p_category_code IS NOT NULL THEN
    SELECT id INTO resolved_cat
      FROM zanaflex_document_categories
     WHERE code = UPPER(TRIM(p_category_code))
     LIMIT 1;
  END IF;

  INSERT INTO zanaflex_document_metadata(
    file_id, title, code, url, source, mime_type, schema, category_id, updated_at
  )
  VALUES (p_file_id, p_title, p_code, p_url, p_source, p_mime_type, p_schema, resolved_cat, NOW())
  ON CONFLICT (file_id) DO UPDATE
    SET title       = COALESCE(EXCLUDED.title,       zanaflex_document_metadata.title),
        code        = COALESCE(EXCLUDED.code,        zanaflex_document_metadata.code),
        url         = COALESCE(EXCLUDED.url,         zanaflex_document_metadata.url),
        source      = COALESCE(EXCLUDED.source,      zanaflex_document_metadata.source),
        mime_type   = COALESCE(EXCLUDED.mime_type,   zanaflex_document_metadata.mime_type),
        schema      = COALESCE(EXCLUDED.schema,      zanaflex_document_metadata.schema),
        category_id = COALESCE(EXCLUDED.category_id, zanaflex_document_metadata.category_id),
        updated_at  = NOW();

  RETURN resolved_cat;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_rag_purge_file(p_file_id TEXT)
RETURNS TABLE(deleted_chunks bigint, deleted_rows bigint)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  c1 bigint := 0;
  c2 bigint := 0;
BEGIN
  DELETE FROM zanaflex_documents
   WHERE metadata->>'file_id' = p_file_id;
  GET DIAGNOSTICS c1 = ROW_COUNT;

  DELETE FROM zanaflex_document_rows
   WHERE dataset_id = p_file_id;
  GET DIAGNOSTICS c2 = ROW_COUNT;

  deleted_chunks := c1;
  deleted_rows   := c2;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_rag_delete_file(p_file_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  PERFORM zanaflex_rag_purge_file(p_file_id);
  DELETE FROM zanaflex_document_metadata WHERE file_id = p_file_id;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_list_rag_documents()
RETURNS TABLE(
  file_id        TEXT,
  title          TEXT,
  code           TEXT,
  url            TEXT,
  source         TEXT,
  mime_type      TEXT,
  category_id    UUID,
  category_code  TEXT,
  category_name  TEXT,
  chunk_count    BIGINT,
  created_at     TIMESTAMPTZ,
  updated_at     TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      m.file_id, m.title, m.code, m.url, m.source, m.mime_type,
      m.category_id, c.code, c.name,
      COALESCE((SELECT COUNT(*) FROM zanaflex_documents d WHERE d.metadata->>'file_id' = m.file_id), 0),
      m.created_at, m.updated_at
    FROM zanaflex_document_metadata m
    LEFT JOIN zanaflex_document_categories c ON c.id = m.category_id
    ORDER BY COALESCE(m.code, m.title, m.file_id);
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_list_rag_documents()
RETURNS TABLE(
  file_id        TEXT,
  title          TEXT,
  code           TEXT,
  url            TEXT,
  category_code  TEXT,
  category_name  TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT zanaflex_is_member() THEN
    RAISE EXCEPTION 'Acesso negado.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT m.file_id, m.title, m.code, m.url, c.code, c.name
      FROM zanaflex_document_metadata m
      JOIN zanaflex_document_categories c ON c.id = m.category_id
     WHERE zanaflex_is_admin()
        OR m.category_id IN (SELECT zanaflex_user_allowed_categories())
     ORDER BY COALESCE(m.code, m.title);
END;
$$;

GRANT SELECT  ON zanaflex_document_metadata                                                          TO authenticated;
GRANT SELECT  ON zanaflex_document_rows                                                              TO authenticated;
GRANT SELECT  ON zanaflex_documents                                                                  TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_rag_upsert_metadata(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, UUID, TEXT) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION zanaflex_rag_purge_file(TEXT)                                              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION zanaflex_admin_rag_delete_file(TEXT)                                       TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_list_rag_documents()                                        TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_list_rag_documents()                                              TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_list_rag_documents();
-- DROP FUNCTION IF EXISTS zanaflex_admin_list_rag_documents();
-- DROP FUNCTION IF EXISTS zanaflex_admin_rag_delete_file(TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_rag_purge_file(TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_rag_upsert_metadata(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, UUID, TEXT);
-- DROP INDEX    IF EXISTS zanaflex_documents_embedding_hnsw;
-- DROP INDEX    IF EXISTS zanaflex_documents_embedding_ivfflat;
-- DROP TABLE    IF EXISTS zanaflex_documents;
-- DROP TABLE    IF EXISTS zanaflex_document_rows;
-- DROP TRIGGER  IF EXISTS trg_zanaflex_meta_updated_at ON zanaflex_document_metadata;
-- DROP FUNCTION IF EXISTS zanaflex_set_updated_at();
-- DROP TABLE    IF EXISTS zanaflex_document_metadata;
-- NOTIFY pgrst, 'reload schema';
