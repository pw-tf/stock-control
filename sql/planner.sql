-- Planner support for the Stock Submission System
-- Run once against the Supabase project (SQL editor) before deploying planner.html.
--
-- The planner books three kinds of calendar entry:
--   * entry_type = 'job'  — a planned stock job, completed via stock-entry.html
--   * entry_type = 'task' — a to-do that needs no stock entry, ticked off in the UI
--   * entry_type = 'misc' — a non-work marker (leave, training, vehicle off the
--                           road, public holiday). Never completed, never overdue
-- All three live in prefilled_jobs so the calendar, the home "Upcoming Jobs"
-- widget and the existing stock-entry pre-fill flow read one table.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------

ALTER TABLE public.prefilled_jobs
    ADD COLUMN IF NOT EXISTS entry_type   text NOT NULL DEFAULT 'job',
    ADD COLUMN IF NOT EXISTS title        text,
    ADD COLUMN IF NOT EXISTS planned_time time,
    ADD COLUMN IF NOT EXISTS end_date     date;

COMMENT ON COLUMN public.prefilled_jobs.entry_type IS
    '''job'' = planned stock job (client/vendor/job_number required), ''task'' = to-do (title required), ''misc'' = non-work marker (title required, never completed)';
COMMENT ON COLUMN public.prefilled_jobs.title IS
    'Display title for tasks and misc entries. Null for jobs, which display job_number.';
COMMENT ON COLUMN public.prefilled_jobs.planned_time IS
    'Optional time of day the entry is booked for. Null = unscheduled within the day.';
COMMENT ON COLUMN public.prefilled_jobs.end_date IS
    'Optional last day of a multi-day task or misc entry. Null = single day (planned_date). Jobs are always single-day.';

-- Tasks and misc entries carry no client or job number, so those columns must
-- be nullable.
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
    CHECK (entry_type IN ('job', 'task', 'misc'));

-- A job needs a client + job number; a task or misc entry needs a title. The UI
-- enforces this too, but the DB is the boundary that actually holds.
ALTER TABLE public.prefilled_jobs DROP CONSTRAINT IF EXISTS prefilled_jobs_shape_check;
ALTER TABLE public.prefilled_jobs
    ADD CONSTRAINT prefilled_jobs_shape_check
    CHECK (
        (entry_type = 'job' AND client_id IS NOT NULL AND job_number IS NOT NULL)
     OR (entry_type IN ('task', 'misc') AND title IS NOT NULL AND length(btrim(title)) > 0)
    );

-- Only a job is ever completed through stock entry.
ALTER TABLE public.prefilled_jobs DROP CONSTRAINT IF EXISTS prefilled_jobs_task_no_job_check;
ALTER TABLE public.prefilled_jobs
    ADD CONSTRAINT prefilled_jobs_task_no_job_check
    CHECK (entry_type = 'job' OR completed_job_id IS NULL);

-- A misc entry is a marker, not work: it is never ticked off.
ALTER TABLE public.prefilled_jobs DROP CONSTRAINT IF EXISTS prefilled_jobs_misc_not_completed_check;
ALTER TABLE public.prefilled_jobs
    ADD CONSTRAINT prefilled_jobs_misc_not_completed_check
    CHECK (entry_type <> 'misc' OR is_completed = false);

-- Only tasks and misc entries span days, and a range never runs backwards. Jobs
-- stay single-day: one job is worked on one day, under one box.
ALTER TABLE public.prefilled_jobs DROP CONSTRAINT IF EXISTS prefilled_jobs_end_date_check;
ALTER TABLE public.prefilled_jobs
    ADD CONSTRAINT prefilled_jobs_end_date_check
    CHECK (end_date IS NULL OR (entry_type <> 'job' AND end_date >= planned_date));

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
-- Every policy is scoped to the caller's depot first. Within the depot:
--   * managers and super_admins see and write anything (the Depot view)
--   * technicians see and write only entries assigned to their own agent, plus
--     unassigned tasks and misc entries — depot-wide items (a shared chore, a
--     public holiday) that belong to no one agent
-- Reads are deliberately as narrow as writes: a technician has no depot view in
-- the UI, so nothing should hand them another agent's rows to read either.

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

-- May the caller touch this row (read or write)? Managers: anything in their
-- depot. Everyone else: their own agent's entries, plus any unassigned entry —
-- which only a task or misc row can be, since a job always carries an agent.
CREATE OR REPLACE FUNCTION public.can_write_planner_entry(entry_agent text, entry_kind text)
RETURNS boolean
LANGUAGE sql STABLE
AS $$ SELECT public.current_is_manager()
          OR entry_agent = public.current_agent_id()
          OR (entry_agent IS NULL AND entry_kind <> 'job') $$;

DROP POLICY IF EXISTS prefilled_jobs_select ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_select ON public.prefilled_jobs
    FOR SELECT TO authenticated
    USING (
        depot_id = public.current_depot_id()
        AND public.can_write_planner_entry(assigned_agent_id, entry_type)
    );

DROP POLICY IF EXISTS prefilled_jobs_insert ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_insert ON public.prefilled_jobs
    FOR INSERT TO authenticated
    WITH CHECK (
        depot_id = public.current_depot_id()
        AND user_id = auth.uid()
        AND public.can_write_planner_entry(assigned_agent_id, entry_type)
    );

DROP POLICY IF EXISTS prefilled_jobs_update ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_update ON public.prefilled_jobs
    FOR UPDATE TO authenticated
    USING (
        depot_id = public.current_depot_id()
        AND public.can_write_planner_entry(assigned_agent_id, entry_type)
    )
    WITH CHECK (
        depot_id = public.current_depot_id()
        AND public.can_write_planner_entry(assigned_agent_id, entry_type)
    );

DROP POLICY IF EXISTS prefilled_jobs_delete ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_delete ON public.prefilled_jobs
    FOR DELETE TO authenticated
    USING (
        depot_id = public.current_depot_id()
        AND public.can_write_planner_entry(assigned_agent_id, entry_type)
    );
