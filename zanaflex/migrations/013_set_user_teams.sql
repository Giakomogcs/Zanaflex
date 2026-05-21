-- 013_set_user_teams.sql
-- Admin RPC to sync a user's team memberships from a single call.
-- Used by the user form when creating/editing users.

CREATE OR REPLACE FUNCTION zanaflex_admin_set_user_teams(
    p_user_id UUID,
    p_team_ids UUID[]
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT zanaflex_is_admin() THEN
        RAISE EXCEPTION 'Permission denied' USING ERRCODE = '42501';
    END IF;

    -- Remove memberships not in the new list
    DELETE FROM zanaflex_team_members
     WHERE user_id = p_user_id
       AND (p_team_ids IS NULL OR NOT (team_id = ANY(p_team_ids)));

    -- Insert any new memberships (idempotent via ON CONFLICT)
    IF p_team_ids IS NOT NULL THEN
        INSERT INTO zanaflex_team_members (team_id, user_id)
        SELECT unnest(p_team_ids), p_user_id
        ON CONFLICT (team_id, user_id) DO NOTHING;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION zanaflex_admin_set_user_teams(UUID, UUID[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION zanaflex_admin_set_user_teams(UUID, UUID[]) TO authenticated;
