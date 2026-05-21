-- =============================================
-- Zanaflex — 003: Admin-only guards
-- Adds zanaflex_is_admin() helper and guards every RPC.
-- Run AFTER 002_add_roles.sql
-- =============================================

-- =======  UP  ========

CREATE OR REPLACE FUNCTION zanaflex_is_admin()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'role'
       FROM auth.users
      WHERE id = auth.uid()) = 'admin',
    false
  );
$$;

-- list_users: admin-only
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
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT
      u.id AS user_id,
      u.email::TEXT,
      COALESCE(u.raw_user_meta_data->>'full_name', '')::TEXT AS full_name,
      COALESCE(u.raw_user_meta_data->>'role', 'visualizador')::TEXT AS role,
      u.created_at
    FROM auth.users u
    ORDER BY u.created_at DESC;
END;
$$;

-- confirm_user: admin-only
CREATE OR REPLACE FUNCTION zanaflex_admin_confirm_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  UPDATE auth.users
  SET email_confirmed_at = NOW(),
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

-- update_user: admin-only
DROP FUNCTION IF EXISTS zanaflex_admin_update_user(UUID, TEXT, TEXT);
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
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
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

-- delete_user: admin-only
CREATE OR REPLACE FUNCTION zanaflex_admin_delete_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM auth.users WHERE id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION zanaflex_is_admin()                              TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_list_users()                      TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_confirm_user(UUID)                TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_user(UUID, TEXT, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_delete_user(UUID)                 TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_is_admin();
-- (and recreate previous signatures without the guard — see 002)
