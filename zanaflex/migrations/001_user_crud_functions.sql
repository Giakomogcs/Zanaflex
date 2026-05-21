-- =============================================
-- Zanaflex — 001: User CRUD Functions
-- Operates directly on auth.users (raw_user_meta_data approach).
-- Mirrors the Sameka pattern, prefix = zanaflex_.
-- =============================================

-- =======  UP  ========

DROP FUNCTION IF EXISTS zanaflex_admin_list_users();

CREATE OR REPLACE FUNCTION zanaflex_admin_list_users()
RETURNS TABLE(
  user_id    UUID,
  email      TEXT,
  full_name  TEXT,
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
    created_at
  FROM auth.users
  ORDER BY created_at DESC;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_confirm_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE auth.users
  SET email_confirmed_at = NOW(),
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_update_user(
  p_user_id   UUID,
  p_full_name TEXT
)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE auth.users
  SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
                           || jsonb_build_object('full_name', p_full_name),
      updated_at = NOW()
  WHERE id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_delete_user(p_user_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = auth, public
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM auth.users WHERE id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION zanaflex_admin_list_users()                 TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_confirm_user(UUID)           TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_user(UUID, TEXT)      TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_delete_user(UUID)            TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- REVOKE EXECUTE ON FUNCTION zanaflex_admin_list_users()              FROM authenticated;
-- REVOKE EXECUTE ON FUNCTION zanaflex_admin_confirm_user(UUID)        FROM authenticated;
-- REVOKE EXECUTE ON FUNCTION zanaflex_admin_update_user(UUID, TEXT)   FROM authenticated;
-- REVOKE EXECUTE ON FUNCTION zanaflex_admin_delete_user(UUID)         FROM authenticated;
--
-- DROP FUNCTION IF EXISTS zanaflex_admin_list_users();
-- DROP FUNCTION IF EXISTS zanaflex_admin_confirm_user(UUID);
-- DROP FUNCTION IF EXISTS zanaflex_admin_update_user(UUID, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_admin_delete_user(UUID);
--
-- NOTIFY pgrst, 'reload schema';
