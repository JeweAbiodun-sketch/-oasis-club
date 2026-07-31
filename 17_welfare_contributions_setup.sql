-- ============================================================
-- Oasis Club App - Move Welfare CONTRIBUTIONS into Supabase so they
-- sync across devices like everything else.
--
-- Scope: this covers ONLY Section 1 "Welfare contribution" (the levy
-- events and their per-member contributions) which until now lived in
-- the browser (localStorage 'oasis-welfare-v1'). It does NOT touch the
-- Welfare Committee loan/fund arrangement (welfare_loans,
-- welfare_release_requests, welfare_purse_entries) or the 2-of-3 fund
-- release approval or benefactor privacy -- those already live in the DB
-- and are unchanged.
--
-- Trust model: contributions are readable by everyone (same as the
-- current in-app behaviour where any member can see who contributed).
-- Only an Executive Officer PIN can add/edit/delete, enforced by the
-- RPCs via is_officer_pin() -- which already includes the Treasurer and
-- Financial Secretary, so the payment-evidence auto-lodge keeps working.
--
-- Run AFTER the core setup. Safe to re-run.
-- ============================================================

-- NOTE: drop-and-recreate (not "if not exists") on purpose. A stray
-- welfare_events table with a different/older schema may already exist in
-- the live DB; "if not exists" would keep the wrong columns. These tables
-- hold no real data yet (welfare contributions used to live in the browser),
-- so recreating them cleanly is safe and makes this file re-runnable.
drop table if exists public.welfare_contributions cascade;
drop table if exists public.welfare_events cascade;

create table public.welfare_events (
  id text primary key,
  title text not null,
  type text not null default 'other',
  event_date date not null,
  target_amount numeric,
  description text,
  created_at timestamptz not null default now()
);

create table public.welfare_contributions (
  id text primary key,
  event_id text not null references public.welfare_events(id) on delete cascade,
  member_id text references public.members(id) on delete set null,
  amount numeric not null,
  paid_date date,
  created_at timestamptz not null default now()
);

create index if not exists welfare_contributions_event_idx on public.welfare_contributions(event_id);

alter table public.welfare_events enable row level security;
alter table public.welfare_contributions enable row level security;

drop policy if exists "welfare_events are publicly readable" on public.welfare_events;
create policy "welfare_events are publicly readable" on public.welfare_events
  for select to anon, authenticated using (true);

drop policy if exists "welfare_contributions are publicly readable" on public.welfare_contributions;
create policy "welfare_contributions are publicly readable" on public.welfare_contributions
  for select to anon, authenticated using (true);

