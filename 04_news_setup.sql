-- ============================================================
-- Oasis Club App — News & Notices feature setup
-- Run this AFTER 01_setup.sql, 02_seed_data.sql, and
-- 03_constitution_setup.sql have already been run. Safe to re-run.
-- ============================================================

-- ============================================================
-- TABLE
-- Any member can submit a post. It starts 'pending' and only
-- becomes visible to everyone once a President or PRO approves it.
-- This app has no real per-user login (just shared PINs), so the
-- "pending posts are private" rule is enforced by the app's UI,
-- not by the database -- the same trust model already used for
-- member PINs elsewhere in this app.
-- ============================================================

create table if not exists public.news_posts (
  id uuid primary key default gen_random_uuid(),
  author_id text not null references public.members(id) on delete cascade,
  title text not null,
  body_html text not null,
  attachment_url text,
  attachment_name text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by text,
  reviewed_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now()
);

alter table public.news_posts enable row level security;

drop policy if exists "news_posts are publicly readable" on public.news_posts;
create policy "news_posts are publicly readable" on public.news_posts
  for select to anon, authenticated
  using (true);

-- ============================================================
-- STORAGE BUCKET for post attachments
-- Public bucket, same trust model as the constitution PDF bucket.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('news-attachments', 'news-attachments', true, 15728640, array[
  'image/jpeg','image/png','image/webp','image/gif',
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'text/plain'
])
on conflict (id) do update set
  public = true,
  file_size_limit = 15728640,
  allowed_mime_types = array[
    'image/jpeg','image/png','image/webp','image/gif',
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/plain'
  ];

drop policy if exists "news attachments are publicly readable" on storage.objects;
create policy "news attachments are publicly readable" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'news-attachments');

drop policy if exists "news attachments can be uploaded" on storage.objects;
create policy "news attachments can be uploaded" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'news-attachments');

-- ============================================================
-- HELPER: is this PIN currently held by the President or PRO?
-- Checked against the member's own personal PIN and current role,
-- since President/PRO are member roles, not officer-PIN logins.
-- ============================================================

create or replace function public.is_news_reviewer_pin(p_pin text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1 from members
    where pin = p_pin
    and role in ('President','PRO')
    and status not in ('suspended','dismissed')
  );
$$;

grant execute on function public.is_news_reviewer_pin(text) to anon, authenticated;

-- ============================================================
-- RPC: submit a new post. Any active member's own PIN works.
-- ============================================================

create or replace function public.submit_news_post(
  p_pin text,
  p_title text,
  p_body_html text,
  p_attachment_url text default null,
  p_attachment_name text default null
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

  if length(trim(p_title)) = 0 then
    raise exception 'Title cannot be empty';
  end if;

  insert into news_posts (author_id, title, body_html, attachment_url, attachment_name)
  values (v_member_id, trim(p_title), p_body_html, p_attachment_url, p_attachment_name)
  returning id into v_new_id;

  return v_new_id;
end;
$$;

grant execute on function public.submit_news_post(text,text,text,text,text) to anon, authenticated;

-- ============================================================
-- RPC: approve or reject a pending post. President/PRO PIN only.
-- ============================================================

create or replace function public.review_news_post(
  p_pin text,
  p_post_id uuid,
  p_decision text,
  p_rejection_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reviewer_id text;
begin
  if p_decision not in ('approved','rejected') then
    raise exception 'Decision must be approved or rejected';
  end if;

  select id into v_reviewer_id from members
  where pin = p_pin and role in ('President','PRO') and status not in ('suspended','dismissed');

  if v_reviewer_id is null then
    raise exception 'Only the President or PRO can review posts';
  end if;

  update news_posts
  set status = p_decision,
      reviewed_by = v_reviewer_id,
      reviewed_at = now(),
      rejection_reason = case when p_decision = 'rejected' then p_rejection_reason else null end
  where id = p_post_id and status = 'pending';

  if not found then
    raise exception 'Post not found or already reviewed';
  end if;
end;
$$;

grant execute on function public.review_news_post(text,uuid,text,text) to anon, authenticated;

-- ============================================================
-- RPC: delete a post. Author (their own pending/rejected post)
-- or an officer-login PIN can delete. Approved posts can only be
-- removed by an officer login, to prevent an author quietly
-- pulling something already published without anyone noticing.
-- ============================================================

create or replace function public.delete_news_post(
  p_pin text,
  p_post_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_post record;
  v_pin_member_id text;
begin
  select * into v_post from news_posts where id = p_post_id;
  if v_post is null then
    raise exception 'Post not found';
  end if;

  select id into v_pin_member_id from members where pin = p_pin;

  if is_officer_pin(p_pin) then
    delete from news_posts where id = p_post_id;
    return;
  end if;

  if v_pin_member_id = v_post.author_id and v_post.status <> 'approved' then
    delete from news_posts where id = p_post_id;
    return;
  end if;

  raise exception 'You can only remove your own post before it is approved';
end;
$$;

grant execute on function public.delete_news_post(text,uuid) to anon, authenticated;

-- ============================================================
-- REALTIME
-- ============================================================
alter publication supabase_realtime add table public.news_posts;

-- ============================================================
-- Done.
-- ============================================================
