-- =============================================
-- Zanaflex — 012: service-role aware match
-- The n8n agent connects to Postgres via service credentials,
-- so auth.uid() is NULL and the ACL in zanaflex_match_documents()
-- can't be evaluated. This variant accepts the caller's user_id
-- explicitly and applies the same team→category ACL.
--
-- Use from n8n: pass the authenticated user_id from the chat payload.
-- The function NEVER trusts the user_id to bypass ACL — it just
-- evaluates ACL *as that user*. Admin still sees everything.
--
-- Run AFTER 011_seed_it_category.sql
-- =============================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION zanaflex_user_allowed_categories_for(p_user_id UUID)
RETURNS SETOF UUID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  is_adm BOOLEAN;
  is_mem BOOLEAN;
BEGIN
  SELECT
    (raw_user_meta_data->>'role' = 'admin'
     AND raw_user_meta_data->>'company_name' = 'zanaflex'),
    (raw_user_meta_data->>'company_name' = 'zanaflex')
  INTO is_adm, is_mem
  FROM auth.users
  WHERE id = p_user_id;

  IF COALESCE(is_adm, false) THEN
    RETURN QUERY SELECT id FROM zanaflex_document_categories;
    RETURN;
  END IF;

  IF NOT COALESCE(is_mem, false) THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT DISTINCT tca.category_id
      FROM zanaflex_team_category_access tca
      JOIN zanaflex_team_members tm ON tm.team_id = tca.team_id
     WHERE tm.user_id = p_user_id;
END;
$$;

DROP FUNCTION IF EXISTS zanaflex_match_documents_for_user(UUID, vector, int, jsonb);
CREATE OR REPLACE FUNCTION zanaflex_match_documents_for_user(
  p_user_id       UUID,
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
SET search_path = auth, public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  is_adm BOOLEAN;
BEGIN
  SELECT (raw_user_meta_data->>'role' = 'admin'
          AND raw_user_meta_data->>'company_name' = 'zanaflex')
    INTO is_adm
    FROM auth.users
   WHERE id = p_user_id;

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
      AND (
        COALESCE(is_adm, false)
        OR m.category_id IN (SELECT zanaflex_user_allowed_categories_for(p_user_id))
      )
    ORDER BY d.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

GRANT EXECUTE ON FUNCTION zanaflex_user_allowed_categories_for(UUID)                TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION zanaflex_match_documents_for_user(UUID, vector, int, jsonb) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_match_documents_for_user(UUID, vector, int, jsonb);
-- DROP FUNCTION IF EXISTS zanaflex_user_allowed_categories_for(UUID);
-- NOTIFY pgrst, 'reload schema';
