-- ============================================================
-- Oasis Club App — Task board feature setup
-- Run this AFTER 01_setup.sql, 02_seed_data.sql, 03_constitution_setup.sql,
-- and 04_news_setup.sql have already been run. Safe to re-run.
-- ============================================================

-- ============================================================
-- TABLE
-- A simple shared task board: To Do / In Progress / Done, grouped
-- by a fixed category list, optionally assigned to one member.
-- Any active member can create, move, or delete any task -- this
-- is intentionally as open as Minutes or Finance entries already
-- are in this app, not officer-gated.
-- ============================================================

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  notes text,
  category text not null check (category in ('Building Project','Events','Admin','Welfare','General')),
  status text not null default 'todo' check (status in ('todo','in_progress','done')),
  assignee_id text references public.members(id) on delete set null,
  created_by text references public.members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.tasks enable row level security;

drop policy if exists "tasks are publicly readable" on public.tasks;
create policy "tasks are publicly readable" on public.tasks
  for select to anon, authenticated
  using (true);

-- ============================================================
-- RPC: create a task. Any active member's own PIN works.
-- ============================================================

create or replace function public.create_task(
  p_pin text,
  p_title text,
  p_category text,
  p_notes text default null,
  p_assignee_id text default null
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

  if p_category not in ('Building Project','Events','Admin','Welfare','General') then
    raise exception 'Not a recognized category';
  end if;

  insert into tasks (title, notes, category, assignee_id, created_by)
  values (trim(p_title), p_notes, p_category, p_assignee_id, v_member_id)
  returning id into v_new_id;

  return v_new_id;
end;
$$;

grant execute on function public.create_task(text,text,text,text,text) to anon, authenticated;

-- ============================================================
-- RPC: update a task (title, notes, category, status, assignee).
-- Pass the current value for any field you don't want to change.
-- Any active member's own PIN works -- task boards work best when
-- anyone can pitch in and move things along.
-- ============================================================

create or replace function public.update_task(
  p_pin text,
  p_task_id uuid,
  p_title text,
  p_notes text,
  p_category text,
  p_status text,
  p_assignee_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id text;
begin
  select id into v_member_id from members
  where pin = p_pin and status not in ('suspended','dismissed');

  if v_member_id is null then
    raise exception 'PIN not recognized, or this member no longer has access';
  end if;

  if length(trim(p_title)) = 0 then
    raise exception 'Title cannot be empty';
  end if;

  if p_category not in ('Building Project','Events','Admin','Welfare','General') then
    raise exception 'Not a recognized category';
  end if;

  if p_status not in ('todo','in_progress','done') then
    raise exception 'Not a recognized status';
  end if;

  update tasks set
    title = trim(p_title),
    notes = p_notes,
    category = p_category,
    status = p_status,
    assignee_id = p_assignee_id,
    updated_at = now()
  where id = p_task_id;

  if not found then
    raise exception 'Task not found';
  end if;
end;
$$;

grant execute on function public.update_task(text,uuid,text,text,text,text,text) to anon, authenticated;

-- ============================================================
-- RPC: delete a task. Any active member's own PIN, or an officer
-- login, can delete -- matches the open editing model above.
-- ============================================================

create or replace function public.delete_task(
  p_pin text,
  p_task_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id text;
begin
  select id into v_member_id from members
  where pin = p_pin and status not in ('suspended','dismissed');

  if v_member_id is null and not is_officer_pin(p_pin) then
    raise exception 'PIN not recognized, or this member no longer has access';
  end if;

  delete from tasks where id = p_task_id;

  if not found then
    raise exception 'Task not found';
  end if;
end;
$$;

grant execute on function public.delete_task(text,uuid) to anon, authenticated;

-- ============================================================
-- REALTIME
-- ============================================================
alter publication supabase_realtime add table public.tasks;

-- ============================================================
-- Done.
-- ============================================================
