-- ============================================================
-- Oasis Club App — let record-keeping officers act with their OWN login.
--
-- Problem: officer-only actions (save minutes, upload meeting recordings,
-- record transactions, manage members, etc.) all gate on is_officer_pin(),
-- which previously accepted ONLY the three shared officer PINs
-- ('4821','7395','1064'). So an officer who signed in by their NAME (personal
-- PIN) was blocked from doing their own duties — the app sent their personal
-- PIN, which failed the check. That is confusing and easy to trip over.
--
-- Fix: is_officer_pin() now ALSO returns true when the PIN belongs to an
-- active member holding a record-keeping office (Secretary, Treasurer,
-- Financial Secretary) — the same three offices the shared PINs represent.
-- The three shared PINs keep working, so nothing that worked before breaks.
--
-- Scope note: only those three offices gain this. President, Vice-President,
-- PRO and Assistant Secretary are deliberately NOT granted officer powers
-- here. PINs are unique per member, so a PIN matches at most one member and
-- only that member's own role is considered.
--
-- Safe to re-run. Run this in the Supabase SQL editor.
-- ============================================================

create or replace function public.is_officer_pin(p_pin text)
returns boolean language sql security definer set search_path = public as $$
  select
    p_pin in ('4821','7395','1064')
    or exists (
      select 1 from public.members m
      where m.pin = p_pin
        and m.role in ('Secretary','Treasurer','Financial Secretary')
        and lower(coalesce(m.status,'active')) not in ('suspended','dismissed')
    );
$$;

grant execute on function public.is_officer_pin(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- Optional check afterwards (replace 7752 with any officer's personal PIN):
--   select public.is_officer_pin('7752');   -- expect: true
--   select public.is_officer_pin('0000');   -- expect: false
-- ------------------------------------------------------------
