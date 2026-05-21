-- =============================================
-- Zanaflex — 004: company_name filter
-- Isolates Zanaflex users from other tenants sharing the
-- same Supabase project (e.g. sameka, aspiramaq).
-- Stamps raw_user_meta_data.company_name = 'zanaflex'.
-- Run AFTER 003_admin_guards.sql
-- =============================================

-- =======  UP  ========

-- 1) is_admin: also require company_name = 'zanaflex'
CREATE OR REPLACE FUNCTION zanaflex_is_admin()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'role' = 'admin'
            AND raw_user_meta_data->>'company_name' = 'zanaflex'
       FROM auth.users
      WHERE id = auth.uid()),
    false
  );
$$;

-- 1b) Helper: is the caller a Zanaflex user at all (admin OR visualizador)?
CREATE OR REPLACE FUNCTION zanaflex_is_member()
RETURNS BOOLEAN
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT raw_user_meta_data->>'company_name' = 'zanaflex'
       FROM auth.users
      WHERE id = auth.uid()),
    false
  );
$$;

-- 2) list_users: filter by company_name = 'zanaflex'
DROP FUNCTION IF EXISTS zanaflex_admin_list_users();
CREATE OR REPLACE FUNCTION zanaflex_admin_list_users()
RETURNS TABLE(
  user_id      UUID,
  email        TEXT,
  full_name    TEXT,
  role         TEXT,
  company_name TEXT,
  created_at   TIMESTAMPTZ
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
      COALESCE(u.raw_user_meta_data->>'company_name', '')::TEXT AS company_name,
      u.created_at
    FROM auth.users u
    WHERE u.raw_user_meta_data->>'company_name' = 'zanaflex'
    ORDER BY u.created_at DESC;
END;
$$;

-- 3) update_user: always (re-)stamp company_name = 'zanaflex'
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
  new_meta := jsonb_build_object('full_name', p_full_name, 'company_name', 'zanaflex');
  IF p_role IS NOT NULL THEN
    new_meta := new_meta || jsonb_build_object('role', p_role);
  END IF;
  UPDATE auth.users
  SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || new_meta,
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

-- NOTE: There is NO backfill here on purpose — Zanaflex is a fresh tenant.
-- To bootstrap the first admin, run manually after seeding the user:
--   UPDATE auth.users
--   SET raw_user_meta_data = COALESCE(raw_user_meta_data,'{}'::jsonb)
--       || '{"role":"admin","company_name":"zanaflex"}'::jsonb
--   WHERE email = 'admin@zanaflex.com.br';

GRANT EXECUTE ON FUNCTION zanaflex_is_admin()                              TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_is_member()                             TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_list_users()                      TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_user(UUID, TEXT, TEXT)     TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- See 003 for previous signatures (no company_name filter).
