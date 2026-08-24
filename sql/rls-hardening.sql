-- RLS hardening for the Stock Submission System
-- =============================================
-- Run once in the Supabase SQL editor. Idempotent and safe to re-run.
-- The rollback for this file is sql/rls-hardening-rollback.sql.
--
-- WHY
-- ---
-- CLAUDE.md states that "RLS is the real enforcement boundary … policies must
-- enforce depot scoping and role permissions on every table". Before this file
-- that was true only of prefilled_jobs and user_widget_config. Everything else
-- was open in one of three ways:
--
--   * jobs, serials and boxes each carried a policy
--       FOR ALL TO public USING (true) WITH CHECK (true)
--     Role `public` includes `anon`, and `anon` held full DML grants, so anyone
--     with the publishable anon key from auth.js — which is served to every
--     visitor — could read, alter or delete every job, serial and box in every
--     depot without signing in. Permissive policies OR together, so the
--     narrower sibling policies on those tables added no protection at all.
--
--   * user_roles.managers_full_access was USING/WITH CHECK is_manager() with no
--     depot predicate and no column restriction, so any manager could run
--     UPDATE user_roles SET role='super_admin' on their own row.
--
--   * depots."Managers can manage depots" was USING (auth.role() =
--     'authenticated') — despite the name it never checked the role, so any
--     signed-in user could create, rename or delete depots.
--
-- Shifts, agents, depot_clients and clients_vendors were role-checked but never
-- depot-checked, so a manager in one depot reached another depot's data.
--
-- THE MODEL
-- ---------
-- One policy per command, TO authenticated only, shaped as:
--
--   super_admin  unrestricted across all depots
--   manager      anything within their own depot_id
--   technician   reads within their own depot; writes limited to rows under
--                their own agent
--
-- Reads are depot-wide rather than agent-wide on purpose. That is what the app
-- already does and depends on: the duplicate-serial check in utils.js is
-- documented as "checked per-depot scope", and inventory.html offers every
-- agent in the depot in its search filter to technicians as well as managers.
-- Ownership is enforced on writes, which mirrors the `canEdit` checks in
-- inventory.html (a technician may edit or delete only their own agent's rows).
--
-- vendors and clients stay global by design — CLAUDE.md describes vendors as a
-- "shared catalogue across depots", and clients is the global registry that
-- depot_clients refines. Depot separation for those lives in depot_clients and
-- clients_vendors, which are scoped here.
--
-- auth.uid() is wrapped as (SELECT auth.uid()) throughout so Postgres evaluates
-- it once per query as an InitPlan instead of once per row.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Helper predicates
-- ---------------------------------------------------------------------------
-- current_depot_id(), current_agent_id() and current_is_manager() already exist
-- from sql/planner.sql. These add the super_admin predicate the depot model
-- needs, and re-declare the three legacy helpers with a pinned search_path —
-- they were SECURITY DEFINER with a mutable search_path, which Supabase's
-- linter flags, and VOLATILE, which made them re-execute for every row.

CREATE OR REPLACE FUNCTION public.current_is_super_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = (SELECT auth.uid()) AND role = 'super_admin'
     ) $$;

CREATE OR REPLACE FUNCTION public.is_manager()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = (SELECT auth.uid()) AND role IN ('manager', 'super_admin')
     ) $$;

CREATE OR REPLACE FUNCTION public.is_staff()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = (SELECT auth.uid())
          AND role IN ('technician', 'manager', 'super_admin')
     ) $$;

CREATE OR REPLACE FUNCTION public.is_current_user_manager()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT EXISTS (
        SELECT 1 FROM public.user_roles
        WHERE user_id = (SELECT auth.uid()) AND role = 'manager'
     ) $$;

