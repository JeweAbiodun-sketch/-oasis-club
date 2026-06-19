-- ================================================================
-- OASIS CLUB — MASTER DATABASE MIGRATION  (run this ONE file)
-- Supabase dashboard → SQL Editor → New query → paste → Run
--
-- Every statement is idempotent: CREATE TABLE IF NOT EXISTS,
-- CREATE OR REPLACE FUNCTION, ON CONFLICT DO NOTHING, etc.
-- Safe to run on a brand-new database OR an existing one.
-- ================================================================


-- ── SECTION 1: CORE TABLES ──────────────────────────────────────

CREATE TABLE IF NOT EXISTS members (
  id         TEXT    PRIMARY KEY,
  name       TEXT    NOT NULL,
  role       TEXT    NOT NULL DEFAULT 'Member',
  status     TEXT    NOT NULL DEFAULT 'active',
  phone      TEXT    NOT NULL DEFAULT '',
  email      TEXT    NOT NULL DEFAULT '',
  joined     TEXT    NOT NULL DEFAULT '',
  dues_paid  NUMERIC NOT NULL DEFAULT 0,
  pin        TEXT    NOT NULL,
  photo      TEXT    NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS minutes (
  id    TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  date  DATE NOT NULL,
  type  TEXT NOT NULL DEFAULT 'general',
  notes TEXT NOT NULL DEFAULT ''
);

-- NOTE: description column is named desc_text to avoid reserved-word conflicts
CREATE TABLE IF NOT EXISTS transactions (
  id        TEXT    PRIMARY KEY,
  date      DATE    NOT NULL,
  desc_text TEXT    NOT NULL,
  type      TEXT    NOT NULL DEFAULT 'income',
  amount    NUMERIC NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS club_meta (
  id                     INTEGER PRIMARY KEY DEFAULT 1,
  financial_year_start   DATE    NOT NULL DEFAULT '2025-10-01',
  annual_due_amount      NUMERIC NOT NULL DEFAULT 50000,
  dues_year_label        TEXT    NOT NULL DEFAULT '2025/2026',
  quorum_note            TEXT    NOT NULL DEFAULT '',
  next_agm_date          DATE,
  term_start             DATE,
  constitution_url       TEXT    NOT NULL DEFAULT '',
  constitution_uploaded_at TIMESTAMPTZ,
  chatbot_api_key        TEXT    NOT NULL DEFAULT '',
  chatbot_api_provider   TEXT    NOT NULL DEFAULT 'gemini',
  CONSTRAINT single_row CHECK (id = 1)
);

-- Add any columns that may be missing on an existing installation
ALTER TABLE club_meta ADD COLUMN IF NOT EXISTS term_start             DATE;
ALTER TABLE club_meta ADD COLUMN IF NOT EXISTS constitution_url       TEXT NOT NULL DEFAULT '';
ALTER TABLE club_meta ADD COLUMN IF NOT EXISTS constitution_uploaded_at TIMESTAMPTZ;
ALTER TABLE club_meta ADD COLUMN IF NOT EXISTS chatbot_api_key        TEXT NOT NULL DEFAULT '';
ALTER TABLE club_meta ADD COLUMN IF NOT EXISTS chatbot_api_provider   TEXT NOT NULL DEFAULT 'gemini';

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

CREATE TABLE IF NOT EXISTS club_polls (
  id         TEXT  PRIMARY KEY,
  question   TEXT  NOT NULL,
  options    JSONB NOT NULL DEFAULT '[]',
  ends_at    TEXT  NOT NULL DEFAULT '',
  created_by TEXT  NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ── SECTION 2: ROW LEVEL SECURITY ───────────────────────────────

ALTER TABLE members      ENABLE ROW LEVEL SECURITY;
ALTER TABLE minutes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE club_meta    ENABLE ROW LEVEL SECURITY;
ALTER TABLE club_events  ENABLE ROW LEVEL SECURITY;
ALTER TABLE club_news    ENABLE ROW LEVEL SECURITY;
ALTER TABLE club_polls   ENABLE ROW LEVEL SECURITY;

-- All tables: public read via anon key (app enforces auth via PIN)
DO $$ BEGIN CREATE POLICY "pub_read_members"      ON members      FOR SELECT USING (true); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE POLICY "pub_read_minutes"      ON minutes      FOR SELECT USING (true); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE POLICY "pub_read_transactions" ON transactions FOR SELECT USING (true); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE POLICY "pub_read_club_meta"    ON club_meta    FOR SELECT USING (true); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE POLICY "pub_read_club_events"  ON club_events  FOR SELECT USING (true); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE POLICY "pub_read_club_news"    ON club_news    FOR SELECT USING (true); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE POLICY "pub_read_club_polls"   ON club_polls   FOR SELECT USING (true); EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ── SECTION 3: SUPABASE STORAGE BUCKET (constitution files) ────

-- Create the bucket (public = anyone can read the URL)
INSERT INTO storage.buckets (id, name, public)
VALUES ('constitution', 'constitution', true)
ON CONFLICT (id) DO NOTHING;

-- Allow anon to read files in the bucket
DO $$ BEGIN
  CREATE POLICY "constitution_select" ON storage.objects
    FOR SELECT USING (bucket_id = 'constitution');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Allow anon to upload / overwrite files (officer PIN is enforced by the app)
DO $$ BEGIN
  CREATE POLICY "constitution_insert" ON storage.objects
    FOR INSERT WITH CHECK (bucket_id = 'constitution');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
  CREATE POLICY "constitution_update" ON storage.objects
    FOR UPDATE USING (bucket_id = 'constitution');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;


-- ── SECTION 4: HELPER FUNCTION ──────────────────────────────────

-- Returns TRUE if the given PIN belongs to any officer role.
-- Secretary: 4821 | Treasurer: 7395 | Financial Secretary: 1064
CREATE OR REPLACE FUNCTION is_officer_pin(p_pin TEXT)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER AS $$
  SELECT p_pin IN ('4821', '7395', '1064');
$$;


-- ── SECTION 5: MEMBER SELF-SERVICE FUNCTIONS ────────────────────

-- Member updates own name/phone/email/photo — authenticated by their PIN
CREATE OR REPLACE FUNCTION update_member_profile(
  p_member_id   TEXT,
  p_current_pin TEXT,
  p_name        TEXT,
  p_phone       TEXT DEFAULT '',
  p_email       TEXT DEFAULT '',
  p_photo       TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM members WHERE id = p_member_id AND pin = p_current_pin) THEN
    RAISE EXCEPTION 'Unauthorized: incorrect PIN';
  END IF;
  UPDATE members
  SET name  = p_name,
      phone = COALESCE(p_phone, ''),
      email = COALESCE(p_email, ''),
      photo = CASE WHEN p_photo IS NULL THEN photo ELSE p_photo END
  WHERE id = p_member_id;
END;
$$;

-- Member changes their own PIN
CREATE OR REPLACE FUNCTION change_member_pin(
  p_member_id   TEXT,
  p_current_pin TEXT,
  p_new_pin     TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM members WHERE id = p_member_id AND pin = p_current_pin) THEN
    RAISE EXCEPTION 'Unauthorized: current PIN is incorrect';
  END IF;
  IF p_new_pin !~ '^\d{4}$' THEN
    RAISE EXCEPTION 'New PIN must be exactly 4 digits';
  END IF;
  UPDATE members SET pin = p_new_pin WHERE id = p_member_id;
END;
$$;


-- ── SECTION 6: OFFICER — MEMBER MANAGEMENT ──────────────────────

-- Create or update any member record
CREATE OR REPLACE FUNCTION officer_upsert_member(
  p_officer_pin TEXT,
  p_id          TEXT,
  p_name        TEXT,
  p_role        TEXT    DEFAULT 'Member',
  p_status      TEXT    DEFAULT 'active',
  p_phone       TEXT    DEFAULT '',
  p_email       TEXT    DEFAULT '',
  p_joined      TEXT    DEFAULT '',
  p_photo       TEXT    DEFAULT NULL,
  p_pin         TEXT    DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO members (id, name, role, status, phone, email, joined, photo, pin, dues_paid)
  VALUES (
    p_id, p_name, p_role, p_status,
    COALESCE(p_phone,''), COALESCE(p_email,''), COALESCE(p_joined,''),
    COALESCE(p_photo,''),
    COALESCE(p_pin, LPAD(FLOOR(RANDOM()*10000)::TEXT, 4, '0')),
    0
  )
  ON CONFLICT (id) DO UPDATE SET
    name   = EXCLUDED.name,
    role   = EXCLUDED.role,
    status = EXCLUDED.status,
    phone  = EXCLUDED.phone,
    email  = EXCLUDED.email,
    joined = EXCLUDED.joined,
    photo  = CASE WHEN p_photo IS NULL THEN members.photo ELSE EXCLUDED.photo END;
END;
$$;

-- Delete a member permanently
CREATE OR REPLACE FUNCTION officer_delete_member(
  p_officer_pin TEXT,
  p_member_id   TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  DELETE FROM members WHERE id = p_member_id;
END;
$$;

-- Restore a suspended / dismissed member back to active
CREATE OR REPLACE FUNCTION officer_restore_member(
  p_officer_pin TEXT,
  p_member_id   TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  UPDATE members SET status = 'active' WHERE id = p_member_id;
END;
$$;

-- Record how much a member has paid towards their annual dues
CREATE OR REPLACE FUNCTION officer_set_dues_paid(
  p_officer_pin TEXT,
  p_member_id   TEXT,
  p_amount      NUMERIC
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  UPDATE members SET dues_paid = p_amount WHERE id = p_member_id;
END;
$$;


-- ── SECTION 7: OFFICER — MINUTES & FINANCE ──────────────────────

CREATE OR REPLACE FUNCTION officer_add_minutes(
  p_officer_pin TEXT,
  p_id          TEXT,
  p_title       TEXT,
  p_date        TEXT,
  p_type        TEXT DEFAULT 'general',
  p_notes       TEXT DEFAULT ''
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO minutes (id, title, date, type, notes)
  VALUES (p_id, p_title, p_date::DATE, p_type, COALESCE(p_notes,''))
  ON CONFLICT (id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION officer_delete_minutes(
  p_officer_pin TEXT,
  p_id          TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  DELETE FROM minutes WHERE id = p_id;
END;
$$;

-- Add a financial entry; desc_text is the column name (not 'description')
CREATE OR REPLACE FUNCTION officer_add_transaction(
  p_officer_pin TEXT,
  p_id          TEXT,
  p_desc        TEXT,
  p_type        TEXT,
  p_amount      NUMERIC,
  p_date        TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO transactions (id, date, desc_text, type, amount)
  VALUES (p_id, p_date::DATE, p_desc, p_type, p_amount)
  ON CONFLICT (id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION officer_delete_transaction(
  p_officer_pin TEXT,
  p_id          TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  DELETE FROM transactions WHERE id = p_id;
END;
$$;


-- ── SECTION 8: OFFICER — CLUB SETTINGS ──────────────────────────

CREATE OR REPLACE FUNCTION officer_update_meta(
  p_officer_pin          TEXT,
  p_financial_year_start TEXT    DEFAULT NULL,
  p_annual_due_amount    NUMERIC DEFAULT NULL,
  p_dues_year_label      TEXT    DEFAULT NULL,
  p_quorum_note          TEXT    DEFAULT NULL,
  p_next_agm_date        TEXT    DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO club_meta (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE club_meta SET
    financial_year_start = COALESCE(p_financial_year_start::DATE, financial_year_start),
    annual_due_amount    = COALESCE(p_annual_due_amount,           annual_due_amount),
    dues_year_label      = COALESCE(p_dues_year_label,             dues_year_label),
    quorum_note          = COALESCE(p_quorum_note,                 quorum_note),
    next_agm_date        = CASE
                             WHEN p_next_agm_date IS NULL THEN next_agm_date
                             WHEN p_next_agm_date = ''   THEN NULL
                             ELSE p_next_agm_date::DATE
                           END
  WHERE id = 1;
END;
$$;

CREATE OR REPLACE FUNCTION officer_update_term_start(
  p_officer_pin TEXT,
  p_term_start  TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO club_meta (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE club_meta SET
    term_start = CASE
                   WHEN p_term_start IS NULL OR p_term_start = '' THEN NULL
                   ELSE p_term_start::DATE
                 END
  WHERE id = 1;
END;
$$;

-- Called after the constitution PDF is uploaded to Supabase Storage
CREATE OR REPLACE FUNCTION officer_update_constitution_url(
  p_pin TEXT,
  p_url TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO club_meta (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE club_meta SET
    constitution_url          = p_url,
    constitution_uploaded_at  = NOW()
  WHERE id = 1;
END;
$$;


-- ── SECTION 9: EVENTS, NOTICES, POLLS ───────────────────────────

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
  INSERT INTO club_events (id, title, date, time, location, type, description)
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

CREATE OR REPLACE FUNCTION add_club_news(
  p_officer_pin TEXT,
  p_id          TEXT,
  p_title       TEXT,
  p_body        TEXT,
  p_author      TEXT DEFAULT 'Club Secretary'
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NOT is_officer_pin(p_officer_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid officer PIN';
  END IF;
  INSERT INTO club_news (id, title, body, author)
  VALUES (p_id, p_title, p_body, p_author)
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
  INSERT INTO club_polls (id, question, options, ends_at, created_by)
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
  -- Verify the member's own PIN
  IF NOT EXISTS (SELECT 1 FROM members WHERE id = p_member_id AND pin = p_member_pin) THEN
    RAISE EXCEPTION 'Unauthorized: invalid member PIN';
  END IF;
  -- Reject duplicate votes
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
  -- Append member ID to the chosen option's votes array
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


-- ── SECTION 10: CHATBOT API KEY (Secretary only) ─────────────────

CREATE OR REPLACE FUNCTION secretary_set_chatbot_key(
  p_secretary_pin TEXT,
  p_api_key       TEXT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_provider TEXT;
BEGIN
  -- Only Secretary PIN (4821) may set/clear the chatbot key
  IF p_secretary_pin != '4821' THEN
    RAISE EXCEPTION 'Unauthorized: only the Secretary can configure the chatbot key';
  END IF;
  INSERT INTO club_meta (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  v_provider := CASE
    WHEN p_api_key ~* '^sk-ant-' THEN 'anthropic'
    WHEN p_api_key ~* '^(cohere-|co-)' THEN 'cohere'
    ELSE 'gemini'
  END;
  UPDATE club_meta
     SET chatbot_api_key = p_api_key,
         chatbot_api_provider = CASE WHEN p_api_key = '' THEN chatbot_api_provider ELSE v_provider END
   WHERE id = 1;
END;
$$;

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


-- ── SECTION 11: GRANTS (anon role used by the app) ──────────────

GRANT EXECUTE ON FUNCTION is_officer_pin(TEXT)                                       TO anon;
GRANT EXECUTE ON FUNCTION update_member_profile(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT)       TO anon;
GRANT EXECUTE ON FUNCTION change_member_pin(TEXT,TEXT,TEXT)                          TO anon;
GRANT EXECUTE ON FUNCTION officer_upsert_member(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon;
GRANT EXECUTE ON FUNCTION officer_delete_member(TEXT,TEXT)                           TO anon;
GRANT EXECUTE ON FUNCTION officer_restore_member(TEXT,TEXT)                          TO anon;
GRANT EXECUTE ON FUNCTION officer_set_dues_paid(TEXT,TEXT,NUMERIC)                   TO anon;
GRANT EXECUTE ON FUNCTION officer_add_minutes(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT)         TO anon;
GRANT EXECUTE ON FUNCTION officer_delete_minutes(TEXT,TEXT)                          TO anon;
GRANT EXECUTE ON FUNCTION officer_add_transaction(TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT)  TO anon;
GRANT EXECUTE ON FUNCTION officer_delete_transaction(TEXT,TEXT)                      TO anon;
GRANT EXECUTE ON FUNCTION officer_update_meta(TEXT,TEXT,NUMERIC,TEXT,TEXT,TEXT)      TO anon;
GRANT EXECUTE ON FUNCTION officer_update_term_start(TEXT,TEXT)                       TO anon;
GRANT EXECUTE ON FUNCTION officer_update_constitution_url(TEXT,TEXT)                 TO anon;
GRANT EXECUTE ON FUNCTION add_club_event(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT)    TO anon;
GRANT EXECUTE ON FUNCTION delete_club_event(TEXT,TEXT)                               TO anon;
GRANT EXECUTE ON FUNCTION add_club_news(TEXT,TEXT,TEXT,TEXT,TEXT)                    TO anon;
GRANT EXECUTE ON FUNCTION delete_club_news(TEXT,TEXT)                                TO anon;
GRANT EXECUTE ON FUNCTION add_club_poll(TEXT,TEXT,TEXT,JSONB,TEXT,TEXT)              TO anon;
GRANT EXECUTE ON FUNCTION vote_club_poll(TEXT,TEXT,TEXT,TEXT)                        TO anon;
GRANT EXECUTE ON FUNCTION delete_club_poll(TEXT,TEXT)                                TO anon;
GRANT EXECUTE ON FUNCTION secretary_set_chatbot_key(TEXT,TEXT)                       TO anon;
GRANT EXECUTE ON FUNCTION secretary_set_chatbot_config(TEXT,TEXT,TEXT)               TO anon;


-- ── SECTION 12: SEED DATA ────────────────────────────────────────

-- Ensure one club_meta row always exists (app will fail to read settings otherwise)
INSERT INTO club_meta (id, financial_year_start, annual_due_amount, dues_year_label, quorum_note, chatbot_api_key, chatbot_api_provider)
VALUES (1, '2025-10-01', 50000, '2025/2026', '', '', 'gemini')
ON CONFLICT (id) DO NOTHING;


-- ════════════════════════════════════════════════════════════════
-- DONE. After running this, reload the app and test all features.
--
-- NEXT STEPS:
--   1. Run supabase-transactions-history.sql  →  loads 201 historical
--      ledger entries (2020-2026, ending balance ₦627,000).
--   2. Log in as Secretary → tap the chat bubble → ⚙ gear →
--      paste your Anthropic or Gemini API key → Save & enable.
-- ════════════════════════════════════════════════════════════════
