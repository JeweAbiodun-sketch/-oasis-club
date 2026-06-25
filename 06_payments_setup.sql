-- ============================================================
-- Oasis Club App — Payment evidence submission feature setup
-- Run this AFTER 01-05 setup scripts have already been run.
-- Safe to re-run.
-- ============================================================

-- ============================================================
-- TABLE
-- A member uploads proof of a payment (dues or a building project
-- contribution) along with the amount they're claiming. It starts
-- 'pending' and is visible only to the submitter, the Treasurer,
-- and the Financial Secretary until reviewed (enforced in the
-- app's UI, same trust model already used for PINs elsewhere in
-- this app -- not a database-level restriction, since there's no
-- real per-user login here, just shared PINs).
-- ============================================================

create table if not exists public.payment_submissions (
  id uuid primary key default gen_random_uuid(),
  member_id text not null references public.members(id) on delete cascade,
  payment_type text not null check (payment_type in ('dues','building_project')),
  amount numeric not null check (amount > 0),
  proof_url text not null,
  proof_name text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by text,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now()
);

alter table public.payment_submissions enable row level security;

drop policy if exists "payment_submissions are publicly readable" on public.payment_submissions;
create policy "payment_submissions are publicly readable" on public.payment_submissions
  for select to anon, authenticated
  using (true);

-- ============================================================
-- STORAGE BUCKET for proof-of-payment files
-- Public bucket, same trust model as constitution / news attachments.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', true, 10485760, array[
  'image/jpeg','image/png','image/webp','image/gif','application/pdf'
])
on conflict (id) do update set
  public = true,
  file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','application/pdf'];

drop policy if exists "payment proofs are publicly readable" on storage.objects;
create policy "payment proofs are publicly readable" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'payment-proofs');

drop policy if exists "payment proofs can be uploaded" on storage.objects;
create policy "payment proofs can be uploaded" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'payment-proofs');

-- ============================================================
-- HELPERS: distinguish Treasurer specifically from Financial
-- Secretary specifically, since (unlike everywhere else in this
-- app) the three officer logins do NOT have equal rights here --
-- only the Treasurer can approve, though either can reject.
-- ============================================================

create or replace function public.is_treasurer_pin(p_pin text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select p_pin = '7395';
$$;

create or replace function public.is_treasurer_or_financial_secretary_pin(p_pin text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select p_pin in ('7395','1064');
$$;

grant execute on function public.is_treasurer_pin(text) to anon, authenticated;
grant execute on function public.is_treasurer_or_financial_secretary_pin(text) to anon, authenticated;

-- ============================================================
-- RPC: submit payment evidence. Any active member's own PIN works.
-- ============================================================

create or replace function public.submit_payment_evidence(
  p_pin text,
  p_payment_type text,
  p_amount numeric,
  p_proof_url text,
  p_proof_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id text;
  v_new_id uuid;
begin
  select id into v_member_id from members
  where pin = p_pin and status not in ('suspended','dismissed');

  if v_member_id is null then
    raise exception 'PIN not recognized, or this member no longer has access';
  end if;

  if p_payment_type not in ('dues','building_project') then
    raise exception 'Not a recognized payment type';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;

  insert into payment_submissions (member_id, payment_type, amount, proof_url, proof_name)
  values (v_member_id, p_payment_type, p_amount, p_proof_url, p_proof_name)
  returning id into v_new_id;

  return v_new_id;
end;
$$;

grant execute on function public.submit_payment_evidence(text,text,numeric,text,text) to anon, authenticated;

-- ============================================================
-- RPC: approve a payment submission. TREASURER ONLY.
-- On approval: a 'dues' submission adds to the member's
-- dues_paid total; a 'building_project' submission is recorded
-- as an income transaction on the Finance page.
-- ============================================================

create or replace function public.approve_payment_evidence(
  p_pin text,
  p_submission_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub record;
  v_member_name text;
begin
  if not is_treasurer_pin(p_pin) then
    raise exception 'Only the Treasurer can approve a payment submission';
  end if;

  select * into v_sub from payment_submissions where id = p_submission_id and status = 'pending';
  if v_sub is null then
    raise exception 'Submission not found or already reviewed';
  end if;

  select name into v_member_name from members where id = v_sub.member_id;

  if v_sub.payment_type = 'dues' then
    -- Deliberately additive (a member may submit evidence for several
    -- installments across the year). This differs from the manual
    -- "Edit dues paid" pencil icon on the Dues page, which overwrites
    -- the total outright -- that's intentional, not a bug to "fix".
    update members set dues_paid = coalesce(dues_paid,0) + v_sub.amount, updated_at = now() where id = v_sub.member_id;
  else
    insert into transactions (id, desc_text, type, amount, date)
    values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' (Building Project contribution)', 'income', v_sub.amount, current_date);
  end if;

  update payment_submissions
  set status = 'approved', reviewed_by = (select id from members where pin = p_pin limit 1), reviewed_at = now()
  where id = p_submission_id;
end;
$$;

grant execute on function public.approve_payment_evidence(text,uuid) to anon, authenticated;

-- ============================================================
-- RPC: reject a payment submission. Treasurer OR Financial
-- Secretary can do this.
-- ============================================================

create or replace function public.reject_payment_evidence(
  p_pin text,
  p_submission_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_treasurer_or_financial_secretary_pin(p_pin) then
    raise exception 'Only the Treasurer or Financial Secretary can review a payment submission';
  end if;

  update payment_submissions
  set status = 'rejected', reviewed_by = null, reviewed_at = now(), rejection_reason = p_reason
  where id = p_submission_id and status = 'pending';

  if not found then
    raise exception 'Submission not found or already reviewed';
  end if;
end;
$$;

grant execute on function public.reject_payment_evidence(text,uuid,text) to anon, authenticated;

-- ============================================================
-- RPC: a member can withdraw their own still-pending submission.
-- ============================================================

create or replace function public.delete_payment_evidence(
  p_pin text,
  p_submission_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id text;
  v_sub record;
begin
  select id into v_member_id from members where pin = p_pin;
  select * into v_sub from payment_submissions where id = p_submission_id;

  if v_sub is null then
    raise exception 'Submission not found';
  end if;

  if v_sub.member_id <> v_member_id and not is_officer_pin(p_pin) then
    raise exception 'You can only remove your own submission';
  end if;

  if v_sub.status = 'approved' then
    raise exception 'An approved submission cannot be removed, since it has already updated the records';
  end if;

  delete from payment_submissions where id = p_submission_id;
end;
$$;

grant execute on function public.delete_payment_evidence(text,uuid) to anon, authenticated;

-- ============================================================
-- REALTIME
-- ============================================================
alter publication supabase_realtime add table public.payment_submissions;

-- ============================================================
-- Done.
-- ============================================================
