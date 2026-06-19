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

  insert into club_meta (id) values (1) on conflict (id) do nothing;
  update club_meta
     set chatbot_api_key = p_api_key,
         chatbot_api_provider = case
           when p_api_key ~* '^sk-ant-' then 'anthropic'
           when p_api_key ~* '^(cohere-|co-)' then 'cohere'
           else 'gemini'
         end
   where id = 1;

  if not found then
    insert into club_meta (id, chatbot_api_key, chatbot_api_provider)
    values (1, p_api_key, case
      when p_api_key ~* '^sk-ant-' then 'anthropic'
      when p_api_key ~* '^(cohere-|co-)' then 'cohere'
      else 'gemini'
    end);
  end if;
end;
$$;

grant execute on function secretary_set_chatbot_key(text, text) to anon, authenticated;

create or replace function secretary_set_chatbot_config(
  p_secretary_pin text,
  p_provider text,
  p_api_key text
) returns void
language plpgsql
security definer
as $$
begin
  if p_secretary_pin <> '4821' then
    if not exists(select 1 from members where pin = p_secretary_pin and role = 'Secretary') then
      raise exception 'Only the Secretary can set the chatbot API key';
    end if;
  end if;

  insert into club_meta (id) values (1) on conflict (id) do nothing;
  update club_meta
     set chatbot_api_key = coalesce(p_api_key, ''),
         chatbot_api_provider = case lower(coalesce(p_provider, ''))
           when 'anthropic' then 'anthropic'
           when 'cohere' then 'cohere'
           else 'gemini'
         end
   where id = 1;
end;
$$;

grant execute on function secretary_set_chatbot_config(text, text, text) to anon, authenticated;
