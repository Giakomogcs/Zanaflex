-- =============================================
-- Zanaflex (clean) — 002: Document categories (+ Drive folder)
-- Consolida: 006 + 017 do conjunto original.
--
-- - Tabela zanaflex_document_categories com drive_folder_id desde o início
-- - RLS: SELECT liberado para membros zanaflex; escrita via RPC admin
-- - RPCs: list / create / update / delete + helper zanaflex_category_drive_folder
-- Rode APÓS 001_users_and_admin.sql
-- =============================================

-- =======  UP  ========

CREATE TABLE IF NOT EXISTS zanaflex_document_categories (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code            TEXT NOT NULL UNIQUE,
  name            TEXT NOT NULL,
  description     TEXT,
  drive_folder_id TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_zanaflex_cat_code ON zanaflex_document_categories(code);

ALTER TABLE zanaflex_document_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS zanaflex_cat_select ON zanaflex_document_categories;
CREATE POLICY zanaflex_cat_select ON zanaflex_document_categories
  FOR SELECT TO authenticated
  USING (zanaflex_is_member());

-- ---------- list ----------
CREATE OR REPLACE FUNCTION zanaflex_list_categories()
RETURNS TABLE(
  id              UUID,
  code            TEXT,
  name            TEXT,
  description     TEXT,
  drive_folder_id TEXT,
  created_at      TIMESTAMPTZ
)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
  IF NOT zanaflex_is_member() THEN
    RAISE EXCEPTION 'Acesso negado: usuário não pertence à Zanaflex.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT c.id, c.code, c.name, c.description, c.drive_folder_id, c.created_at
      FROM zanaflex_document_categories c
     ORDER BY c.code;
END;
$$;

-- ---------- create (admin-only) ----------
CREATE OR REPLACE FUNCTION zanaflex_admin_create_category(
  p_code            TEXT,
  p_name            TEXT,
  p_description     TEXT DEFAULT NULL,
  p_drive_folder_id TEXT DEFAULT NULL
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
  INSERT INTO zanaflex_document_categories(code, name, description, drive_folder_id)
  VALUES (
    UPPER(TRIM(p_code)),
    p_name,
    p_description,
    NULLIF(TRIM(p_drive_folder_id), '')
  )
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

-- ---------- update (admin-only) ----------
CREATE OR REPLACE FUNCTION zanaflex_admin_update_category(
  p_id              UUID,
  p_code            TEXT,
  p_name            TEXT,
  p_description     TEXT DEFAULT NULL,
  p_drive_folder_id TEXT DEFAULT NULL
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
  UPDATE zanaflex_document_categories
     SET code            = UPPER(TRIM(p_code)),
         name            = p_name,
         description     = p_description,
         drive_folder_id = NULLIF(TRIM(p_drive_folder_id), ''),
         updated_at      = NOW()
   WHERE id = p_id;
END;
$$;

-- ---------- delete (admin-only) ----------
CREATE OR REPLACE FUNCTION zanaflex_admin_delete_category(p_id UUID)
RETURNS VOID
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT zanaflex_is_admin() THEN
    RAISE EXCEPTION 'Acesso negado: apenas administradores.' USING ERRCODE = '42501';
  END IF;
  DELETE FROM zanaflex_document_categories WHERE id = p_id;
END;
$$;

-- ---------- drive folder lookup (usado pelo n8n) ----------
CREATE OR REPLACE FUNCTION zanaflex_category_drive_folder(
  p_category_id   UUID DEFAULT NULL,
  p_category_code TEXT DEFAULT NULL
)
RETURNS TEXT
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_folder TEXT;
BEGIN
  IF p_category_id IS NOT NULL THEN
    SELECT drive_folder_id INTO v_folder
      FROM zanaflex_document_categories
     WHERE id = p_category_id;
  ELSIF p_category_code IS NOT NULL THEN
    SELECT drive_folder_id INTO v_folder
      FROM zanaflex_document_categories
     WHERE code = UPPER(TRIM(p_category_code));
  END IF;
  RETURN v_folder;
END;
$$;

GRANT SELECT  ON zanaflex_document_categories                                            TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_list_categories()                                     TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_create_category(TEXT, TEXT, TEXT, TEXT)         TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_delete_category(UUID)                           TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_category_drive_folder(UUID, TEXT)                     TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_category_drive_folder(UUID, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_admin_delete_category(UUID);
-- DROP FUNCTION IF EXISTS zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_admin_create_category(TEXT, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_list_categories();
-- DROP POLICY  IF EXISTS zanaflex_cat_select ON zanaflex_document_categories;
-- DROP TABLE   IF EXISTS zanaflex_document_categories;
-- NOTIFY pgrst, 'reload schema';
