-- Rollback for sql/rls-hardening.sql
-- =================================
-- Captured from the live Serial Tracker project (lfydtctndrzzdyavmlva) on
-- 2026-08-24, immediately before rls-hardening.sql was applied. This is the
-- exact policy set, view set and dead-table definition that existed beforehand.
--
-- Running this file restores the PREVIOUS, INSECURE state. It exists only as an
-- escape hatch: if the hardened policies lock users out of a flow that matters
-- more than the exposure, run this to get back to a working app, then fix the
-- specific policy rather than leaving this state in place.
--
-- Read sql/rls-hardening.sql for what each of these was replaced with and why.
-- The three headline problems restored by this file are:
--   * jobs / serials / boxes readable and writable by anon (the public API key)
--   * any manager able to set their own role to super_admin
--   * any authenticated user able to create, rename or delete depots

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Undo the hardening
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS agents_select            ON public.agents;
DROP POLICY IF EXISTS agents_write             ON public.agents;
DROP POLICY IF EXISTS boxes_select             ON public.boxes;
DROP POLICY IF EXISTS boxes_insert             ON public.boxes;
DROP POLICY IF EXISTS boxes_update             ON public.boxes;
DROP POLICY IF EXISTS boxes_delete             ON public.boxes;
DROP POLICY IF EXISTS clients_select           ON public.clients;
DROP POLICY IF EXISTS clients_write            ON public.clients;
DROP POLICY IF EXISTS clients_vendors_select   ON public.clients_vendors;
DROP POLICY IF EXISTS clients_vendors_write    ON public.clients_vendors;
DROP POLICY IF EXISTS depot_clients_select     ON public.depot_clients;
DROP POLICY IF EXISTS depot_clients_write      ON public.depot_clients;
DROP POLICY IF EXISTS depots_select            ON public.depots;
DROP POLICY IF EXISTS depots_write             ON public.depots;
DROP POLICY IF EXISTS invitation_tokens_select ON public.invitation_tokens;
DROP POLICY IF EXISTS invitation_tokens_insert ON public.invitation_tokens;
DROP POLICY IF EXISTS invitation_tokens_update ON public.invitation_tokens;
DROP POLICY IF EXISTS invitation_tokens_delete ON public.invitation_tokens;
DROP POLICY IF EXISTS jobs_select              ON public.jobs;
DROP POLICY IF EXISTS jobs_insert              ON public.jobs;
DROP POLICY IF EXISTS jobs_update              ON public.jobs;
DROP POLICY IF EXISTS jobs_delete              ON public.jobs;
DROP POLICY IF EXISTS serials_select           ON public.serials;
DROP POLICY IF EXISTS serials_insert           ON public.serials;
DROP POLICY IF EXISTS serials_update           ON public.serials;
DROP POLICY IF EXISTS serials_delete           ON public.serials;
DROP POLICY IF EXISTS shifts_select            ON public.shifts;
DROP POLICY IF EXISTS shifts_insert            ON public.shifts;
DROP POLICY IF EXISTS shifts_update            ON public.shifts;
DROP POLICY IF EXISTS shifts_delete            ON public.shifts;
DROP POLICY IF EXISTS user_roles_select        ON public.user_roles;
DROP POLICY IF EXISTS user_roles_insert        ON public.user_roles;
DROP POLICY IF EXISTS user_roles_update        ON public.user_roles;
DROP POLICY IF EXISTS user_roles_delete        ON public.user_roles;
DROP POLICY IF EXISTS vendors_select           ON public.vendors;
DROP POLICY IF EXISTS vendors_write            ON public.vendors;

DROP POLICY IF EXISTS "Receipts readable within depot" ON storage.objects;
DROP POLICY IF EXISTS "Receipts writable within depot" ON storage.objects;
DROP POLICY IF EXISTS "Receipts deletable within depot" ON storage.objects;

DROP FUNCTION IF EXISTS public.validate_invitation_token(text);
DROP FUNCTION IF EXISTS public.redeem_invitation_token(text);
DROP FUNCTION IF EXISTS public.current_is_super_admin();
DROP FUNCTION IF EXISTS public.receipt_in_current_depot(text);

-- ---------------------------------------------------------------------------
-- 2. Restore the previous grants
-- ---------------------------------------------------------------------------
-- The hardening revoked anon's DML on every table. This puts it back.

GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER, TRUNCATE
    ON ALL TABLES IN SCHEMA public TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER, TRUNCATE
    ON ALL TABLES IN SCHEMA public TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Restore the dropped objects
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.audit_log (
    id         bigserial PRIMARY KEY,
    user_id    uuid REFERENCES auth.users(id),
    action     text NOT NULL,
    table_name text,
    record_id  text,
    details    jsonb,
    created_at timestamptz DEFAULT now()
);
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Managers can read audit log" ON public.audit_log FOR SELECT TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['manager','super_admin'])));

CREATE OR REPLACE VIEW public.serial_tracker WITH (security_invoker = true) AS
 SELECT s.id, s.serial_number, s.created_at, j.job_number, j.vendor,
        b.box_id, b.agent, b.client, b.status AS box_status
   FROM serials s
   JOIN jobs j  ON s.job_id = j.id
   JOIN boxes b ON s.box_id = b.id
  ORDER BY s.created_at DESC;

CREATE OR REPLACE VIEW public.box_summary WITH (security_invoker = true) AS
 SELECT b.id, b.box_id, b.agent, b.client, b.status, b.created_at, b.closed_at,
        count(DISTINCT j.id) AS job_count,
        count(s.id) AS serial_count
   FROM boxes b
   LEFT JOIN jobs j    ON b.id = j.box_id
   LEFT JOIN serials s ON b.id = s.box_id
  GROUP BY b.id, b.box_id, b.agent, b.client, b.status, b.created_at, b.closed_at
  ORDER BY b.created_at DESC;

-- ---------------------------------------------------------------------------
-- 4. Restore the original policies, verbatim
-- ---------------------------------------------------------------------------

-- agents
CREATE POLICY "Authenticated users can read agents" ON public.agents FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Managers can manage agents" ON public.agents FOR ALL TO public
    USING (is_manager());

-- boxes  (NOTE: the first policy is the anon read/write hole)
CREATE POLICY "Allow all operations on boxes" ON public.boxes FOR ALL TO public
    USING (true) WITH CHECK (true);
CREATE POLICY "Authenticated users can read boxes" ON public.boxes FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Technicians and managers can insert boxes" ON public.boxes FOR INSERT TO public
    WITH CHECK (EXISTS (SELECT 1 FROM user_roles
                        WHERE user_roles.user_id = auth.uid()
                          AND user_roles.role = ANY (ARRAY['technician','manager'])));
CREATE POLICY "Technicians and managers can update boxes" ON public.boxes FOR UPDATE TO public
    USING (is_staff());

-- clients
CREATE POLICY "Authenticated users can read clients" ON public.clients FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Managers can manage clients" ON public.clients FOR ALL TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['manager','super_admin'])));

-- clients_vendors
CREATE POLICY "Allow authenticated users to read clients_vendors" ON public.clients_vendors FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "Allow authenticated users to view clients_vendors" ON public.clients_vendors FOR SELECT TO authenticated
    USING (true);
CREATE POLICY "Allow authenticated users to insert clients_vendors" ON public.clients_vendors FOR INSERT TO authenticated
    WITH CHECK (true);
CREATE POLICY "Allow authenticated users to update clients_vendors" ON public.clients_vendors FOR UPDATE TO authenticated
    USING (true);
CREATE POLICY "Allow authenticated users to delete clients_vendors" ON public.clients_vendors FOR DELETE TO authenticated
    USING (true);

-- depot_clients
CREATE POLICY "Authenticated users can read depot_clients" ON public.depot_clients FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Managers can manage depot_clients" ON public.depot_clients FOR ALL TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['manager','super_admin'])));

-- depots  (NOTE: "Managers can manage depots" never checked the role)
CREATE POLICY "Authenticated users can read depots" ON public.depots FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Managers can manage depots" ON public.depots FOR ALL TO public
    USING (auth.role() = 'authenticated');

-- invitation_tokens  (NOTE: anon could read and burn unused tokens)
CREATE POLICY "Anyone can read valid tokens" ON public.invitation_tokens FOR SELECT TO anon, authenticated
    USING (used = false AND expires_at > now());