-- May the caller see rows belonging to this depot? Super admins reach every
-- depot; everyone else is confined to their own. A null depot on either side
-- never matches, so a user without a depot row sees nothing.
CREATE OR REPLACE FUNCTION public.can_read_depot(target_depot text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT public.current_is_super_admin()
          OR (target_depot IS NOT NULL
              AND target_depot = public.current_depot_id()) $$;

-- May the caller write rows belonging to this depot, regardless of agent?
-- Managers and super admins only — a technician's writes go through
-- can_write_box() / the per-table agent checks instead.
CREATE OR REPLACE FUNCTION public.can_write_depot(target_depot text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT public.current_is_super_admin()
          OR (public.current_is_manager()
              AND target_depot IS NOT NULL
              AND target_depot = public.current_depot_id()) $$;

-- May the caller write rows hanging off this box? Jobs and serials carry no
-- agent of their own — they inherit it from the box they belong to.
CREATE OR REPLACE FUNCTION public.can_write_box(target_box bigint)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT EXISTS (
        SELECT 1 FROM public.boxes b
        WHERE b.id = target_box
          AND (public.can_write_depot(b.depot_id)
               OR (b.depot_id = public.current_depot_id()
                   AND b.agent = public.current_agent_id()))
     ) $$;

-- The job id embedded in a receipt filename. Receipts are uploaded as
-- "{timestamp}-{jobId}.jpg" (uploadReceiptToStorage in stock-entry.html), and
-- that is the only link back to a depot at upload time — the job row exists but
-- its receipt_url is not set until the upload succeeds.
CREATE OR REPLACE FUNCTION public.receipt_job_id(object_name text)
RETURNS bigint
LANGUAGE sql IMMUTABLE
AS $$ SELECT (regexp_match(object_name, '^[0-9]+-([0-9]+)\.jpg$'))[1]::bigint $$;

-- Strict: the receipt's job must exist and sit in the caller's depot.
CREATE OR REPLACE FUNCTION public.can_read_receipt(object_name text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT EXISTS (
        SELECT 1 FROM public.jobs j
        WHERE j.id = public.receipt_job_id(object_name)
          AND public.can_read_depot(j.depot_id)
     ) $$;

-- Deletion is the same test, but also allows a file whose job row has already
-- gone. That keeps orphan cleanup possible and stops the policy depending on
-- whether the client removes the file before or after deleting the job.
CREATE OR REPLACE FUNCTION public.can_delete_receipt(object_name text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT public.is_staff()
          AND COALESCE(
                (SELECT public.can_read_depot(j.depot_id)
                   FROM public.jobs j
                  WHERE j.id = public.receipt_job_id(object_name)),
                true) $$;

-- The role and depot a user row currently holds. Used by the user_roles UPDATE
-- policy: WITH CHECK sees only the proposed row, so this reads the pre-update
-- value (a STABLE function runs against the statement's snapshot) to prove the
-- privileged columns are unchanged.
CREATE OR REPLACE FUNCTION public.existing_user_role(target_user uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT role FROM public.user_roles WHERE user_id = target_user $$;

CREATE OR REPLACE FUNCTION public.existing_user_depot(target_user uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT depot_id FROM public.user_roles WHERE user_id = target_user $$;

CREATE OR REPLACE FUNCTION public.existing_user_agent(target_user uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT agent_id FROM public.user_roles WHERE user_id = target_user $$;

CREATE OR REPLACE FUNCTION public.existing_user_shifts_enabled(target_user uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT shifts_enabled FROM public.user_roles WHERE user_id = target_user $$;

-- ---------------------------------------------------------------------------
-- 2. Drop every legacy policy
-- ---------------------------------------------------------------------------
-- Permissive policies OR together, so a single leftover `USING (true)` would
-- undo everything below. These must all go.

DROP POLICY IF EXISTS "Allow all operations on boxes"                 ON public.boxes;
DROP POLICY IF EXISTS "Authenticated users can read boxes"            ON public.boxes;
DROP POLICY IF EXISTS "Technicians and managers can insert boxes"     ON public.boxes;
DROP POLICY IF EXISTS "Technicians and managers can update boxes"     ON public.boxes;

DROP POLICY IF EXISTS "Allow all operations on jobs"                  ON public.jobs;
DROP POLICY IF EXISTS "Authenticated users can read jobs"             ON public.jobs;
DROP POLICY IF EXISTS "Technicians and managers can manage jobs"      ON public.jobs;

DROP POLICY IF EXISTS "Allow all operations on serials"               ON public.serials;
DROP POLICY IF EXISTS "Authenticated users can read serials"          ON public.serials;
DROP POLICY IF EXISTS "Technicians and managers can manage serials"   ON public.serials;

DROP POLICY IF EXISTS "Users can view own shifts"                     ON public.shifts;
DROP POLICY IF EXISTS "Users can insert own shifts"                   ON public.shifts;
DROP POLICY IF EXISTS "Users can update own shifts"                   ON public.shifts;
DROP POLICY IF EXISTS "Managers can view all shifts"                  ON public.shifts;
DROP POLICY IF EXISTS "Managers can update any shift"                 ON public.shifts;

DROP POLICY IF EXISTS "Authenticated users can read agents"           ON public.agents;
DROP POLICY IF EXISTS "Managers can manage agents"                    ON public.agents;

DROP POLICY IF EXISTS "Authenticated users can read clients"          ON public.clients;
DROP POLICY IF EXISTS "Managers can manage clients"                   ON public.clients;

DROP POLICY IF EXISTS "Authenticated users can read vendors"          ON public.vendors;
DROP POLICY IF EXISTS "Managers can manage vendors"                   ON public.vendors;

DROP POLICY IF EXISTS "Authenticated users can read depot_clients"    ON public.depot_clients;
DROP POLICY IF EXISTS "Managers can manage depot_clients"             ON public.depot_clients;

DROP POLICY IF EXISTS "Allow authenticated users to read clients_vendors"   ON public.clients_vendors;
DROP POLICY IF EXISTS "Allow authenticated users to view clients_vendors"   ON public.clients_vendors;
DROP POLICY IF EXISTS "Allow authenticated users to insert clients_vendors" ON public.clients_vendors;
DROP POLICY IF EXISTS "Allow authenticated users to update clients_vendors" ON public.clients_vendors;
DROP POLICY IF EXISTS "Allow authenticated users to delete clients_vendors" ON public.clients_vendors;

DROP POLICY IF EXISTS "Authenticated users can read depots"           ON public.depots;
DROP POLICY IF EXISTS "Managers can manage depots"                    ON public.depots;

DROP POLICY IF EXISTS "Anyone can read valid tokens"                  ON public.invitation_tokens;
DROP POLICY IF EXISTS "Managers can view their tokens"                ON public.invitation_tokens;
DROP POLICY IF EXISTS "Managers can create invitation tokens"         ON public.invitation_tokens;
DROP POLICY IF EXISTS "System can mark tokens as used"                ON public.invitation_tokens;

DROP POLICY IF EXISTS users_read_own_role                             ON public.user_roles;
DROP POLICY IF EXISTS authenticated_read_all_roles                    ON public.user_roles;
DROP POLICY IF EXISTS managers_full_access                            ON public.user_roles;
DROP POLICY IF EXISTS signup_insert_own_role                          ON public.user_roles;
DROP POLICY IF EXISTS user_roles_select                               ON public.user_roles;
DROP POLICY IF EXISTS user_roles_insert                               ON public.user_roles;
DROP POLICY IF EXISTS user_roles_update                               ON public.user_roles;
DROP POLICY IF EXISTS user_roles_delete                               ON public.user_roles;

DROP POLICY IF EXISTS "Users manage own widget config"                ON public.user_widget_config;

-- The four pre-planner policies on prefilled_jobs. They were keyed on
-- auth.uid() = user_id and were never dropped when sql/planner.sql introduced
-- the depot/agent model, so whoever created an entry kept full read and write
-- on it after it was reassigned to another agent or after they changed depots.
DROP POLICY IF EXISTS "Users can view own prefilled jobs"             ON public.prefilled_jobs;
DROP POLICY IF EXISTS "Users can insert own prefilled jobs"           ON public.prefilled_jobs;
DROP POLICY IF EXISTS "Users can update own prefilled jobs"           ON public.prefilled_jobs;
DROP POLICY IF EXISTS "Users can delete own prefilled jobs"           ON public.prefilled_jobs;

-- ---------------------------------------------------------------------------
-- 3. The new policies
-- ---------------------------------------------------------------------------

ALTER TABLE public.boxes             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.serials           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shifts            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agents            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendors           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.depot_clients     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients_vendors   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.depots            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invitation_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_widget_config ENABLE ROW LEVEL SECURITY;

-- boxes -------------------------------------------------------------------
-- A technician opens boxes under their own agent; a manager may open or close
-- one on any agent's behalf within the depot (inventory.html's "Close box").
CREATE POLICY boxes_select ON public.boxes FOR SELECT TO authenticated
    USING (public.can_read_depot(depot_id));
CREATE POLICY boxes_insert ON public.boxes FOR INSERT TO authenticated
    WITH CHECK (public.can_write_depot(depot_id)
                OR (depot_id = public.current_depot_id()
                    AND agent = public.current_agent_id()));
CREATE POLICY boxes_update ON public.boxes FOR UPDATE TO authenticated
    USING (public.can_write_depot(depot_id)
           OR (depot_id = public.current_depot_id()
               AND agent = public.current_agent_id()))
    WITH CHECK (public.can_write_depot(depot_id)
                OR (depot_id = public.current_depot_id()
                    AND agent = public.current_agent_id()));
CREATE POLICY boxes_delete ON public.boxes FOR DELETE TO authenticated
    USING (public.can_write_depot(depot_id));

-- jobs --------------------------------------------------------------------
CREATE POLICY jobs_select ON public.jobs FOR SELECT TO authenticated
    USING (public.can_read_depot(depot_id));
CREATE POLICY jobs_insert ON public.jobs FOR INSERT TO authenticated
    WITH CHECK (depot_id = public.current_depot_id()
                AND public.can_write_box(box_id));
CREATE POLICY jobs_update ON public.jobs FOR UPDATE TO authenticated
    USING (public.can_read_depot(depot_id) AND public.can_write_box(box_id))
    WITH CHECK (public.can_read_depot(depot_id) AND public.can_write_box(box_id));
CREATE POLICY jobs_delete ON public.jobs FOR DELETE TO authenticated
    USING (public.can_read_depot(depot_id) AND public.can_write_box(box_id));

-- serials -----------------------------------------------------------------
-- Reads stay depot-wide: checkDuplicateSerials() in utils.js is documented as
-- a per-depot check, and it has to see other agents' serials to work.
CREATE POLICY serials_select ON public.serials FOR SELECT TO authenticated
    USING (public.can_read_depot(depot_id));
CREATE POLICY serials_insert ON public.serials FOR INSERT TO authenticated
    WITH CHECK (depot_id = public.current_depot_id()
                AND public.can_write_box(box_id));
CREATE POLICY serials_update ON public.serials FOR UPDATE TO authenticated
    USING (public.can_read_depot(depot_id) AND public.can_write_box(box_id))
    WITH CHECK (public.can_read_depot(depot_id) AND public.can_write_box(box_id));
CREATE POLICY serials_delete ON public.serials FOR DELETE TO authenticated
    USING (public.can_read_depot(depot_id) AND public.can_write_box(box_id));

-- shifts ------------------------------------------------------------------
-- Deliberately narrower than the tables above: a technician sees only their own
-- shifts, as they do today. Managers get the depot for shifts.html.
CREATE POLICY shifts_select ON public.shifts FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()) OR public.can_write_depot(depot_id));
CREATE POLICY shifts_insert ON public.shifts FOR INSERT TO authenticated
    WITH CHECK (user_id = (SELECT auth.uid())
                AND depot_id = public.current_depot_id());
CREATE POLICY shifts_update ON public.shifts FOR UPDATE TO authenticated
    USING (user_id = (SELECT auth.uid()) OR public.can_write_depot(depot_id))
    WITH CHECK (user_id = (SELECT auth.uid()) OR public.can_write_depot(depot_id));
CREATE POLICY shifts_delete ON public.shifts FOR DELETE TO authenticated
    USING (public.can_write_depot(depot_id));

-- agents ------------------------------------------------------------------
CREATE POLICY agents_select ON public.agents FOR SELECT TO authenticated
    USING (public.can_read_depot(depot_id));
CREATE POLICY agents_write ON public.agents FOR ALL TO authenticated
    USING (public.can_write_depot(depot_id))
    WITH CHECK (public.can_write_depot(depot_id));

-- clients and vendors -----------------------------------------------------
-- Global catalogues by design. Readable by anyone signed in, written by
-- managers and super admins. Which of them a depot actually uses is decided by
-- depot_clients and clients_vendors below.
CREATE POLICY clients_select ON public.clients FOR SELECT TO authenticated
    USING (true);
CREATE POLICY clients_write ON public.clients FOR ALL TO authenticated
    USING (public.is_manager()) WITH CHECK (public.is_manager());

CREATE POLICY vendors_select ON public.vendors FOR SELECT TO authenticated
    USING (true);
CREATE POLICY vendors_write ON public.vendors FOR ALL TO authenticated
    USING (public.is_manager()) WITH CHECK (public.is_manager());

-- depot_clients and clients_vendors ---------------------------------------
CREATE POLICY depot_clients_select ON public.depot_clients FOR SELECT TO authenticated
    USING (public.can_read_depot(depot_id));
CREATE POLICY depot_clients_write ON public.depot_clients FOR ALL TO authenticated
    USING (public.can_write_depot(depot_id))
    WITH CHECK (public.can_write_depot(depot_id));

CREATE POLICY clients_vendors_select ON public.clients_vendors FOR SELECT TO authenticated
    USING (public.can_read_depot(depot_id));
CREATE POLICY clients_vendors_write ON public.clients_vendors FOR ALL TO authenticated
    USING (public.can_write_depot(depot_id))
    WITH CHECK (public.can_write_depot(depot_id));

-- depots ------------------------------------------------------------------
-- Creating, renaming and deleting depots is manage-depots.html, which is
-- super_admin only. Everyone else reads their own depot and nothing more.
CREATE POLICY depots_select ON public.depots FOR SELECT TO authenticated
    USING (public.can_read_depot(depot_id));
CREATE POLICY depots_write ON public.depots FOR ALL TO authenticated
    USING (public.current_is_super_admin())
    WITH CHECK (public.current_is_super_admin());

-- invitation_tokens -------------------------------------------------------
-- No anon access at all. Signup is unauthenticated and still needs to check a
-- token, so it goes through validate_invitation_token() / redeem_invitation_token()
-- in section 4 instead of reading the table.
CREATE POLICY invitation_tokens_select ON public.invitation_tokens FOR SELECT TO authenticated
    USING (public.can_write_depot(depot_id));
CREATE POLICY invitation_tokens_insert ON public.invitation_tokens FOR INSERT TO authenticated
    WITH CHECK (public.can_write_depot(depot_id));
CREATE POLICY invitation_tokens_update ON public.invitation_tokens FOR UPDATE TO authenticated
    USING (public.can_write_depot(depot_id))
    WITH CHECK (public.can_write_depot(depot_id));
CREATE POLICY invitation_tokens_delete ON public.invitation_tokens FOR DELETE TO authenticated
    USING (public.can_write_depot(depot_id));

-- user_roles --------------------------------------------------------------
-- Reads: your own row, plus the rest of your depot (shifts.html and my-depot.html
-- join emails and agents onto other users). Super admins see everyone.
CREATE POLICY user_roles_select ON public.user_roles FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid()) OR public.can_read_depot(depot_id));

-- Only managers and super admins create user rows directly. Token signup used
-- to insert its own row here, which meant anyone who could reach auth.signUp()
-- could file themselves into any depot they named — the token was never checked
-- by the database. That path now goes through redeem_invitation_token() in
-- section 4, which redeems the token and creates the row in one statement.
CREATE POLICY user_roles_insert ON public.user_roles FOR INSERT TO authenticated
    WITH CHECK (public.can_write_depot(depot_id));

-- Two ways to update a row, and neither can touch role or depot_id:
--
--   * a manager, on anyone in their depot — keeping the fields my-depot.html
--     actually edits (agent_id, shifts_enabled, must_change_password)
--   * any user, on their own row — which is how change-password.html and
--     reset-password.html clear must_change_password. That branch additionally
--     pins agent_id and shifts_enabled so a technician cannot assign themselves
--     an agent or turn on shift tracking.
--
-- Only a super_admin may change role or depot_id, through manage-depots.html.
-- Changing role was the manager -> super_admin self-promotion hole.
CREATE POLICY user_roles_update ON public.user_roles FOR UPDATE TO authenticated
    USING (user_id = (SELECT auth.uid()) OR public.can_write_depot(depot_id))
    WITH CHECK (
        public.current_is_super_admin()
        OR (public.can_write_depot(depot_id)
            AND role     IS NOT DISTINCT FROM public.existing_user_role(user_id)
            AND depot_id IS NOT DISTINCT FROM public.existing_user_depot(user_id))
        OR (user_id = (SELECT auth.uid())
            AND role           IS NOT DISTINCT FROM public.existing_user_role(user_id)
            AND depot_id       IS NOT DISTINCT FROM public.existing_user_depot(user_id)
            AND agent_id       IS NOT DISTINCT FROM public.existing_user_agent(user_id)
            AND shifts_enabled IS NOT DISTINCT FROM public.existing_user_shifts_enabled(user_id))
    );

CREATE POLICY user_roles_delete ON public.user_roles FOR DELETE TO authenticated
    USING (public.can_write_depot(depot_id));

-- user_widget_config ------------------------------------------------------
CREATE POLICY user_widget_config_all ON public.user_widget_config FOR ALL TO authenticated
    USING (user_id = (SELECT auth.uid()))
    WITH CHECK (user_id = (SELECT auth.uid()));

-- prefilled_jobs ----------------------------------------------------------
-- Same model as sql/planner.sql, recreated only to wrap auth.uid() and the
-- helper calls in a scalar subquery so they run once per query, not per row.
DROP POLICY IF EXISTS prefilled_jobs_select ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_select ON public.prefilled_jobs FOR SELECT TO authenticated
    USING (depot_id = (SELECT public.current_depot_id())
           AND public.can_write_planner_entry(assigned_agent_id, entry_type));

DROP POLICY IF EXISTS prefilled_jobs_insert ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_insert ON public.prefilled_jobs FOR INSERT TO authenticated
    WITH CHECK (depot_id = (SELECT public.current_depot_id())
                AND user_id = (SELECT auth.uid())
                AND public.can_write_planner_entry(assigned_agent_id, entry_type));

DROP POLICY IF EXISTS prefilled_jobs_update ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_update ON public.prefilled_jobs FOR UPDATE TO authenticated
    USING (depot_id = (SELECT public.current_depot_id())
           AND public.can_write_planner_entry(assigned_agent_id, entry_type))
    WITH CHECK (depot_id = (SELECT public.current_depot_id())
                AND public.can_write_planner_entry(assigned_agent_id, entry_type));

DROP POLICY IF EXISTS prefilled_jobs_delete ON public.prefilled_jobs;
CREATE POLICY prefilled_jobs_delete ON public.prefilled_jobs FOR DELETE TO authenticated
    USING (depot_id = (SELECT public.current_depot_id())
           AND public.can_write_planner_entry(assigned_agent_id, entry_type));

-- can_write_planner_entry was the one helper sql/planner.sql left without a
-- pinned search_path.
CREATE OR REPLACE FUNCTION public.can_write_planner_entry(entry_agent text, entry_kind text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$ SELECT public.current_is_manager()
          OR entry_agent = public.current_agent_id()
          OR (entry_agent IS NULL AND entry_kind <> 'job') $$;

-- ---------------------------------------------------------------------------
-- 4. Invitation tokens without exposing the table
-- ---------------------------------------------------------------------------
-- signup.html runs before any session exists, so it cannot read a depot-scoped
-- table. These two definer functions give it exactly what it needs and nothing
-- else: no token enumeration, and no way to burn someone else's invitation
-- without knowing the token string.

CREATE OR REPLACE FUNCTION public.validate_invitation_token(p_token text)
RETURNS TABLE (email text, depot_id text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
    SELECT t.email, t.depot_id
    FROM public.invitation_tokens t
    WHERE t.token = p_token
      AND t.used = false
      AND t.expires_at > now()
$$;

-- Redeems a token and creates the caller's technician row in one statement.
-- Doing both here is what ties the two together: the depot comes from the token
-- row, not from anything the browser sends, so a signup cannot file itself into
-- a depot it was not invited to. Returns no row if the token is already used,
-- expired or unknown, and the caller must already be signed in (auth.signUp()
-- establishes the session before this is called).
CREATE OR REPLACE FUNCTION public.redeem_invitation_token(p_token text)
RETURNS TABLE (email text, depot_id text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid   uuid := (SELECT auth.uid());
    v_email text;
    v_depot text;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'redeem_invitation_token requires an authenticated session';
    END IF;

    UPDATE public.invitation_tokens t
       SET used = true, used_at = now()
     WHERE t.token = p_token
       AND t.used = false
       AND t.expires_at > now()
    RETURNING t.email, t.depot_id INTO v_email, v_depot;

    IF v_email IS NULL THEN
        RETURN;                      -- dead token: no row created, no row returned
    END IF;

    INSERT INTO public.user_roles (user_id, email, role, agent_id, depot_id)
    VALUES (v_uid, v_email, 'technician', NULL, v_depot)
    ON CONFLICT (user_id) DO NOTHING;

    RETURN QUERY SELECT v_email, v_depot;
END
$$;

REVOKE ALL ON FUNCTION public.validate_invitation_token(text) FROM public;
REVOKE ALL ON FUNCTION public.redeem_invitation_token(text)   FROM public;
GRANT EXECUTE ON FUNCTION public.validate_invitation_token(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_invitation_token(text)   TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Storage: job-receipts
-- ---------------------------------------------------------------------------
-- The bucket is private, but the old read policy let any technician, manager or
-- super_admin in ANY depot read ANY receipt: no depot check and no path check.
-- Filenames are enumerable from jobs.receipt_url, so that was every receipt in
-- the system. There was also no DELETE policy at all, which is why the cleanup
-- calls in stock-entry.html and inventory.html have always failed silently.

DROP POLICY IF EXISTS "Allow technician/manager read"     ON storage.objects;
DROP POLICY IF EXISTS "Allow technician/manager upload"   ON storage.objects;
DROP POLICY IF EXISTS "Receipts readable within depot"    ON storage.objects;
DROP POLICY IF EXISTS "Receipts writable within depot"    ON storage.objects;
DROP POLICY IF EXISTS "Receipts deletable within depot"   ON storage.objects;

CREATE POLICY "Receipts readable within depot" ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'job-receipts' AND public.can_read_receipt(name));

-- The job row is inserted before its receipt is uploaded, so the depot is
-- already resolvable from the filename at upload time.
CREATE POLICY "Receipts writable within depot" ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'job-receipts' AND public.can_read_receipt(name));

CREATE POLICY "Receipts deletable within depot" ON storage.objects FOR DELETE TO authenticated
    USING (bucket_id = 'job-receipts' AND public.can_delete_receipt(name));

-- ---------------------------------------------------------------------------
-- 6. Revoke anon's table grants
-- ---------------------------------------------------------------------------
-- Defence in depth. Every policy above is TO authenticated, so anon already
-- matches nothing; this makes a future permissive policy far less dangerous.
-- anon keeps schema USAGE and EXECUTE on the two signup functions.

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;

-- ---------------------------------------------------------------------------
-- 7. Drop unused objects
-- ---------------------------------------------------------------------------
-- None of these is referenced anywhere in the repo. audit_log holds no rows and
-- had no INSERT policy, so nothing could ever have written to it through the
-- API. Definitions are preserved in sql/rls-hardening-rollback.sql.

DROP VIEW  IF EXISTS public.serial_tracker;
DROP VIEW  IF EXISTS public.box_summary;
DROP TABLE IF EXISTS public.audit_log;

COMMIT;

-- ---------------------------------------------------------------------------
-- 8. Keep the helpers off the public REST surface
-- ---------------------------------------------------------------------------
-- Applied as a follow-up migration (rls_helper_execute_lockdown) after the
-- Supabase linter pointed out that everything above is reachable as an RPC.
--
-- PostgREST exposes every function in `public` as /rest/v1/rpc/<name>, and these
-- are SECURITY DEFINER. That matters most for the existing_user_* helpers, which
-- take an arbitrary user id: existing_user_role('<uuid>') would have told any
-- caller holding the anon key what role, depot and agent that user has.
--
-- Policy expressions are evaluated as the querying role, so `authenticated` must
-- keep EXECUTE or every policy above fails closed. `anon` never evaluates a
-- policy now — it holds no table grants at all — so it needs none of them.
--
-- This section is outside the transaction above because it was applied as its
-- own migration; it has its own BEGIN/COMMIT so a re-run of the whole file is
-- still all-or-nothing per section.

BEGIN;

CREATE OR REPLACE FUNCTION public.receipt_job_id(object_name text)
RETURNS bigint
LANGUAGE sql IMMUTABLE
SET search_path = public
AS $$ SELECT (regexp_match(object_name, '^[0-9]+-([0-9]+)\.jpg$'))[1]::bigint $$;

DO $$
DECLARE
    fn text;
    fns text[] := ARRAY[
        'current_is_super_admin()',
        'current_is_manager()',
        'current_depot_id()',
        'current_agent_id()',
        'is_manager()',
        'is_staff()',
        'is_current_user_manager()',
        'can_read_depot(text)',
        'can_write_depot(text)',
        'can_write_box(bigint)',
        'can_write_planner_entry(text, text)',
        'receipt_job_id(text)',
        'can_read_receipt(text)',
        'can_delete_receipt(text)',
        'existing_user_role(uuid)',
        'existing_user_depot(uuid)',
        'existing_user_agent(uuid)',
        'existing_user_shifts_enabled(uuid)'
    ];
BEGIN
    FOREACH fn IN ARRAY fns LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', fn);
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role', fn);
    END LOOP;
END $$;

-- Signup runs before a session exists, so these two stay reachable by anon.
GRANT EXECUTE ON FUNCTION public.validate_invitation_token(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_invitation_token(text)   TO anon, authenticated;

COMMIT;
