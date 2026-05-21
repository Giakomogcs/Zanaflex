-- =============================================
-- Zanaflex — 005: Prevent self-deletion
-- An admin cannot delete their own user via RPC,
-- avoiding accidental lock-out.
-- Run AFTER 004_add_company_name.sql
-- =============================================

-- =======  UP  ========

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
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'Você não pode excluir sua própria conta.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM auth.users WHERE id = p_user_id;
END;
$$;

GRANT EXECUTE ON FUNCTION zanaflex_admin_delete_user(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- See 003 for the version without the self-delete guard.
