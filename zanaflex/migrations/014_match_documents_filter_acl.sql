-- ============================================================
-- 014_match_documents_filter_acl.sql
-- Teaches zanaflex_match_documents() to honor an ACL override
-- passed via the filter jsonb: { "allowed_category_ids": [uuid,...] }
--
-- This is the bridge for the n8n Supabase Vector Store node, which calls
-- match_documents(query_embedding, match_count, filter) with NO custom
-- user_id parameter. The agent computes the allowed categories upfront
-- (via zanaflex_user_allowed_categories_for(userId)) and passes them in
-- the filter — service_role from n8n is trusted here.
--
-- Behavior:
--   * If filter has key "allowed_category_ids": use that array as the ACL.
--       - special case: array contains "*"        → bypass ACL (admin)
--       - empty array []                          → return nothing
--   * Else if caller is admin (auth.uid()-based)  → all categories
--   * Else if caller is a Zanaflex member         → their team categories
--   * Else                                        → return nothing
--
-- The standard equality filter still applies on the non-ACL metadata keys
-- (e.g. {"file_id":"..."} continues to work alongside allowed_category_ids).
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

    -- Wildcard: bypass ACL entirely (admin agent context)
    IF effective_filter->'allowed_category_ids' @> '["*"]'::jsonb THEN
      override_bypass := TRUE;
    ELSE
      SELECT ARRAY(
        SELECT (jsonb_array_elements_text(effective_filter->'allowed_category_ids'))::uuid
      ) INTO override_ids;
    END IF;

    -- Strip the ACL key from the filter so the @> match doesn't fail
    effective_filter := effective_filter - 'allowed_category_ids';
  END IF;

  -- If no override and caller is neither admin nor a Zanaflex member → no results
  IF NOT has_override AND NOT is_admin_caller AND NOT is_member_caller THEN
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
    WHERE d.metadata @> effective_filter
      AND (
        -- 1) Filter-based override
        (has_override AND (
            override_bypass
            OR (override_ids IS NOT NULL AND m.category_id = ANY(override_ids))
        ))
        -- 2) auth.uid()-based admin
        OR (NOT has_override AND is_admin_caller)
        -- 3) auth.uid()-based member ACL
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
-- DROP FUNCTION IF EXISTS zanaflex_match_documents(vector, int, jsonb);
-- (then re-run 008 to restore the previous version)
