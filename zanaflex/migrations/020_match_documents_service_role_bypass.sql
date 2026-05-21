-- ============================================================
-- 020_match_documents_service_role_bypass.sql
-- Allows service_role (used by n8n) to query zanaflex_match_documents
-- without a per-call ACL filter. ACL for end-users is still enforced by:
--   1) the Front-end + webhook ("Prepare Input" + "Get Allowed Categories")
--      → the agent's List Documents / Get File Contents tools pass
--        allowed_ids explicitly in their SQL.
--   2) authenticated callers (NOT service_role) still go through the
--        auth.uid()-based admin/member checks (migration 014).
--   3) callers that DO pass `allowed_category_ids` in the filter still
--        get filtered by that list (override path, unchanged).
--
-- Problem this fixes
-- ------------------
-- n8n's Supabase Vector Store retrieve-as-tool calls
--   zanaflex_match_documents(query_embedding, match_count, '{}')
-- with the service_role key. service_role has no auth.uid(), so the
-- previous logic returned NOTHING — the agent then said "não encontrei".
--
-- Safe to re-run. Drops/recreates the function with the same signature
-- AND keeps the metadata enrichment introduced in migration 019.
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
  is_service_role    BOOLEAN := (
    COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role'
    OR COALESCE(auth.role(), '') = 'service_role'
  );
  effective_filter   JSONB   := COALESCE(filter, '{}'::jsonb);
BEGIN
  -- Detect filter-based override (used by n8n when it DOES pass ACL)
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

  -- Trust boundary: if there is no override and the caller is neither
  -- admin nor member nor service_role, return nothing.
  IF NOT has_override
     AND NOT is_admin_caller
     AND NOT is_member_caller
     AND NOT is_service_role THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.content,
      -- Enrich chunk metadata with canonical per-file fields (url, title,
      -- code, category_id, source, mime_type) — needed so the agent can
      -- render the source link as [Abrir documento](url).
      (
        jsonb_strip_nulls(jsonb_build_object(
          'url',         m.url,
          'title',       m.title,
          'code',        m.code,
          'category_id', m.category_id,
          'source',      m.source,
          'mime_type',   m.mime_type
        )) || COALESCE(d.metadata, '{}'::jsonb)
      ) AS metadata,
      1 - (d.embedding <=> query_embedding) AS similarity
    FROM zanaflex_documents d
    LEFT JOIN zanaflex_document_metadata m
           ON m.file_id = d.metadata->>'file_id'
    WHERE d.metadata @> effective_filter
      AND (
        -- 1) Filter-based override (override_ids may be NULL when wildcard)
        (has_override AND (
            override_bypass
            OR (override_ids IS NOT NULL AND m.category_id = ANY(override_ids))
        ))
        -- 2) service_role with no override → trust n8n trust boundary
        OR (NOT has_override AND is_service_role)
        -- 3) auth.uid()-based admin
        OR (NOT has_override AND NOT is_service_role AND is_admin_caller)
        -- 4) auth.uid()-based member ACL
        OR (NOT has_override AND NOT is_service_role AND is_member_caller
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
-- Re-run 019_match_documents_enrich_url.sql to restore the strict version.
