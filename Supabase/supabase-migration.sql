-- ================================================================
-- Oasis Club: Persistent Events, News, and Polls
-- Run this entire script in the Supabase SQL Editor.
-- Go to: Supabase dashboard → SQL Editor → New query → paste → Run
-- ================================================================

-- TABLES --------------------------------------------------------

CREATE TABLE IF NOT EXISTS club_events (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  date        DATE NOT NULL,
  time        TEXT NOT NULL DEFAULT '',
  location    TEXT NOT NULL DEFAULT '',
  type        TEXT NOT NULL DEFAULT 'general',
  description TEXT NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS club_news (
  id         TEXT PRIMARY KEY,
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  author     TEXT NOT NULL DEFAULT 'Club Secretary',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_url  TEXT;
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_name TEXT;
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_mime TEXT;
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_path TEXT;

CREATE TABLE IF NOT EXISTS club_polls (
  id         TEXT PRIMARY KEY,
  question   TEXT    NOT NULL,
  options    JSONB   NOT NULL DEFAULT '[]',
  ends_at    TEXT    NOT NULL DEFAULT '',
  created_by TEXT    NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS -----------------------------------------------------------

ALTER TABLE club_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE club_news   ENABLE ROW LEVEL SECURITY;
ALTER TABLE club_polls  ENABLE ROW LEVEL SECURITY;
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_url  TEXT;
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_name TEXT;
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_mime TEXT;
ALTER TABLE club_news ADD COLUMN IF NOT EXISTS attachment_path TEXT;

-- News attachments bucket used by notice posts
INSERT INTO storage.buckets (id, name, public)
VALUES ('news-attachments', 'news-attachments', true)
ON CONFLICT (id) DO NOTHING;

DO $$ BEGIN
  CREATE POLICY "news_attachments_select" ON storage.objects
    FOR SELECT USING (bucket_id = 'news-attachments');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "news_attachments_insert" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'news-attachments');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "news_attachments_update" ON storage.objects
    FOR UPDATE USING (bucket_id = 'news-attachments');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Everyone can read (anon key is used in the app)
DO $$ BEGIN
  CREATE POLICY "Public read events" ON club_events FOR SELECT USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "Public read news" ON club_news FOR SELECT USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "Public read polls" ON club_polls FOR SELECT USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- HELPER --------------------------------------------------------

CREATE OR REPLACE FUNCTION is_officer_pin(p_pin TEXT)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
  -- These are the role-level officer PINs defined in the app's EDITOR_PINS object.
  -- Update here if the officer PINs change.
  SELECT p_pin IN ('4821', '7395', '1064');
$$;

-- EVENTS --------------------------------------------------------

CREATE OR REPLACE FUNCTION add_club_event(
  p_officer_pin TEXT,
  p_id          TEXT,
  p_title       TEXT,
  p_date        TEXT,
  p_time        TEXT DEFAULT '',
  p_location    TEXT DEFAULT '',
  p_type        TEXT DEFAULT 'general',
  p_description TEXT DEFAULT ''
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO club_events(id, title, date, time, location, type, description)
  VALUES (p_id, p_title, p_date::DATE, p_time, p_location, p_type, p_description)
  ON CONFLICT (id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION delete_club_event(
  p_officer_pin TEXT,
  p_id          TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  DELETE FROM club_events WHERE id = p_id;
END;
$$;

-- NEWS ----------------------------------------------------------

CREATE OR REPLACE FUNCTION add_club_news(
  p_officer_pin TEXT,
  p_id          TEXT,
  p_title       TEXT,
  p_body        TEXT,
  p_author      TEXT DEFAULT 'Club Secretary',
  p_attachment_url  TEXT DEFAULT NULL,
  p_attachment_name TEXT DEFAULT NULL,
  p_attachment_mime TEXT DEFAULT NULL,
  p_attachment_path TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO club_news(id, title, body, author, attachment_url, attachment_name, attachment_mime, attachment_path)
  VALUES (p_id, p_title, p_body, p_author, p_attachment_url, p_attachment_name, p_attachment_mime, p_attachment_path)
  ON CONFLICT (id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION delete_club_news(
  p_officer_pin TEXT,
  p_id          TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  DELETE FROM club_news WHERE id = p_id;
END;
$$;

-- POLLS ---------------------------------------------------------

CREATE OR REPLACE FUNCTION add_club_poll(
  p_officer_pin TEXT,
  p_id          TEXT,
  p_question    TEXT,
  p_options     JSONB,
  p_ends_at     TEXT DEFAULT '',
  p_created_by  TEXT DEFAULT ''
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO club_polls(id, question, options, ends_at, created_by)
  VALUES (p_id, p_question, p_options, p_ends_at, p_created_by)
  ON CONFLICT (id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION vote_club_poll(
  p_member_pin TEXT,
  p_poll_id    TEXT,
  p_option_id  TEXT,
  p_member_id  TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_already BOOLEAN;
BEGIN
  -- Validate the member's personal PIN
  IF NOT EXISTS (
    SELECT 1 FROM members WHERE id = p_member_id AND pin = p_member_pin
  ) THEN
    RAISE EXCEPTION 'Unauthorized: invalid member PIN';
  END IF;

  -- Reject duplicate vote
  SELECT EXISTS (
    SELECT 1
    FROM   club_polls p,
           jsonb_array_elements(p.options) AS opt,
           jsonb_array_elements_text(opt->'votes') AS v
    WHERE  p.id = p_poll_id
    AND    v = p_member_id
  ) INTO v_already;

  IF v_already THEN
    RAISE EXCEPTION 'Already voted';
  END IF;

  -- Append member to the chosen option's votes array
  UPDATE club_polls
  SET options = (
    SELECT jsonb_agg(
      CASE WHEN (opt->>'id') = p_option_id
           THEN jsonb_set(opt, '{votes}', opt->'votes' || to_jsonb(p_member_id))
           ELSE opt
      END
    )
    FROM jsonb_array_elements(options) AS opt
  )
  WHERE id = p_poll_id;
END;
$$;

CREATE OR REPLACE FUNCTION delete_club_poll(
  p_officer_pin TEXT,
  p_id          TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  DELETE FROM club_polls WHERE id = p_id;
END;
$$;

-- GRANTS --------------------------------------------------------
-- Allow the anon (public) role to call these functions via the API key.

GRANT EXECUTE ON FUNCTION is_officer_pin(TEXT)                              TO anon;
GRANT EXECUTE ON FUNCTION add_club_event(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon;
GRANT EXECUTE ON FUNCTION delete_club_event(TEXT,TEXT)                      TO anon;
GRANT EXECUTE ON FUNCTION add_club_news(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon;
GRANT EXECUTE ON FUNCTION delete_club_news(TEXT,TEXT)                       TO anon;
GRANT EXECUTE ON FUNCTION add_club_poll(TEXT,TEXT,TEXT,JSONB,TEXT,TEXT)     TO anon;
GRANT EXECUTE ON FUNCTION vote_club_poll(TEXT,TEXT,TEXT,TEXT)               TO anon;
GRANT EXECUTE ON FUNCTION delete_club_poll(TEXT,TEXT)                       TO anon;

-- DONE ----------------------------------------------------------
-- After running this, reload the app. Events, Notices, and Polls
-- will now persist in the database and sync to every device
-- automatically via Supabase Realtime.