-- ------------------------------------------------------------
-- RPC: add / update a welfare event (levy or other). Officer PIN only.
-- ------------------------------------------------------------
create or replace function public.officer_add_welfare_event(
  p_officer_pin text,
  p_id text,
  p_title text,
  p_type text,
  p_event_date date,
  p_target_amount text default null,
  p_description text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to manage welfare contributions';
  end if;
  insert into welfare_events (id, title, type, event_date, target_amount, description)
  values (p_id, trim(p_title), coalesce(nullif(trim(coalesce(p_type,'')),''),'other'),
          p_event_date, nullif(trim(coalesce(p_target_amount,'')),'')::numeric,
          nullif(trim(coalesce(p_description,'')),''))
  on conflict (id) do update set
    title = excluded.title, type = excluded.type, event_date = excluded.event_date,
    target_amount = excluded.target_amount, description = excluded.description;
end;
$fn$;

grant execute on function public.officer_add_welfare_event(text,text,text,text,date,text,text) to anon, authenticated;

-- ------------------------------------------------------------
-- RPC: delete a welfare event (and its contributions, via cascade).
-- ------------------------------------------------------------
create or replace function public.officer_delete_welfare_event(
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
    raise exception 'Not authorized to manage welfare contributions';
  end if;
  delete from welfare_events where id = p_id;
end;
$fn$;

grant execute on function public.officer_delete_welfare_event(text,text) to anon, authenticated;

-- ------------------------------------------------------------
-- RPC: record one member contribution against an event.
-- If p_event_id doesn't exist yet, create a levy event for it (used by
-- the payment-evidence auto-lodge, which targets the current FY levy).
-- ------------------------------------------------------------
create or replace function public.officer_add_welfare_contribution(
  p_officer_pin text,
  p_id text,
  p_event_id text,
  p_member_id text,
  p_amount numeric,
  p_paid_date date,
  p_event_title text default null,
  p_event_type text default 'levy',
  p_event_date date default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to record welfare contributions';
  end if;
  if not exists (select 1 from welfare_events where id = p_event_id) then
    insert into welfare_events (id, title, type, event_date)
    values (p_event_id,
            coalesce(nullif(trim(coalesce(p_event_title,'')),''),'Welfare Contributions'),
            coalesce(nullif(trim(coalesce(p_event_type,'')),''),'levy'),
            coalesce(p_event_date, p_paid_date, current_date));
  end if;
  insert into welfare_contributions (id, event_id, member_id, amount, paid_date)
  values (p_id, p_event_id, p_member_id, p_amount, p_paid_date);
end;
$fn$;

grant execute on function public.officer_add_welfare_contribution(text,text,text,text,numeric,date,text,text,date) to anon, authenticated;

-- ------------------------------------------------------------
-- RPC: delete a single contribution.
-- ------------------------------------------------------------
create or replace function public.officer_delete_welfare_contribution(
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
    raise exception 'Not authorized to manage welfare contributions';
  end if;
  delete from welfare_contributions where id = p_id;
end;
$fn$;

grant execute on function public.officer_delete_welfare_contribution(text,text) to anon, authenticated;

-- ------------------------------------------------------------
-- RPC: replace the ENTIRE welfare contribution ledger in one call.
-- Powers the Treasurer "Upload welfare CSV/Excel (replace in full)"
-- feature. p_events is the same JSON shape the app uses in memory:
--   [{id,title,type,date,targetAmount,description,
--     contributions:[{id,memberId,amount,paidDate}]}]
-- ------------------------------------------------------------
create or replace function public.officer_replace_all_welfare(
  p_officer_pin text,
  p_events jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  ev jsonb;
  c jsonb;
  v_eid text;
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to manage welfare contributions';
  end if;
  delete from welfare_contributions;
  delete from welfare_events;
  for ev in select * from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) loop
    v_eid := coalesce(nullif(ev->>'id',''), gen_random_uuid()::text);
    insert into welfare_events (id, title, type, event_date, target_amount, description)
    values (v_eid,
            coalesce(nullif(ev->>'title',''),'Welfare Event'),
            coalesce(nullif(ev->>'type',''),'other'),
            coalesce(nullif(ev->>'date','')::date, current_date),
            nullif(ev->>'targetAmount','')::numeric,
            nullif(ev->>'description',''));
    for c in select * from jsonb_array_elements(coalesce(ev->'contributions','[]'::jsonb)) loop
      if coalesce(c->>'memberId','') <> '' and coalesce(nullif(c->>'amount',''),'0')::numeric <> 0 then
        insert into welfare_contributions (id, event_id, member_id, amount, paid_date)
        values (coalesce(nullif(c->>'id',''), gen_random_uuid()::text),
                v_eid, c->>'memberId', (c->>'amount')::numeric,
                nullif(c->>'paidDate','')::date);
      end if;
    end loop;
  end loop;
end;
$fn$;

grant execute on function public.officer_replace_all_welfare(text,jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- REALTIME
-- ------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='welfare_events') then
    alter publication supabase_realtime add table public.welfare_events;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='welfare_contributions') then
    alter publication supabase_realtime add table public.welfare_contributions;
  end if;
end $$;

notify pgrst, 'reload schema';

-- ============================================================
-- Done. Next: run 17b_welfare_seed_from_statement.sql to load the
-- corrected contributions, then publish the updated index.html.
-- ============================================================
