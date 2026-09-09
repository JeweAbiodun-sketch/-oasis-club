-- ============================================================
-- Oasis Club App — Fix "could not choose the best candidate
-- function" error when SAVING MEETING MINUTES.
--
-- Cause: the live database has TWO overloads of officer_add_minutes:
--     (p_officer_pin text, p_id text, p_title text, p_date DATE, p_type text, p_notes text)  <- stray copy
--     (p_officer_pin text, p_id text, p_title text, p_date TEXT, p_type text, p_notes text)  <- correct copy
-- (This happens when CREATE OR REPLACE is run with a changed parameter
--  type — Postgres makes a NEW overload instead of replacing.)
-- The app sends p_date as a string, which Postgres can match to TEXT
-- or cast to DATE, so PostgREST cannot decide which to call and every
-- "Save minutes" fails for everyone — regardless of how they log in.
--
-- Fix: drop the stray (…, date, …) overload. The correct (…, text, …)
-- version — which casts p_date::date internally — is left untouched.
--
-- Safe to run: "if exists" does nothing if the stray copy is already
-- gone, and it never touches the (…, text, …) version.
-- Run this in the Supabase SQL editor.
-- ============================================================

drop function if exists public.officer_add_minutes(text, text, text, date, text, text);

-- Tell PostgREST to refresh its schema cache so the change is live.
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- Optional verification: run this SELECT on its own afterwards.
-- It should return EXACTLY ONE row, whose args end in "..., text, text".
-- ------------------------------------------------------------
-- select p.oid::regprocedure as signature,
--        pg_get_function_arguments(p.oid) as args
-- from pg_proc p
-- join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public'
--   and p.proname = 'officer_add_minutes';
