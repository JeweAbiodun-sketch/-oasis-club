-- ============================================================
-- Oasis Club App — Task status restriction
-- Run this against the live database. Safe to re-run.
--
-- Previously, update_task() let any active member's PIN change a
-- task's status, regardless of who it was assigned to -- the only
-- thing stopping a misclick was the button being shown on the board,
-- which is a UI convenience, not real enforcement (anyone could still
-- call the underlying RPC directly). This closes that gap to match
-- what the front end now does: only the member a task is assigned to
-- can change its status; for an unassigned task, only whoever created
-- it can. By request, there is no officer-PIN override for this --
-- officer sessions have no personal member identity, so they were
-- never able to satisfy this check anyway, the same way they can't
-- satisfy is_treasurer_session-style member-identity checks elsewhere.
--
-- Title, category, notes, and reassignment are all UNCHANGED -- still
-- open to any active member, same as before. This only gates the
-- status field specifically.
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
as $function$
declare
  v_member_id text;
  v_task tasks;
  v_controller_id text;
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

  select * into v_task from tasks where id = p_task_id;
  if v_task.id is null then
    raise exception 'Task not found';
  end if;

  -- Only enforce the ownership check if the status is actually changing.
  -- Editing title/category/notes/assignee without touching status is
  -- unaffected, same as before.
  if p_status <> v_task.status then
    v_controller_id := coalesce(v_task.assignee_id, v_task.created_by);
    if v_controller_id is null or v_controller_id <> v_member_id then
      raise exception 'Only the member this task is assigned to (or whoever added it, if unassigned) can change its status';
    end if;
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
$function$;
