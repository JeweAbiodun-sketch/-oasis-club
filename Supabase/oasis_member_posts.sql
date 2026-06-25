-- ============================================================
-- Oasis Club — Member Post Submission & PRO Approval
-- Run this once in Supabase SQL Editor.
-- ============================================================

-- 1. Table to hold posts submitted by members, pending PRO review.
create table if not exists club_news_pending (
  id text primary key,
  title text not null,
  body text not null,
  author text not null,
  submitted_by_member_id text not null,
  created_at timestamptz not null default now()
);
alter table club_news_pending add column if not exists attachment_url text;
alter table club_news_pending add column if not exists attachment_name text;
alter table club_news_pending add column if not exists attachment_mime text;
alter table club_news_pending add column if not exists attachment_path text;

alter table club_news_pending enable row level security;

-- Anyone (anon key) can read pending posts — needed so the PRO's
-- screen and the submitting member's "pending" view both work.
drop policy if exists "Allow read pending news" on club_news_pending;
create policy "Allow read pending news" on club_news_pending
  for select using (true);

-- Disallow direct table writes from the client; all writes go through
-- the functions below, which validate the member's PIN server-side.
revoke insert, update, delete on club_news_pending from anon, authenticated;

-- ------------------------------------------------------------
-- 2. Member submits a post (any member with a valid PIN can call this).
-- ------------------------------------------------------------
create or replace function submit_member_news(
  p_member_pin text,
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
declare
  v_member_id text;
begin
  select id into v_member_id from members where pin = p_member_pin limit 1;
  if v_member_id is null then
    raise exception 'Invalid member PIN';
  end if;

  insert into club_news_pending (id, title, body, author, submitted_by_member_id, attachment_url, attachment_name, attachment_mime, attachment_path)
  values (p_id, p_title, p_body, p_author, v_member_id, p_attachment_url, p_attachment_name, p_attachment_mime, p_attachment_path);
end;
$$;

-- ------------------------------------------------------------
-- 3. PRO (or any officer) approves a pending post —
--    moves it into the live club_news table.
-- ------------------------------------------------------------
create or replace function approve_member_news(
  p_officer_pin text,
  p_id text
) returns void
language plpgsql
security definer
as $$
declare
  v_row club_news_pending;
  v_valid boolean := false;
begin
  -- Accept the PRO/officer PIN if it matches any member whose role is 'PRO',
  -- OR any of the dedicated officer PINs already used elsewhere in the app.
  select exists(
    select 1 from members where pin = p_officer_pin and role = 'PRO'
  ) into v_valid;

  if not v_valid then
    raise exception 'Only the PRO can approve posts';
  end if;

  select * into v_row from club_news_pending where id = p_id;
  if v_row.id is null then
    raise exception 'Post not found';
  end if;

  insert into club_news (id, title, body, author, created_at, attachment_url, attachment_name, attachment_mime, attachment_path)
  values (v_row.id, v_row.title, v_row.body, v_row.author, v_row.created_at, v_row.attachment_url, v_row.attachment_name, v_row.attachment_mime, v_row.attachment_path);

  delete from club_news_pending where id = p_id;
end;
$$;

-- ------------------------------------------------------------
-- 4. PRO rejects a pending post — removes it without publishing.
-- ------------------------------------------------------------
create or replace function reject_member_news(
  p_officer_pin text,
  p_id text
) returns void
language plpgsql
security definer
as $$
declare
  v_valid boolean := false;
begin
  select exists(
    select 1 from members where pin = p_officer_pin and role = 'PRO'
  ) into v_valid;

  if not v_valid then
    raise exception 'Only the PRO can reject posts';
  end if;

  delete from club_news_pending where id = p_id;
end;
$$;

-- ------------------------------------------------------------
-- 5. Allow the anon/authenticated client roles to call these functions.
-- ------------------------------------------------------------
grant execute on function submit_member_news(text, text, text, text, text, text, text, text, text) to anon, authenticated;
grant execute on function approve_member_news(text, text) to anon, authenticated;
grant execute on function reject_member_news(text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 6. Enable realtime sync for the pending table (so PRO sees new
--    submissions live, same as everything else in the app).
-- ------------------------------------------------------------
alter publication supabase_realtime add table club_news_pending;
