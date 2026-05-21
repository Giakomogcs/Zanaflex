-- =============================================
-- Zanaflex — 010: Chat message table + user_id auto-fill
-- Mirrors the Sameka pattern. Stores LangChain Postgres chat memory
-- and links each row to the authenticated user via a trigger.
-- Run AFTER 009_rag_upsert_replace.sql
-- =============================================

-- =======  UP  ========

CREATE TABLE IF NOT EXISTS zanaflex_chat_message (
  id          BIGSERIAL PRIMARY KEY,
  session_id  TEXT        NOT NULL,
  message     JSONB       NOT NULL,
  user_id     UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_zanaflex_chat_session ON zanaflex_chat_message(session_id);
CREATE INDEX IF NOT EXISTS idx_zanaflex_chat_user    ON zanaflex_chat_message(user_id);

-- Trigger: extract user_id from human message context block or copy from the
-- matching human message in the same session for AI/system messages.
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

NOTIFY pgrst, 'reload schema';

-- =======  DOWN  ========
-- DROP TRIGGER IF EXISTS trg_zanaflex_chat_set_user_id ON zanaflex_chat_message;
-- DROP FUNCTION IF EXISTS trg_zanaflex_set_chat_user_id();
-- DROP TABLE IF EXISTS zanaflex_chat_message;
-- NOTIFY pgrst, 'reload schema';
