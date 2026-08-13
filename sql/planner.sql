-- Planner support for the Stock Submission System
-- Run once against the Supabase project (SQL editor) before deploying planner.html.
--
-- The planner books two kinds of calendar entry:
--   * entry_type = 'job'  — a planned stock job, completed via stock-entry.html
--   * entry_type = 'task' — a miscellaneous task that needs no stock entry
-- Both live in prefilled_jobs so the calendar, the home "Upcoming Jobs" widget
-- and the existing stock-entry pre-fill flow all read one table.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------

ALTER TABLE public.prefilled_jobs
    ADD COLUMN IF NOT EXISTS entry_type   text NOT NULL DEFAULT 'job',
    ADD COLUMN IF NOT EXISTS title        text,
    ADD COLUMN IF NOT EXISTS planned_time time;

COMMENT ON COLUMN public.prefilled_jobs.entry_type IS
    '''job'' = planned stock job (client/vendor/job_number required), ''task'' = misc task (title required)';
COMMENT ON COLUMN public.prefilled_jobs.title IS
    'Display title for entry_type = ''task''. Null for jobs, which display job_number.';
COMMENT ON COLUMN public.prefilled_jobs.planned_time IS
    'Optional time of day the entry is booked for. Null = unscheduled within the day.';

-- Tasks carry no client or job number, so those columns must be nullable.
ALTER TABLE public.prefilled_jobs ALTER COLUMN client_id  DROP NOT NULL;
ALTER TABLE public.prefilled_jobs ALTER COLUMN job_number DROP NOT NULL;

-- Every entry is booked onto a calendar date.
UPDATE public.prefilled_jobs SET planned_date = created_at::date WHERE planned_date IS NULL;
ALTER TABLE public.prefilled_jobs ALTER COLUMN planned_date SET NOT NULL;
ALTER TABLE public.prefilled_jobs ALTER COLUMN planned_date SET DEFAULT CURRENT_DATE;

-- ---------------------------------------------------------------------------
-- 2. Integrity
-- ---------------------------------------------------------------------------

ALTER TABLE public.prefilled_jobs DROP CONSTRAINT IF EXISTS prefilled_jobs_entry_type_check;
ALTER TABLE public.prefilled_jobs
    ADD CONSTRAINT prefilled_jobs_entry_type_check
    CHECK (entry_type IN ('job', 'task'));

-- A job needs a client + job number; a task needs a title. The UI enforces this
-- too, but the DB is the boundary that actually holds.
ALTER TABLE public.prefilled_jobs DROP CONSTRAINT IF EXISTS prefilled_jobs_shape_check;
ALTER TABLE public.prefilled_jobs
    ADD CONSTRAINT prefilled_jobs_shape_check
    CHECK (
        (entry_type = 'job'  AND client_id IS NOT NULL AND job_number IS NOT NULL)
     OR (entry_type = 'task' AND title IS NOT NULL AND length(btrim(title)) > 0)
    );

-- Tasks are never completed through stock entry.
ALTER TABLE public.prefilled_jobs DROP CONSTRAINT IF EXISTS prefilled_jobs_task_no_job_check;
ALTER TABLE public.prefilled_jobs
    ADD CONSTRAINT prefilled_jobs_task_no_job_check
    CHECK (entry_type = 'job' OR completed_job_id IS NULL);

-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------

-- The planner queries a date window per depot; the widget queries the same
-- window filtered to one agent.
CREATE INDEX IF NOT EXISTS prefilled_jobs_depot_date_idx
    ON public.prefilled_jobs (depot_id, planned_date);
CREATE INDEX IF NOT EXISTS prefilled_jobs_depot_agent_date_idx
    ON public.prefilled_jobs (depot_id, assigned_agent_id, planned_date);

-- ---------------------------------------------------------------------------
-- 4. Row Level Security
-- ---------------------------------------------------------------------------
-- The planner and the "Upcoming Jobs" widget are depot-wide for every role, so
-- SELECT must be scoped to the caller's depot rather than to auth.uid().
-- Writes stay narrower: technicians may only touch entries assigned to their own
-- agent, managers and super_admins may touch anything in their depot.

ALTER TABLE public.prefilled_jobs ENABLE ROW LEVEL SECURITY;

-- Helper predicates, kept as functions so the policies stay readable.
CREATE OR REPLACE FUNCTION public.current_depot_id()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT depot_id FROM public.user_roles WHERE user_id = auth.uid() $$;

CREATE OR REPLACE FUNCTION public.current_agent_id()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT agent_id FROM public.user_roles WHERE user_id = auth.uid() $$;

CREATE OR REPLACE FUNCTION public.current_is_manager()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = auth.uid() AND role IN ('manager', 'super_admin')
     ) $$;

DROP POLICY IF EXISTS prefilled_jobs_select ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_select ON public.prefilled_jobs
    FOR SELECT TO authenticated
    USING (depot_id = public.current_depot_id());

DROP POLICY IF EXISTS prefilled_jobs_insert ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_insert ON public.prefilled_jobs
    FOR INSERT TO authenticated
    WITH CHECK (
        depot_id = public.current_depot_id()
        AND user_id = auth.uid()
        AND (public.current_is_manager() OR assigned_agent_id = public.current_agent_id())
    );

DROP POLICY IF EXISTS prefilled_jobs_update ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_update ON public.prefilled_jobs
    FOR UPDATE TO authenticated
    USING (
        depot_id = public.current_depot_id()
        AND (public.current_is_manager() OR assigned_agent_id = public.current_agent_id())
    )
    WITH CHECK (
        depot_id = public.current_depot_id()
        AND (public.current_is_manager() OR assigned_agent_id = public.current_agent_id())
    );

DROP POLICY IF EXISTS prefilled_jobs_delete ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_delete ON public.prefilled_jobs
    FOR DELETE TO authenticated
    USING (
        depot_id = public.current_depot_id()
        AND (public.current_is_manager() OR assigned_agent_id = public.current_agent_id())
    );
