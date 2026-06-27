-- ============================================================
-- Oasis Club App — President approval for welfare fund releases
-- Run this against the live database. Safe to re-run.
--
-- New rule (by request): releasing welfare funds is no longer
-- immediate once the Treasurer/Financial Secretary acts -- it now
-- needs the President's approval before the money actually moves.
-- The President's approval IS the trigger: approving is the moment
-- the welfare_purse_entries row gets created, not a separate step
-- after it.
--
-- This intentionally mirrors the existing payment_submissions /
-- welfare_loans pattern already used elsewhere in this app: a request
-- table with a status, and a separate approve/reject step performed
-- by whoever is authorized to decide.
-- ============================================================

-- ============================================================
-- PART 1: New table for pending release requests.
-- ============================================================

create table if not exists public.welfare_release_requests (
  id text primary key,
  amount numeric not null,
  description text,
  entry_date date not null,
  requested_by text references members(id),
  status text not null default 'pending',
  reviewed_by text references members(id),
  reviewed_at timestamp with time zone,
  rejection_reason text,
  created_at timestamp with time zone not null default now()
);

alter table public.welfare_release_requests enable row level security;

drop policy if exists "Allow read access to welfare_release_requests" on public.welfare_release_requests;
create policy "Allow read access to welfare_release_requests"
  on public.welfare_release_requests for select
  using (true);

-- Realtime, idempotent (won't error if already added on a re-run).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'welfare_release_requests'
  ) then
    alter publication supabase_realtime add table public.welfare_release_requests;
  end if;
end $$;

-- ============================================================
-- PART 2: is_president_pin() -- mirrors is_news_reviewer_pin()'s
-- pattern (member-role-based, not a hardcoded officer PIN, since the
-- President signs in with their own personal PIN, same as PRO does
-- for news review).
-- ============================================================

create or replace function public.is_president_pin(p_pin text)
returns boolean
language sql
security definer
set search_path = public
as $function$
  select exists(
    select 1 from members
    where pin = p_pin
    and role = 'President'
    and status not in ('suspended','dismissed')
  );
$function$;

-- ============================================================
-- PART 3: request_welfare_release() -- replaces the OLD
-- release_welfare_fund() as the front-end entry point for
-- Treasurer/Financial Secretary. Only creates a pending request; does
-- NOT touch welfare_purse_entries. Same authorization as the old
-- release_welfare_fund() had (Treasurer or Financial Secretary
-- officer-PIN login only).
-- ============================================================

create or replace function public.request_welfare_release(
  p_officer_pin text,
  p_id text,
  p_amount numeric,
  p_description text,
  p_entry_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not is_treasurer_or_financial_secretary_pin(p_officer_pin) then
    raise exception 'Only the Treasurer or Financial Secretary can request a welfare fund release';
  end if;

  insert into welfare_release_requests (id, amount, description, entry_date, requested_by, status)
  values (p_id, p_amount, p_description, p_entry_date, null, 'pending');
  -- requested_by is left null deliberately, same reasoning as
  -- release_welfare_fund()'s own v_recorder_id lookup: an officer-PIN
  -- session has no personal member identity to attach here unless that
  -- PIN happens to also be someone's personal PIN, which would be a
  -- separate problem. Reviewers can still see which officer ROLE made
  -- the request from context (this is the only function that creates
  -- these rows), even without a specific member name attached.
end;
$function$;

-- ============================================================
-- PART 4: approve_welfare_release() -- President only. This IS the
-- disbursement: approving inserts into welfare_purse_entries, exactly
-- what release_welfare_fund() used to do directly.
-- ============================================================

create or replace function public.approve_welfare_release(
  p_pin text,
  p_request_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_req welfare_release_requests;
  v_president_id text;
begin
  if not is_president_pin(p_pin) then
    raise exception 'Only the President can approve a welfare fund release';
  end if;

  select * into v_req from welfare_release_requests where id = p_request_id and status = 'pending';
  if v_req.id is null then
    raise exception 'Request not found or already reviewed';
  end if;

  select id into v_president_id from members where pin = p_pin limit 1;

  insert into welfare_purse_entries (id, entry_type, amount, description, recorded_by, entry_date)
  values (p_request_id, 'release', v_req.amount, v_req.description, v_president_id, v_req.entry_date);

  update welfare_release_requests
  set status = 'approved', reviewed_by = v_president_id, reviewed_at = now()
  where id = p_request_id;
end;
$function$;

-- ============================================================
-- PART 5: reject_welfare_release() -- President only.
-- ============================================================

create or replace function public.reject_welfare_release(
  p_pin text,
  p_request_id text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_president_id text;
begin
  if not is_president_pin(p_pin) then
    raise exception 'Only the President can reject a welfare fund release';
  end if;

  select id into v_president_id from members where pin = p_pin limit 1;

  update welfare_release_requests
  set status = 'rejected', reviewed_by = v_president_id, reviewed_at = now(), rejection_reason = p_reason
  where id = p_request_id and status = 'pending';

  if not found then
    raise exception 'Request not found or already reviewed';
  end if;
end;
$function$;

-- ============================================================
-- PART 5b: withdraw_welfare_release() -- lets the Treasurer or
-- Financial Secretary pull back their own request while it's still
-- pending, mirroring delete_payment_evidence()'s existing pattern for
-- the same kind of "I want to undo my own pending submission" case.
-- ============================================================

create or replace function public.withdraw_welfare_release(
  p_officer_pin text,
  p_request_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not is_treasurer_or_financial_secretary_pin(p_officer_pin) then
    raise exception 'Only the Treasurer or Financial Secretary can withdraw a release request';
  end if;

  delete from welfare_release_requests where id = p_request_id and status = 'pending';

  if not found then
    raise exception 'Request not found or already reviewed';
  end if;
end;
$function$;

-- ============================================================
-- PART 6: Retire the old release_welfare_fund() so nothing can bypass
-- the new approval step by calling it directly. Anything that used to
-- call this now calls request_welfare_release() instead (the front
-- end is updated separately).
-- ============================================================

drop function if exists public.release_welfare_fund(text, text, numeric, text, date);

-- ============================================================
-- Done.
-- ============================================================
