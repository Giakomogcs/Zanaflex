-- =============================================
-- Zanaflex — 009: Single-document atomic upsert
-- The RAG webhook calls this BEFORE reinserting fresh chunks for a file_id.
-- It deletes ONLY the chunks/rows belonging to that file_id and (optionally)
-- replaces the metadata row. Everything else in the RAG store is untouched.
-- Run AFTER 008_rag_documents_acl.sql
-- =============================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION zanaflex_rag_upsert_metadata(
  p_file_id      TEXT,
  p_title        TEXT,
  p_code         TEXT       DEFAULT NULL,
  p_url          TEXT       DEFAULT NULL,
  p_source       TEXT       DEFAULT 'webhook',
  p_mime_type    TEXT       DEFAULT NULL,
  p_schema       JSONB      DEFAULT NULL,
  p_category_id  UUID       DEFAULT NULL,
  p_category_code TEXT      DEFAULT NULL   -- convenience: resolve category by code
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

-- Atomic "purge chunks of a single file" used right before re-ingestion.
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

-- Hard delete: removes everything related to a file including metadata.
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

-- Admin listing for the RAG management page (joins category code/name)
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
      m.file_id,
      m.title,
      m.code,
      m.url,
      m.source,
      m.mime_type,
      m.category_id,
      c.code  AS category_code,
      c.name  AS category_name,
      COALESCE((SELECT COUNT(*) FROM zanaflex_documents d WHERE d.metadata->>'file_id' = m.file_id), 0) AS chunk_count,
      m.created_at,
      m.updated_at
    FROM zanaflex_document_metadata m
    LEFT JOIN zanaflex_document_categories c ON c.id = m.category_id
    ORDER BY COALESCE(m.code, m.title, m.file_id);
END;
$$;

-- User-facing list: only docs the caller can see (via team→category ACL)
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

GRANT EXECUTE ON FUNCTION zanaflex_rag_upsert_metadata(
  TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, UUID, TEXT
) TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_rag_purge_file(TEXT)               TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_rag_delete_file(TEXT)        TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_list_rag_documents()         TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_list_rag_documents()               TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_list_rag_documents();
-- DROP FUNCTION IF EXISTS zanaflex_admin_list_rag_documents();
-- DROP FUNCTION IF EXISTS zanaflex_admin_rag_delete_file(TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_rag_purge_file(TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_rag_upsert_metadata(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, JSONB, UUID, TEXT);
-- NOTIFY pgrst, 'reload schema';
