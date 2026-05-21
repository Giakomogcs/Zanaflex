-- ============================================================
-- 019_match_documents_enrich_url.sql
-- Enriches the metadata returned by zanaflex_match_documents() with
-- the canonical document fields from zanaflex_document_metadata:
--   url, title, code, category_id, source, mime_type
--
-- Motivation
-- ----------
-- The agent (n8n) cites sources using the markdown link
--   - **[CÓDIGO]** Título — [Abrir documento](url)
-- The `url` value must come from each retrieved chunk. Previously, the
-- chunk-level metadata only carried `file_id` / `category_id`, so the
-- LLM had no real URL to fill in and rendered an empty `()` (which the
-- browser resolved against the current page, e.g.
-- `http://127.0.0.1:5501/zanaflex/front-zanaflex.html#`).
--
-- Fix: merge the per-file `zanaflex_document_metadata` row INTO the
-- chunk's `metadata` jsonb at query time. Chunk-level keys win on
-- conflict (preserves any custom metadata stored during indexing).
--
-- Safe to re-run. Drops/recreates the function with the same signature.
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
  override_ids       UUID[];
  has_override       BOOLEAN := FALSE;
  override_bypass    BOOLEAN := FALSE;
  is_admin_caller    BOOLEAN := zanaflex_is_admin();
  is_member_caller   BOOLEAN := zanaflex_is_member();
  effective_filter   JSONB   := COALESCE(filter, '{}'::jsonb);
BEGIN
  -- Detect filter-based override (used by n8n service-role agent calls)
  IF effective_filter ? 'allowed_category_ids' THEN
    has_override := TRUE;

    IF effective_filter->'allowed_category_ids' @> '["*"]'::jsonb THEN
      override_bypass := TRUE;
    ELSE
      SELECT ARRAY(
        SELECT (jsonb_array_elements_text(effective_filter->'allowed_category_ids'))::uuid
      ) INTO override_ids;
    END IF;

    effective_filter := effective_filter - 'allowed_category_ids';
  END IF;

  IF NOT has_override AND NOT is_admin_caller AND NOT is_member_caller THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.content,
      -- Enrich chunk metadata with canonical per-file fields so the agent
      -- can render the source link. Chunk-level keys override file-level
      -- keys on conflict (jsonb concat operator).
      (
        jsonb_build_object(
          'url',         m.url,
          'title',       m.title,
          'code',        m.code,
          'category_id', m.category_id,
          'source',      m.source,
          'mime_type',   m.mime_type
        )
        - ARRAY(
            SELECT k FROM jsonb_object_keys(
              jsonb_build_object(
                'url',         m.url,
                'title',       m.title,
                'code',        m.code,
                'category_id', m.category_id,
                'source',      m.source,
                'mime_type',   m.mime_type
              )
            ) AS k
            WHERE jsonb_build_object(
                    'url',         m.url,
                    'title',       m.title,
                    'code',        m.code,
                    'category_id', m.category_id,
                    'source',      m.source,
                    'mime_type',   m.mime_type
                  ) ->> k IS NULL
          )
      ) || COALESCE(d.metadata, '{}'::jsonb) AS metadata,
      1 - (d.embedding <=> query_embedding) AS similarity
    FROM zanaflex_documents d
    LEFT JOIN zanaflex_document_metadata m
           ON m.file_id = d.metadata->>'file_id'
    WHERE d.metadata @> effective_filter
      AND (
        (has_override AND (
            override_bypass
            OR (override_ids IS NOT NULL AND m.category_id = ANY(override_ids))
        ))
        OR (NOT has_override AND is_admin_caller)
        OR (NOT has_override AND is_member_caller
            AND m.category_id IN (SELECT zanaflex_user_allowed_categories()))
      )
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

GRANT EXECUTE ON FUNCTION zanaflex_match_documents(vector, int, jsonb)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- Re-run 014_match_documents_filter_acl.sql to restore the previous,
-- non-enriched version of zanaflex_match_documents().
