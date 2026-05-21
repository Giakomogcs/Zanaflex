-- =============================================
-- Zanaflex — 017: Drive folder per category
-- Cada categoria de documento aponta para uma pasta dedicada no Google Drive.
-- Isso permite que o workflow Zanaflex-RAG faça loop por pasta na hora de
-- (re)indexar e que o upload do front coloque o arquivo na pasta certa.
-- Execute APÓS 016_fix_legacy_metadata_schema.sql
-- =============================================

-- =======  UP  ========

-- 1) Coluna drive_folder_id (Google Drive folder ID; NULL = pasta não definida)
ALTER TABLE zanaflex_document_categories
  ADD COLUMN IF NOT EXISTS drive_folder_id TEXT;

-- 2) Substitui RPC de listagem para devolver drive_folder_id
DROP FUNCTION IF EXISTS zanaflex_list_categories();

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

-- 3) Substitui create/update para aceitar drive_folder_id (compatível com chamadas antigas)
DROP FUNCTION IF EXISTS zanaflex_admin_create_category(TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS zanaflex_admin_create_category(TEXT, TEXT, TEXT, TEXT);

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

DROP FUNCTION IF EXISTS zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT, TEXT);

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

-- 4) Helper: resolve drive_folder_id a partir de id ou code (usado pelo n8n).
--    Service role chama isso direto via SQL; sem guard de role para simplificar.
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

-- 5) (Sem seed) — o ID da pasta da categoria IT é configurado via UI
--     (página Categorias) ou por um nó Set/executeQuery do workflow n8n.

-- 6) Grants
GRANT EXECUTE ON FUNCTION zanaflex_list_categories()                                              TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_create_category(TEXT, TEXT, TEXT, TEXT)                  TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT, TEXT)            TO authenticated;
GRANT EXECUTE ON FUNCTION zanaflex_category_drive_folder(UUID, TEXT)                              TO authenticated;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP FUNCTION IF EXISTS zanaflex_category_drive_folder(UUID, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_admin_update_category(UUID, TEXT, TEXT, TEXT, TEXT);
-- DROP FUNCTION IF EXISTS zanaflex_admin_create_category(TEXT, TEXT, TEXT, TEXT);
-- (recriar as versões antigas do 006 se precisar reverter)
-- ALTER TABLE zanaflex_document_categories DROP COLUMN IF EXISTS drive_folder_id;
-- NOTIFY pgrst, 'reload schema';
