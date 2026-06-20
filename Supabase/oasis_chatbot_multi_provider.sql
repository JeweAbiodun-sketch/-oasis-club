-- ============================================================
-- Oasis Club — Chatbot: support Anthropic, OpenAI, Cohere, Gemini
-- Run this once in Supabase SQL Editor.
-- ============================================================

alter table club_meta add column if not exists chatbot_provider text default 'anthropic';

-- Remove the old 2-parameter version so there's only one signature for this function.
drop function if exists secretary_set_chatbot_key(text, text);

create or replace function secretary_set_chatbot_key(
  p_secretary_pin text,
  p_api_key text,
  p_provider text default 'anthropic'
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

  if p_provider not in ('anthropic','openai','cohere','gemini') then
    raise exception 'Unknown provider: %', p_provider;
  end if;

  update club_meta
  set chatbot_api_key = p_api_key,
      chatbot_provider = p_provider
  where id = 1;

  if not found then
    insert into club_meta (id, chatbot_api_key, chatbot_provider) values (1, p_api_key, p_provider);
  end if;
end;
$$;

grant execute on function secretary_set_chatbot_key(text, text, text) to anon, authenticated;
