-- ============================================================
-- Oasis Club App - Self-service PIN reset by email.
--
-- Stores short-lived, single-use reset codes that the "pin-reset" Edge
-- Function creates (on request) and verifies (on confirm). Members prove they
-- own their registered email by entering the 6-digit code sent to it, then set
-- a new PIN. The Edge Function uses the service-role key, so this table is
-- fully locked to the client: RLS is ON with NO anon/authenticated policies,
-- meaning nobody but the function (service role) can read or write it.
--
-- Run AFTER the master migration. Safe to re-run.
-- ============================================================

create table if not exists public.pin_reset_codes (
  id          uuid primary key default gen_random_uuid(),
  member_id   text not null,
  email       text not null,
  code_hash   text not null,            -- SHA-256 of the 6-digit code (never store the code itself)
  expires_at  timestamptz not null,
  used        boolean not null default false,
  attempts    integer not null default 0,
  created_at  timestamptz not null default now()
);

create index if not exists pin_reset_codes_member_idx on public.pin_reset_codes(member_id);
create index if not exists pin_reset_codes_email_idx  on public.pin_reset_codes(lower(email));

-- Lock it down: RLS on, and deliberately NO policies for anon/authenticated.
-- The Edge Function bypasses RLS via the service-role key; the browser cannot
-- touch this table at all (it never needs to).
alter table public.pin_reset_codes enable row level security;
revoke all on public.pin_reset_codes from anon, authenticated;

-- Optional housekeeping: drop expired/used codes older than a day. Call
-- manually or from a scheduled job if you like; not required for correctness.
create or replace function public.purge_expired_pin_reset_codes()
returns void language sql security definer set search_path = public as $$
  delete from public.pin_reset_codes
  where created_at < now() - interval '1 day';
$$;

notify pgrst, 'reload schema';

-- ============================================================
-- Done. Next: deploy the "pin-reset" Edge Function and set its secrets
-- (RESEND_API_KEY, RESET_FROM_EMAIL). See the deployment runbook.
-- ============================================================
