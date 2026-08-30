-- ============================================================
-- Oasis Club App - Add created_at to minutes (publish timestamp).
--
-- WHY: the app flags each minute as "on time" / "published late" per
-- Article 11 (minutes published within 21 days OF THE MEETING). That test
-- needs to know WHEN the minute was posted -- but the minutes table never
-- stored a timestamp, so the UI had been comparing the meeting date against
-- "now", which made every minute eventually drift to "overdue" no matter how
-- promptly it was actually filed.
--
-- This migration adds created_at so the app can compute the status correctly
-- for minutes posted from now on. Safe to re-run.
--
-- Existing rows are intentionally left NULL (their real publish date is
-- unknown), and the app shows a neutral "recorded" badge for those rather
-- than guessing. See the OPTIONAL backfill at the bottom if you would rather
-- treat all past minutes as filed on their meeting date (i.e. "on time").
-- ============================================================

-- 1) Add the column WITHOUT a default first, so existing rows stay NULL
--    (an ADD COLUMN ... DEFAULT NOW() would backfill every old row to today,
--    falsely marking historic minutes as "published late").
alter table public.minutes
  add column if not exists created_at timestamptz;

-- 2) From now on, new minutes automatically get their post time.
alter table public.minutes
  alter column created_at set default now();

-- officer_add_minutes inserts (id, title, date, type, notes) only, so the
-- DEFAULT above fills created_at on every new insert. No function change needed.

notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- OPTIONAL backfill (commented out on purpose).
-- Uncomment and run ONLY if you want every existing minute to count as filed
-- on its meeting date -- they will then show "on time" instead of "recorded".
-- This writes an assumed timestamp; leave it commented to keep the record
-- honest about which past minutes have a known publish date.
-- ------------------------------------------------------------
-- update public.minutes
--   set created_at = (date::timestamptz)
--   where created_at is null;

-- ============================================================
-- Done.
-- ============================================================
