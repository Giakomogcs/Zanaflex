-- =============================================
-- Zanaflex — 011: Seed initial document category
-- Inserts the pilot category "IT" (Instrução de Trabalho).
-- Documents are NOT seeded here — they are ingested by the
-- Zanaflex-RAG workflow on first run / on every webhook call.
-- Idempotent: re-runs safely.
-- Run AFTER 010_chat_user_id.sql
-- =============================================

-- =======  UP  ========

INSERT INTO zanaflex_document_categories(code, name, description)
VALUES (
  'IT',
  'Instrução de Trabalho',
  'Procedimentos operacionais padronizados de processos da Zanaflex.'
)
ON CONFLICT (code) DO UPDATE
   SET name        = EXCLUDED.name,
       description = EXCLUDED.description,
       updated_at  = NOW();

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DELETE FROM zanaflex_document_categories WHERE code = 'IT';
-- NOTIFY pgrst, 'reload schema';
