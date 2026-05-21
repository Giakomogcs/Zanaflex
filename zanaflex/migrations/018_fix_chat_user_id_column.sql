-- =============================================
-- Zanaflex — 018: Ensure zanaflex_chat_message.user_id exists + backfill
-- Fixes "column cm.user_id does not exist" when the chat table was
-- auto-created by LangChain's Postgres Chat Memory BEFORE migration 010
-- ran (so CREATE TABLE IF NOT EXISTS skipped adding user_id).
-- Safe to re-run.
-- =============================================

-- =======  UP  ========

-- 1) Add the column if missing
ALTER TABLE zanaflex_chat_message
  ADD COLUMN IF NOT EXISTS user_id UUID;

-- 2) Index for per-user history queries
CREATE INDEX IF NOT EXISTS idx_zanaflex_chat_user
  ON zanaflex_chat_message(user_id);

-- 3) Ensure created_at exists too (older auto-created tables may lack it)
ALTER TABLE zanaflex_chat_message
  ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

-- 4) Recreate trigger function (idempotent — same as migration 010)
CREATE OR REPLACE FUNCTION trg_zanaflex_set_chat_user_id()
RETURNS TRIGGER AS $$
DECLARE
  _content TEXT;
  _id_str  TEXT;
  _uid     UUID;
BEGIN
  IF NEW.user_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.message->>'type' = 'human' THEN
    _content := NEW.message->>'content';
    _id_str  := substring(_content from 'ID="([0-9a-fA-F-]{36})"');
    IF _id_str IS NOT NULL THEN
      NEW.user_id := _id_str::UUID;
    END IF;
  ELSE
    SELECT cm.user_id INTO _uid
      FROM zanaflex_chat_message cm
     WHERE cm.session_id = NEW.session_id
       AND cm.user_id IS NOT NULL
     LIMIT 1;
    IF _uid IS NOT NULL THEN
      NEW.user_id := _uid;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zanaflex_chat_set_user_id ON zanaflex_chat_message;
CREATE TRIGGER trg_zanaflex_chat_set_user_id
  BEFORE INSERT ON zanaflex_chat_message
  FOR EACH ROW
  EXECUTE FUNCTION trg_zanaflex_set_chat_user_id();

-- 5) Backfill: extract user_id from existing human messages' context block,
--    then propagate to sibling AI/system rows in the same session.
WITH humans AS (
  SELECT
    cm.session_id,
    (substring(cm.message->>'content' from 'ID="([0-9a-fA-F-]{36})"'))::UUID AS uid
  FROM zanaflex_chat_message cm
  WHERE cm.user_id IS NULL
    AND cm.message->>'type' = 'human'
    AND cm.message->>'content' ~ 'ID="[0-9a-fA-F-]{36}"'
)
UPDATE zanaflex_chat_message cm
   SET user_id = h.uid
  FROM humans h
 WHERE cm.session_id = h.session_id
   AND cm.user_id IS NULL
   AND h.uid IS NOT NULL;

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- ALTER TABLE zanaflex_chat_message DROP COLUMN IF EXISTS user_id;
-- DROP INDEX IF EXISTS idx_zanaflex_chat_user;
-- NOTIFY pgrst, 'reload schema';
