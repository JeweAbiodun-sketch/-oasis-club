-- ============================================================
-- Oasis Club App - Track welfare DISBURSEMENTS (money paid out of the
-- welfare contribution fund: bereavement/support, e.g. "Issued out to X
-- for burial"). Until now only contributions IN were recorded, so the
-- welfare fund balance was overstated. This adds the money-OUT side so the
-- fund shows a true balance = contributions - disbursements.
--
-- Same trust model as welfare_contributions: readable by everyone; only an
-- Executive Officer PIN can add/delete (via is_officer_pin()). Does NOT touch
-- the welfare loan/purse system. Safe to re-run.
-- ============================================================

create table if not exists public.welfare_disbursements (
  id text primary key,
  description text not null,
  amount numeric not null,
  disbursed_date date not null,
  beneficiary_member_id text references public.members(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table public.welfare_disbursements enable row level security;

drop policy if exists "welfare_disbursements are publicly readable" on public.welfare_disbursements;
create policy "welfare_disbursements are publicly readable" on public.welfare_disbursements
  for select to anon, authenticated using (true);

create or replace function public.officer_add_welfare_disbursement(
  p_officer_pin text,
  p_id text,
  p_description text,
  p_amount numeric,
  p_disbursed_date date,
  p_beneficiary_member_id text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to record welfare disbursements';
  end if;
  insert into welfare_disbursements (id, description, amount, disbursed_date, beneficiary_member_id)
  values (p_id, trim(p_description), p_amount, p_disbursed_date,
          nullif(trim(coalesce(p_beneficiary_member_id,'')),''));
end;
$fn$;

grant execute on function public.officer_add_welfare_disbursement(text,text,text,numeric,date,text) to anon, authenticated;

create or replace function public.officer_delete_welfare_disbursement(
  p_officer_pin text,
  p_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to manage welfare disbursements';
  end if;
  delete from welfare_disbursements where id = p_id;
end;
$fn$;

grant execute on function public.officer_delete_welfare_disbursement(text,text) to anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='welfare_disbursements') then
    alter publication supabase_realtime add table public.welfare_disbursements;
  end if;
end $$;

notify pgrst, 'reload schema';

-- ============================================================
-- Done.
-- ============================================================