CREATE POLICY "Managers can view their tokens" ON public.invitation_tokens FOR SELECT TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['manager','super_admin'])));
CREATE POLICY "Managers can create invitation tokens" ON public.invitation_tokens FOR INSERT TO authenticated
    WITH CHECK (EXISTS (SELECT 1 FROM user_roles
                        WHERE user_roles.user_id = auth.uid()
                          AND user_roles.role = 'manager'));
CREATE POLICY "System can mark tokens as used" ON public.invitation_tokens FOR UPDATE TO anon, authenticated
    USING (used = false) WITH CHECK (used = true);

-- jobs  (NOTE: the first policy is the anon read/write hole)
CREATE POLICY "Allow all operations on jobs" ON public.jobs FOR ALL TO public
    USING (true) WITH CHECK (true);
CREATE POLICY "Authenticated users can read jobs" ON public.jobs FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Technicians and managers can manage jobs" ON public.jobs FOR ALL TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['technician','manager','super_admin'])));

-- prefilled_jobs  (the four legacy policies the hardening dropped; the four
-- planner policies from sql/planner.sql are left in place and not repeated here)
CREATE POLICY "Users can view own prefilled jobs" ON public.prefilled_jobs FOR SELECT TO public
    USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own prefilled jobs" ON public.prefilled_jobs FOR INSERT TO public
    WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own prefilled jobs" ON public.prefilled_jobs FOR UPDATE TO public
    USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can delete own prefilled jobs" ON public.prefilled_jobs FOR DELETE TO public
    USING (auth.uid() = user_id);

-- serials  (NOTE: the first policy is the anon read/write hole)
CREATE POLICY "Allow all operations on serials" ON public.serials FOR ALL TO public
    USING (true) WITH CHECK (true);
CREATE POLICY "Authenticated users can read serials" ON public.serials FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Technicians and managers can manage serials" ON public.serials FOR ALL TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['technician','manager','super_admin'])));

-- shifts  (NOTE: the manager policies had no depot predicate)
CREATE POLICY "Users can view own shifts" ON public.shifts FOR SELECT TO public
    USING (auth.uid() = user_id);
CREATE POLICY "Managers can view all shifts" ON public.shifts FOR SELECT TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['manager','super_admin'])));
CREATE POLICY "Users can insert own shifts" ON public.shifts FOR INSERT TO public
    WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own shifts" ON public.shifts FOR UPDATE TO public
    USING (auth.uid() = user_id);
CREATE POLICY "Managers can update any shift" ON public.shifts FOR UPDATE TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['manager','super_admin'])));

-- user_roles  (NOTE: managers_full_access is the self-promotion hole)
CREATE POLICY users_read_own_role ON public.user_roles FOR SELECT TO authenticated
    USING (user_id = auth.uid());
CREATE POLICY authenticated_read_all_roles ON public.user_roles FOR SELECT TO authenticated
    USING (true);
CREATE POLICY signup_insert_own_role ON public.user_roles FOR INSERT TO authenticated
    WITH CHECK (user_id = auth.uid() AND role = 'technician' AND agent_id IS NULL);
CREATE POLICY managers_full_access ON public.user_roles FOR ALL TO authenticated
    USING (is_manager()) WITH CHECK (is_manager());

-- vendors
CREATE POLICY "Authenticated users can read vendors" ON public.vendors FOR SELECT TO public
    USING (auth.role() = 'authenticated');
CREATE POLICY "Managers can manage vendors" ON public.vendors FOR ALL TO public
    USING (EXISTS (SELECT 1 FROM user_roles
                   WHERE user_roles.user_id = auth.uid()
                     AND user_roles.role = ANY (ARRAY['manager','super_admin'])));

-- storage: job-receipts (no DELETE policy existed, which is why receipt
-- cleanup silently failed — restoring that gap along with the rest)
DROP POLICY IF EXISTS "Allow technician/manager read"   ON storage.objects;
DROP POLICY IF EXISTS "Allow technician/manager upload" ON storage.objects;
CREATE POLICY "Allow technician/manager read" ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'job-receipts'
           AND auth.uid() IN (SELECT user_roles.user_id FROM user_roles
                              WHERE user_roles.role = ANY (ARRAY['technician','manager','super_admin'])));
CREATE POLICY "Allow technician/manager upload" ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'job-receipts'
                AND auth.uid() IN (SELECT user_roles.user_id FROM user_roles
                                   WHERE user_roles.role = ANY (ARRAY['technician','manager','super_admin'])));

COMMIT;
