-- ============================================================
-- Oasis Club — Core Notice/Event/Poll Functions
-- These were missing from the start (not something we broke).
-- Run this once in Supabase SQL Editor.
-- ============================================================

-- Make sure the tables exist with the columns the app expects.
-- If they already exist with these exact columns, these lines are no-ops.
create table if not exists club_events (
  id text primary key,
  title text not null,
  date date not null,
  time text,
  location text,
  type text default 'general',
  description text,
  created_at timestamptz not null default now()
);

create table if not exists club_news (
  id text primary key,
  title text not null,
  body text not null,
  author text default 'Club Secretary',
  created_at timestamptz not null default now()
);
alter table club_news add column if not exists attachment_url text;
alter table club_news add column if not exists attachment_name text;
alter table club_news add column if not exists attachment_mime text;
alter table club_news add column if not exists attachment_path text;

create table if not exists club_polls (
  id text primary key,
  question text not null,
  options jsonb not null default '[]'::jsonb,
  ends_at text,
  created_by text,
  created_at timestamptz not null default now()
);

alter table club_events enable row level security;
alter table club_news enable row level security;
alter table club_polls enable row level security;

drop policy if exists "Allow read club_events" on club_events;
create policy "Allow read club_events" on club_events for select using (true);
drop policy if exists "Allow read club_news" on club_news;
create policy "Allow read club_news" on club_news for select using (true);
drop policy if exists "Allow read club_polls" on club_polls;
create policy "Allow read club_polls" on club_polls for select using (true);

revoke insert, update, delete on club_events from anon, authenticated;
revoke insert, update, delete on club_news from anon, authenticated;
revoke insert, update, delete on club_polls from anon, authenticated;

-- ------------------------------------------------------------
-- Helper: validate an officer PIN against the same pattern
-- used elsewhere (dedicated officer PINs, or a member whose
-- role matches an executive office).
-- ------------------------------------------------------------
create or replace function is_officer_pin(p_pin text) returns boolean
language plpgsql
security definer
as $$
declare v_valid boolean;
begin
  if p_pin in ('4821','7395','1064') then  -- secretary, treasurer, financial_secretary
    return true;
  end if;
  select exists(
    select 1 from members
    where pin = p_pin
      and role in ('President','Vice-President','Secretary','Assistant Secretary','Treasurer','Financial Secretary','PRO')
  ) into v_valid;
  return v_valid;
end;
$$;

-- ------------------------------------------------------------
-- EVENTS
-- ------------------------------------------------------------
create or replace function add_club_event(
  p_officer_pin text,
  p_id text,
  p_title text,
  p_date date,
  p_time text,
  p_location text,
  p_type text,
  p_description text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to post events';
  end if;
  insert into club_events (id, title, date, time, location, type, description)
  values (p_id, p_title, p_date, p_time, p_location, coalesce(p_type,'general'), p_description);
end;
$$;

create or replace function delete_club_event(
  p_officer_pin text,
  p_id text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to delete events';
  end if;
  delete from club_events where id = p_id;
end;
$$;

-- ------------------------------------------------------------
-- NEWS
-- ------------------------------------------------------------
create or replace function add_club_news(
  p_officer_pin text,
  p_id text,
  p_title text,
  p_body text,
  p_author text,
  p_attachment_url text default null,
  p_attachment_name text default null,
  p_attachment_mime text default null,
  p_attachment_path text default null
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to post notices';
  end if;
  insert into club_news (id, title, body, author, attachment_url, attachment_name, attachment_mime, attachment_path)
  values (p_id, p_title, p_body, coalesce(p_author,'Club Secretary'), p_attachment_url, p_attachment_name, p_attachment_mime, p_attachment_path);
end;
$$;

create or replace function delete_club_news(
  p_officer_pin text,
  p_id text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to delete notices';
  end if;
  delete from club_news where id = p_id;
end;
$$;

-- ------------------------------------------------------------
-- POLLS
-- ------------------------------------------------------------
create or replace function add_club_poll(
  p_officer_pin text,
  p_id text,
  p_question text,
  p_options jsonb,
  p_ends_at text,
  p_created_by text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to create polls';
  end if;
  insert into club_polls (id, question, options, ends_at, created_by)
  values (p_id, p_question, p_options, p_ends_at, p_created_by);
end;
$$;

create or replace function delete_club_poll(
  p_officer_pin text,
  p_id text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to delete polls';
  end if;
  delete from club_polls where id = p_id;
end;
$$;

create or replace function vote_club_poll(
  p_member_pin text,
  p_poll_id text,
  p_option_id text,
  p_member_id text
) returns void
language plpgsql
security definer
as $$
declare
  v_member_id text;
  v_options jsonb;
  v_new_options jsonb;
  v_opt jsonb;
  v_votes jsonb;
begin
  select id into v_member_id from members where pin = p_member_pin limit 1;
  if v_member_id is null then
    raise exception 'Invalid member PIN';
  end if;

  select options into v_options from club_polls where id = p_poll_id;
  if v_options is null then
    raise exception 'Poll not found';
  end if;

  -- Remove this member's vote from every option, then add it to the chosen one.
  select jsonb_agg(
    case
      when opt->>'id' = p_option_id then
        jsonb_set(
          opt,
          '{votes}',
          (
            select coalesce(jsonb_agg(v), '[]'::jsonb)
            from (
              select distinct v
              from jsonb_array_elements_text(coalesce(opt->'votes','[]'::jsonb)) v
              where v <> v_member_id
              union
              select v_member_id
            ) sub(v)
          )
        )
      else
        jsonb_set(
          opt,
          '{votes}',
          coalesce(
            (select jsonb_agg(v) from jsonb_array_elements_text(coalesce(opt->'votes','[]'::jsonb)) v where v <> v_member_id),
            '[]'::jsonb
          )
        )
    end
  )
  into v_new_options
  from jsonb_array_elements(v_options) opt;

  update club_polls set options = v_new_options where id = p_poll_id;
end;
$$;

grant execute on function is_officer_pin(text) to anon, authenticated;
grant execute on function add_club_event(text, text, text, date, text, text, text, text) to anon, authenticated;
grant execute on function delete_club_event(text, text) to anon, authenticated;
grant execute on function add_club_news(text, text, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function delete_club_news(text, text) to anon, authenticated;
grant execute on function add_club_poll(text, text, text, jsonb, text, text) to anon, authenticated;
grant execute on function delete_club_poll(text, text) to anon, authenticated;
grant execute on function vote_club_poll(text, text, text, text) to anon, authenticated;

alter publication supabase_realtime add table club_events;
alter publication supabase_realtime add table club_news;
alter publication supabase_realtime add table club_polls;
