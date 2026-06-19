-- ============================================================
-- Oasis Club — Secretary: Set Chatbot API Key
-- Run this once in Supabase SQL Editor, alongside the earlier files.
-- ============================================================

create or replace function secretary_set_chatbot_key(
  p_secretary_pin text,
  p_api_key text
) returns void
language plpgsql
security definer
as $$
begin
  if p_secretary_pin <> '4821' then
    -- also allow any member whose role is Secretary
    if not exists(select 1 from members where pin = p_secretary_pin and role = 'Secretary') then
      raise exception 'Only the Secretary can set the chatbot API key';
    end if;
  end if;

  update club_meta set chatbot_api_key = p_api_key where id = 1;

  if not found then
    insert into club_meta (id, chatbot_api_key) values (1, p_api_key);
  end if;
end;
$$;

grant execute on function secretary_set_chatbot_key(text, text) to anon, authenticated;
