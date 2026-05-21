-- =============================================
-- Zanaflex — 007: Teams + ACL (team→categories, user→teams)
-- Permission model:
--   user ∈ N teams
--   team has access to N document categories
--   user can read documents whose category ∈ union(team.categories for team in user.teams)
--   admin sees everything (bypass)
-- Run AFTER 006_document_categories.sql
-- =============================================

-- =======  UP  ========

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS zanaflex_teams (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS zanaflex_team_members (
  team_id    UUID NOT NULL REFERENCES zanaflex_teams(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL,  -- references auth.users(id) but FK avoided to keep migration self-contained
  added_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (team_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_tm_user ON zanaflex_team_members(user_id);

CREATE TABLE IF NOT EXISTS zanaflex_team_category_access (
  team_id     UUID NOT NULL REFERENCES zanaflex_teams(id)                 ON DELETE CASCADE,
  category_id UUID NOT NULL REFERENCES zanaflex_document_categories(id)   ON DELETE CASCADE,
  granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (team_id, category_id)
);
CREATE INDEX IF NOT EXISTS idx_zanaflex_tca_cat ON zanaflex_team_category_access(category_id);

-- RLS: tables not directly written from clients; reads gated to members
ALTER TABLE zanaflex_teams                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE zanaflex_team_members           ENABLE ROW LEVEL SECURITY;
ALTER TABLE zanaflex_team_category_access   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS zanaflex_teams_select   ON zanaflex_teams;
DROP POLICY IF EXISTS zanaflex_tm_select      ON zanaflex_team_members;
DROP POLICY IF EXISTS zanaflex_tca_select     ON zanaflex_team_category_access;

CREATE POLICY zanaflex_teams_select ON zanaflex_teams
  FOR SELECT TO authenticated USING (zanaflex_is_member());
CREATE POLICY zanaflex_tm_select ON zanaflex_team_members
  FOR SELECT TO authenticated USING (zanaflex_is_member());
CREATE POLICY zanaflex_tca_select ON zanaflex_team_category_access
  FOR SELECT TO authenticated USING (zanaflex_is_member());

-- ============================================================
-- Core helper: which categories can the current user see?
--   - admin → ALL categories
--   - viewer → union of team.categories for each team they belong to
-- Returns set of UUID (category_id).
-- ============================================================
CREATE OR REPLACE FUNCTION zanaflex_user_allowed_categories()
RETURNS SETOF UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF zanaflex_is_admin() THEN
    RETURN QUERY SELECT id FROM zanaflex_document_categories;
    RETURN;
  END IF;

  IF NOT zanaflex_is_member() THEN
    RETURN;  -- no rows
  END IF;

  RETURN QUERY
    SELECT DISTINCT tca.category_id
      FROM zanaflex_team_category_access tca
      JOIN zanaflex_team_members tm ON tm.team_id = tca.team_id
     WHERE tm.user_id = auth.uid();
END;
$$;

-- Convenience: same data as a single jsonb array (handy for n8n nodes)
CREATE OR REPLACE FUNCTION zanaflex_user_allowed_category_codes()
RETURNS JSONB
SECURITY DEFINER
SET search_path = public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    jsonb_agg(c.code ORDER BY c.code),
    '[]'::jsonb
  )
  FROM zanaflex_document_categories c
  WHERE c.id IN (SELECT zanaflex_user_allowed_categories());
$$;

-- ============================================================
-- TEAM CRUD (admin only)
-- ============================================================

CREATE OR REPLACE FUNCTION zanaflex_admin_create_team(
  p_name        TEXT,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  new_id UUID;
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  INSERT INTO zanaflex_teams(name, description) VALUES (TRIM(p_name), p_description)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_update_team(
  p_id          UUID,
  p_name        TEXT,
  p_description TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE zanaflex_teams
     SET name = TRIM(p_name), description = p_description, updated_at = NOW()
   WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_delete_team(p_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM zanaflex_teams WHERE id = p_id;
END;
$$;

-- ============================================================
-- TEAM MEMBERSHIP (admin only)
-- ============================================================

CREATE OR REPLACE FUNCTION zanaflex_admin_set_team_members(
  p_team_id UUID,
  p_user_ids UUID[]
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM zanaflex_team_members WHERE team_id = p_team_id;
  IF p_user_ids IS NOT NULL AND array_length(p_user_ids, 1) > 0 THEN
    INSERT INTO zanaflex_team_members(team_id, user_id)
    SELECT p_team_id, uid FROM unnest(p_user_ids) AS uid
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_set_team_categories(
  p_team_id      UUID,
  p_category_ids UUID[]
)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM zanaflex_team_category_access WHERE team_id = p_team_id;
  IF p_category_ids IS NOT NULL AND array_length(p_category_ids, 1) > 0 THEN
    INSERT INTO zanaflex_team_category_access(team_id, category_id)
    SELECT p_team_id, cid FROM unnest(p_category_ids) AS cid
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

-- ============================================================
-- LIST / READ
-- ============================================================

CREATE OR REPLACE FUNCTION zanaflex_admin_list_teams()
RETURNS TABLE(
  id           UUID,
  name         TEXT,
  description  TEXT,
  member_ids   JSONB,
  category_ids JSONB,
  created_at   TIMESTAMPTZ
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
      t.id,
      t.name,
      t.description,
      COALESCE(
        (SELECT jsonb_agg(tm.user_id) FROM zanaflex_team_members tm WHERE tm.team_id = t.id),
        '[]'::jsonb
      ) AS member_ids,
      COALESCE(
        (SELECT jsonb_agg(tca.category_id) FROM zanaflex_team_category_access tca WHERE tca.team_id = t.id),
        '[]'::jsonb
      ) AS category_ids,
      t.created_at
    FROM zanaflex_teams t
    ORDER BY t.name;
END;
$$;

-- User-facing: which teams am I in?
CREATE OR REPLACE FUNCTION zanaflex_my_teams()
RETURNS TABLE(
  id   UUID,
  name TEXT
)
SECURITY DEFINER
SET search_path = public
LANGUAGE sql
STABLE
AS $$
  SELECT t.id, t.name
    FROM zanaflex_teams t
    JOIN zanaflex_team_members tm ON tm.team_id = t.id
   WHERE tm.user_id = auth.uid()
   ORDER BY t.name;
$$;

GRANT SELECT ON zanaflex_teams                  TO authenticated;
GRANT SELECT ON zanaflex_team_members           TO authenticated;
GRANT SELECT ON zanaflex_team_category_access   TO authenticated;

GRANT EXECUTE ON FUNCTION zanaflex_user_allowed_categories()                    TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_user_allowed_category_codes()                TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_create_team(TEXT, TEXT)                TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_team(UUID, TEXT, TEXT)          TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_delete_team(UUID)                      TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_set_team_members(UUID, UUID[])         TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_set_team_categories(UUID, UUID[])      TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_list_teams()                           TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_my_teams()                                   TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_my_teams();
-- DROP FUNCTION IF EXISTS zanaflex_admin_list_teams();
-- DROP FUNCTION IF EXISTS zanaflex_admin_set_team_categories(UUID, UUID[]);
-- DROP FUNCTION IF EXISTS zanaflex_admin_set_team_members(UUID, UUID[]);
-- DROP FUNCTION IF EXISTS zanaflex_admin_delete_team(UUID);
-- DROP FUNCTION IF EXISTS zanaflex_admin_update_team(UUID, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_admin_create_team(TEXT, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_user_allowed_category_codes();
-- DROP FUNCTION IF EXISTS zanaflex_user_allowed_categories();
-- DROP TABLE IF EXISTS zanaflex_team_category_access;
-- DROP TABLE IF EXISTS zanaflex_team_members;
-- DROP TABLE IF EXISTS zanaflex_teams;
-- NOTIFY pgrst, 'reload schema';
