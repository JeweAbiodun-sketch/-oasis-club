-- ============================================================
-- Oasis Club App — Fix "could not choose the best candidate
-- function" error when approving payment evidence.
--
-- Cause: the live database has TWO overloads of
--   approve_payment_evidence:
--     (p_pin text, p_submission_id text)   <- old, stray copy
--     (p_pin text, p_submission_id uuid)   <- correct copy
-- When the app sends the submission id as a string, Postgres can
-- cast it to either text OR uuid, so PostgREST cannot decide which
-- one to call and aborts the approval.
--
-- Fix: drop the old (text,text) overload. The correct (text,uuid)
-- version defined in 06/11/12 is left untouched.
--
-- Safe to run: "if exists" means it does nothing if the stray copy
-- is already gone. It never touches the (text,uuid) version.
-- Run this in the Supabase SQL editor.
-- ============================================================

drop function if exists public.approve_payment_evidence(text, text);

-- Tell PostgREST to refresh its schema cache so the change is live.
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- Optional verification: after running the above, run this SELECT
-- on its own. It should return EXACTLY ONE row, with arg types
-- "text, uuid".
-- ------------------------------------------------------------
-- select p.oid::regprocedure as signature,
--        pg_get_function_arguments(p.oid) as args
-- from pg_proc p
-- join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public'
--   and p.proname = 'approve_payment_evidence';
