-- =============================================
-- Zanaflex — 002: Add role to user CRUD
-- Default role for new users = 'visualizador'.
-- Run AFTER 001_user_crud_functions.sql
-- =============================================

-- =======  UP  ========

DROP FUNCTION IF EXISTS zanaflex_admin_list_users();
CREATE OR REPLACE FUNCTION zanaflex_admin_list_users()
RETURNS TABLE(
  user_id    UUID,
  email      TEXT,
  full_name  TEXT,
  role       TEXT,
  created_at TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT
    id AS user_id,
    email::TEXT,
    COALESCE(raw_user_meta_data->>'full_name', '')::TEXT AS full_name,
    COALESCE(raw_user_meta_data->>'role', 'visualizador')::TEXT AS role,
    created_at
  FROM auth.users
  ORDER BY created_at DESC;
$$;

DROP FUNCTION IF EXISTS zanaflex_admin_update_user(UUID, TEXT);
CREATE OR REPLACE FUNCTION zanaflex_admin_update_user(
  p_user_id   UUID,
  p_full_name TEXT,
  p_role      TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
DECLARE
  new_meta JSONB;
BEGIN
  new_meta := jsonb_build_object('full_name', p_full_name);
  IF p_role IS NOT NULL THEN
    new_meta := new_meta || jsonb_build_object('role', p_role);
  END IF;
  UPDATE auth.users
  SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || new_meta,
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION zanaflex_admin_list_users()                       TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_user(UUID, TEXT, TEXT)      TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- See 001 for reverse signatures.
