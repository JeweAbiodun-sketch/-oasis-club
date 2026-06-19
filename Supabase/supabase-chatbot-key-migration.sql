-- ================================================================
-- Oasis Club: Secretary-managed chatbot API key
-- Run this in the Supabase SQL Editor.
-- Go to: Supabase dashboard → SQL Editor → New query → paste → Run
-- ================================================================

-- Add chatbot_api_key and chatbot_api_provider columns to club_meta
ALTER TABLE club_meta
  ADD COLUMN IF NOT EXISTS chatbot_api_key TEXT NOT NULL DEFAULT '';
ALTER TABLE club_meta
  ADD COLUMN IF NOT EXISTS chatbot_api_provider TEXT NOT NULL DEFAULT 'gemini';

-- Secretary-only RPC: only PIN '4821' (Secretary) can set or clear the key.
-- The key is stored in the database; all members read it when the app loads
-- so the AI assistant works on every device without individual key entry.
CREATE OR REPLACE FUNCTION secretary_set_chatbot_key(
  p_secretary_pin TEXT,
  p_api_key       TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secretary_pin != '4821' THEN
    RAISE EXCEPTION 'Unauthorized: only the Secretary can configure the chatbot key';
  END IF;
  INSERT INTO club_meta (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE club_meta
     SET chatbot_api_key = p_api_key,
         chatbot_api_provider = CASE
           WHEN p_api_key ~* '^sk-ant-' THEN 'anthropic'
           WHEN p_api_key ~* '^(cohere-|co-)' THEN 'cohere'
           ELSE 'gemini'
         END
   WHERE id = 1;
END;
$$;

GRANT EXECUTE ON FUNCTION secretary_set_chatbot_key(TEXT, TEXT) TO anon;

CREATE OR REPLACE FUNCTION secretary_set_chatbot_config(
  p_secretary_pin TEXT,
  p_provider      TEXT,
  p_api_key       TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF p_secretary_pin != '4821' THEN
    RAISE EXCEPTION 'Unauthorized: only the Secretary can configure the chatbot key';
  END IF;
  INSERT INTO club_meta (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE club_meta
     SET chatbot_api_key = coalesce(p_api_key, ''),
         chatbot_api_provider = CASE lower(coalesce(p_provider, ''))
           WHEN 'anthropic' THEN 'anthropic'
           WHEN 'cohere' THEN 'cohere'
           ELSE 'gemini'
         END
   WHERE id = 1;
END;
$$;

GRANT EXECUTE ON FUNCTION secretary_set_chatbot_config(TEXT, TEXT, TEXT) TO anon;

-- DONE
-- After running this, reload the app and log in as Secretary.
-- Tap the chat bubble → the gear icon (⚙) → paste your Anthropic or
-- Gemini key → Save & enable. The AI assistant will then work for every
-- member on every device automatically.
