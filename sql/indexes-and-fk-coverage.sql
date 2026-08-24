-- Index maintenance
-- =================
-- APPLIED to the Serial Tracker project (lfydtctndrzzdyavmlva) on 2026-08-24 as
-- migration 20260824_add_missing_fk_indexes. Idempotent; safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Covering indexes for unindexed foreign keys
-- ---------------------------------------------------------------------------
-- Without these, Postgres scans the child table to enforce ON DELETE/ON UPDATE,
-- and the joins the app makes across these columns have no index either.

CREATE INDEX IF NOT EXISTS depot_clients_client_id_idx
    ON public.depot_clients (client_id);
CREATE INDEX IF NOT EXISTS invitation_tokens_created_by_idx
    ON public.invitation_tokens (created_by);
CREATE INDEX IF NOT EXISTS invitation_tokens_depot_id_idx
    ON public.invitation_tokens (depot_id);
CREATE INDEX IF NOT EXISTS prefilled_jobs_completed_job_id_idx
    ON public.prefilled_jobs (completed_job_id);
CREATE INDEX IF NOT EXISTS prefilled_jobs_user_id_idx
    ON public.prefilled_jobs (user_id);
CREATE INDEX IF NOT EXISTS user_roles_depot_id_idx
    ON public.user_roles (depot_id);

-- ---------------------------------------------------------------------------
-- 2. The ten "unused" indexes — deliberately NOT dropped
-- ---------------------------------------------------------------------------
-- Supabase's performance advisor reports these as never scanned:
--
--   idx_boxes_client              idx_jobs_job_number
--   idx_serials_created_at        idx_shifts_agent_id
--   idx_agents_depot              idx_boxes_depot
--   idx_user_roles_userid_role    idx_invitation_tokens_email
--   idx_invitation_tokens_expires idx_clients_vendors_depot
--
-- The statistics behind that are trustworthy on their own terms — pg_stat has
-- been accumulating for 259 days. They are still the wrong basis for a drop
-- right now, because sql/rls-hardening.sql has just changed the shape of every
-- query in the system: each one now carries a depot_id (or user_id) predicate
-- injected by RLS that did not exist when those counters were gathered.
-- Four of the ten sit exactly on those columns.
--
-- The upside of dropping them is negligible at this size (1.1k jobs, 1.8k
-- serials, 85 boxes — tens of kilobytes of index), so there is nothing to buy
-- and a regression to risk.
--
-- Revisit after a few weeks of real traffic on the new policies:
--
--   SELECT relname, indexrelname, idx_scan
--   FROM pg_stat_user_indexes
--   WHERE schemaname = 'public' AND idx_scan = 0
--   ORDER BY relname;
--
-- Anything still at zero then is genuinely dead and can go.
