-- =============================================
-- Zanaflex — 016: alinha zanaflex_document_metadata legado
-- Bancos criados pelo node "Webhook Setup" antigo do workflow Zanaflex-RAG
-- ficaram com o schema simplificado (id TEXT PK, sem category_id/code/etc.).
-- Este patch é idempotente e migra para o schema da migration 008.
-- Execute APÓS 008_rag_documents_acl.sql.
-- =============================================

-- =======  UP  ========

-- 1) Adiciona colunas faltantes
ALTER TABLE zanaflex_document_metadata
  ADD COLUMN IF NOT EXISTS code        TEXT,
  ADD COLUMN IF NOT EXISTS source      TEXT,
  ADD COLUMN IF NOT EXISTS mime_type   TEXT,
  ADD COLUMN IF NOT EXISTS category_id UUID,
  ADD COLUMN IF NOT EXISTS updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- 2) Renomeia "id" -> "file_id" se ainda for o nome legado
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'zanaflex_document_metadata'
       AND column_name  = 'id'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'zanaflex_document_metadata'
       AND column_name  = 'file_id'
  ) THEN
    EXECUTE 'ALTER TABLE zanaflex_document_metadata RENAME COLUMN id TO file_id';
  END IF;
END$$;

-- 3) Converte schema TEXT -> JSONB (se ainda estiver como TEXT)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name   = 'zanaflex_document_metadata'
       AND column_name  = 'schema'
       AND data_type    = 'text'
  ) THEN
    EXECUTE $sql$
      ALTER TABLE zanaflex_document_metadata
      ALTER COLUMN schema TYPE JSONB
      USING NULLIF(schema, '')::jsonb
    $sql$;
  END IF;
END$$;

-- 4) FK para categorias (se ainda não existe)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
     WHERE table_schema = 'public'
       AND table_name   = 'zanaflex_document_categories'
  ) AND NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints
     WHERE table_schema = 'public'
       AND table_name   = 'zanaflex_document_metadata'
       AND constraint_name = 'zanaflex_document_metadata_category_id_fkey'
  ) THEN
    EXECUTE '
      ALTER TABLE zanaflex_document_metadata
        ADD CONSTRAINT zanaflex_document_metadata_category_id_fkey
        FOREIGN KEY (category_id)
        REFERENCES zanaflex_document_categories(id)
        ON DELETE SET NULL
    ';
  END IF;
END$$;

-- 5) Trigger para manter updated_at
CREATE OR REPLACE FUNCTION zanaflex_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_zanaflex_meta_updated_at ON zanaflex_document_metadata;
CREATE TRIGGER trg_zanaflex_meta_updated_at
  BEFORE UPDATE ON zanaflex_document_metadata
  FOR EACH ROW EXECUTE FUNCTION zanaflex_set_updated_at();

-- 6) Índices úteis (alinhados com 008)
CREATE INDEX IF NOT EXISTS idx_zanaflex_meta_category
  ON zanaflex_document_metadata(category_id);
CREATE INDEX IF NOT EXISTS idx_zanaflex_meta_code
  ON zanaflex_document_metadata(code);
CREATE INDEX IF NOT EXISTS zanaflex_idx_doc_metadata_session
  ON zanaflex_document_metadata(session_id);

-- 7) Verificação rápida (não falha se rodar tudo certo)
DO $$
DECLARE missing TEXT;
BEGIN
  SELECT string_agg(col, ', ')
    INTO missing
  FROM (
    SELECT unnest(ARRAY[
      'file_id','title','code','url','source','mime_type',
      'schema','category_id','created_at','updated_at'
    ]) AS col
  ) wanted
  WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.columns c
     WHERE c.table_schema = 'public'
       AND c.table_name   = 'zanaflex_document_metadata'
       AND c.column_name  = wanted.col
  );

  IF missing IS NOT NULL THEN
    RAISE EXCEPTION
      'zanaflex_document_metadata ainda está faltando colunas: %', missing;
  END IF;
END$$;

-- =======  DOWN  ========
-- Sem rollback: as colunas adicionadas são compatíveis com o schema legado
-- (legado usa subset). Caso precise reverter, faça manualmente:
--   ALTER TABLE zanaflex_document_metadata RENAME COLUMN file_id TO id;
--   ALTER TABLE zanaflex_document_metadata DROP COLUMN code, ... ;
