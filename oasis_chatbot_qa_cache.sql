-- ============================================================
-- Oasis Club — Chatbot Q&A Cache
-- Stores successful AI answers so similar future questions can
-- be answered even when the API key is missing or failing.
-- Run this once in Supabase SQL Editor.
-- ============================================================

create table if not exists asst_qa_cache (
  id text primary key,
  question text not null,
  question_keywords text not null,   -- normalized, space-separated keywords for fuzzy matching
  answer text not null,
  hit_count integer not null default 0,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);

alter table asst_qa_cache enable row level security;

drop policy if exists "Allow read asst_qa_cache" on asst_qa_cache;
create policy "Allow read asst_qa_cache" on asst_qa_cache for select using (true);

-- No officer gating here — any logged-in session (member or officer) can
-- contribute a cached answer, since this just mirrors questions members
-- are already allowed to ask the assistant.
revoke insert, update, delete on asst_qa_cache from anon, authenticated;

create or replace function save_asst_qa(
  p_id text,
  p_question text,
  p_question_keywords text,
  p_answer text
) returns void
language plpgsql
security definer
as $$
begin
  insert into asst_qa_cache (id, question, question_keywords, answer)
  values (p_id, p_question, p_question_keywords, p_answer);
end;
$$;

create or replace function bump_asst_qa_hit(
  p_id text
) returns void
language plpgsql
security definer
as $$
begin
  update asst_qa_cache
  set hit_count = hit_count + 1, last_used_at = now()
  where id = p_id;
end;
$$;

grant execute on function save_asst_qa(text, text, text, text) to anon, authenticated;
grant execute on function bump_asst_qa_hit(text) to anon, authenticated;

alter publication supabase_realtime add table asst_qa_cache;
