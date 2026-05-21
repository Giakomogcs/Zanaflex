-- =============================================
-- Zanaflex — 006: Document categories
-- Top-level taxonomy of document TYPES (e.g. IT, PO, MAN).
-- Each RAG document belongs to exactly ONE category.
-- Teams (007) grant access to N categories.
-- Run AFTER 005_prevent_self_delete.sql
-- =============================================

-- =======  UP  ========

CREATE TABLE IF NOT EXISTS zanaflex_document_categories (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  description TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_zanaflex_cat_code ON zanaflex_document_categories(code);

-- RLS: keep table readable to any zanaflex member; writes go through RPCs.
ALTER TABLE zanaflex_document_categories ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS zanaflex_cat_select ON zanaflex_document_categories;
CREATE POLICY zanaflex_cat_select ON zanaflex_document_categories
  FOR SELECT TO authenticated
  USING (zanaflex_is_member());

-- ============================================================
-- RPCs (admin-only writes; any zanaflex member can list)
-- ============================================================

CREATE OR REPLACE FUNCTION zanaflex_list_categories()
RETURNS TABLE(
  id          UUID,
  code        TEXT,
  name        TEXT,
  description TEXT,
  created_at  TIMESTAMPTZ
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
    SELECT c.id, c.code, c.name, c.description, c.created_at
      FROM zanaflex_document_categories c
     ORDER BY c.code;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_create_category(
  p_code        TEXT,
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
  INSERT INTO zanaflex_document_categories(code, name, description)
  VALUES (UPPER(TRIM(p_code)), p_name, p_description)
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION zanaflex_admin_update_category(
  p_id          UUID,
  p_code        TEXT,
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
  UPDATE zanaflex_document_categories
     SET code        = UPPER(TRIM(p_code)),
         name        = p_name,
         description = p_description,
         updated_at  = NOW()
   WHERE id = p_id;
END;
$$;

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

GRANT SELECT ON zanaflex_document_categories                                TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_list_categories()                        TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_create_category(TEXT, TEXT, TEXT)  TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_delete_category(UUID)              TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_admin_delete_category(UUID);
-- DROP FUNCTION IF EXISTS zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_admin_create_category(TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_list_categories();
-- DROP POLICY IF EXISTS zanaflex_cat_select ON zanaflex_document_categories;
-- DROP TABLE IF EXISTS zanaflex_document_categories;
-- NOTIFY pgrst, 'reload schema';
