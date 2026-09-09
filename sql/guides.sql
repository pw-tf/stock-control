-- Technician guides for the Stock Submission System
-- Run once against the Supabase project (SQL editor) before deploying guides.html.
--
-- WHY
-- ---
-- The 2026 terminal guides (bank + model configuration steps) previously lived in
-- a document nobody could reach from the app. Storing them as rows rather than
-- hardcoded HTML means a manager can correct a phone number or a menu path from
-- the app — or straight from the Supabase table editor — without a deploy.
--
-- SHAPE
-- -----
-- A guide is reached by drilling down: client -> vendor -> device -> guide.
--
--   clients   INGENICO, VERIFONE  — who dispatches the work
--   vendors   CBA, NAB, WPB, SUN, HJK — the banks
--   device    the terminal model: Move5000, QT850, CM5P, P630, T650P, P400
--   guide     the variant: Standalone, Integrated, Cloud (PC-EFTPOS)...
--
-- Note this is the reverse of the source document's wording, which called the
-- banks "clients"; the column names here follow the app's schema.
--
--   client NULL, vendor NULL, device NULL  -> general, reached from the home screen
--   all three set                          -> a bank's terminal model variant
--
-- Guides are global, like clients and vendors themselves: terminal procedures are
-- national, so every depot reads the same rows.
--
-- EVERY GUIDE IS SELF-CONTAINED. An earlier revision factored the shared setup
-- steps into five "common procedure" entries that the device guides linked into.
-- That reads badly in the field — a tech halfway through a swap should not be
-- told to go and open something else — so those steps are now written out in
-- full in each guide that needs them. The cost is deliberate: a change to a
-- shared step (the Bluetooth menu path, say) has to be made in each guide that
-- carries it. Clarity on site beats DRY in the table.
--
-- Idempotent; safe to re-run. The seed uses ON CONFLICT (slug) DO NOTHING so
-- re-running never clobbers an edit made since.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Readable names for the catalogue codes
-- ---------------------------------------------------------------------------
-- vendor_id is a code ('WPB', 'SUN', 'HJK') that reads badly as a navigation
-- heading. Rather than hardcoding a label map in the page, give the catalogues
-- an optional display name and let the UI fall back to the id when it is null.
-- Additive and nullable, so no existing page changes behaviour.

ALTER TABLE public.clients ADD COLUMN IF NOT EXISTS display_name text;
ALTER TABLE public.vendors ADD COLUMN IF NOT EXISTS display_name text;

COMMENT ON COLUMN public.clients.display_name IS
    'Human-readable name for the client code. Null falls back to client_id.';
COMMENT ON COLUMN public.vendors.display_name IS
    'Human-readable name for the vendor code. Null falls back to vendor_id.';

UPDATE public.clients SET display_name = v.name
FROM (VALUES
    ('INGENICO', 'Ingenico'),
    ('VERIFONE', 'Verifone'),
    ('AMTEK',    'Amtek')
) AS v(id, name)
WHERE public.clients.client_id = v.id AND public.clients.display_name IS NULL;

UPDATE public.vendors SET display_name = v.name
FROM (VALUES
    ('CBA', 'CBA'),
    ('NAB', 'NAB'),
    ('WPB', 'Westpac Group'),
    ('SUN', 'Suncorp'),
    ('HJK', 'Hungry Jacks'),
    ('ANZ', 'ANZ'),
    ('FDI', 'FiServ'),
    ('MCA', 'MCA'),
    ('OTH', 'Other')
) AS v(id, name)
WHERE public.vendors.vendor_id = v.id AND public.vendors.display_name IS NULL;

-- ---------------------------------------------------------------------------
-- 2. Table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.guides (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         text NOT NULL UNIQUE,
    client_id    text REFERENCES public.clients(client_id) ON DELETE SET NULL,
    vendor_id    text REFERENCES public.vendors(vendor_id) ON DELETE SET NULL,
    device       text,
    title        text NOT NULL,
    subtitle     text,
    body_md      text NOT NULL DEFAULT '',
    sort_order   integer NOT NULL DEFAULT 0,
    is_published boolean NOT NULL DEFAULT true,
    updated_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- Added after the first release, hence the separate ALTER rather than living in
-- the CREATE above only.
ALTER TABLE public.guides ADD COLUMN IF NOT EXISTS device text;

COMMENT ON TABLE public.guides IS
    'Technician terminal guides, drilled down client -> vendor -> device -> guide. Global, not depot-scoped.';
COMMENT ON COLUMN public.guides.slug IS
    'URL-safe id used by guides.html?guide=<slug>.';
COMMENT ON COLUMN public.guides.client_id IS
    'Manufacturer the guide sits under. Null = general guide, reached from the guides home screen.';
COMMENT ON COLUMN public.guides.vendor_id IS
    'Bank the guide applies to.';
COMMENT ON COLUMN public.guides.device IS
    'Terminal model, e.g. Move5000. The level between vendor and guide; several guides share one device when it has variants (Standalone / Integrated / Cloud).';
COMMENT ON COLUMN public.guides.title IS
    'The variant name within the device, e.g. "Standalone". For a device with only one guide this is usually just the model name.';
COMMENT ON COLUMN public.guides.subtitle IS
    'One-line scope note, e.g. "Applies to: Swaps, Installs, Upgrades".';
COMMENT ON COLUMN public.guides.body_md IS
    'Guide body in markdown, self-contained — it never refers the reader to another guide. Rendered by markdown.js, which escapes before parsing, so raw HTML here is inert rather than a way to inject markup.';
COMMENT ON COLUMN public.guides.sort_order IS
    'Manual ordering within a device. Also orders the devices themselves, by the lowest sort_order among each device''s guides.';
COMMENT ON COLUMN public.guides.is_published IS
    'False hides the guide from the browser without deleting it. Managers still see it, flagged as a draft.';

-- ---------------------------------------------------------------------------
-- 3. Constraints
-- ---------------------------------------------------------------------------

-- A guide cannot hang off a bank without a manufacturer above it, or the tree
-- has no branch to render it on.
ALTER TABLE public.guides DROP CONSTRAINT IF EXISTS guides_vendor_needs_client_check;
ALTER TABLE public.guides
    ADD CONSTRAINT guides_vendor_needs_client_check
    CHECK (vendor_id IS NULL OR client_id IS NOT NULL);

-- Same again one level down: a device belongs to a bank.
ALTER TABLE public.guides DROP CONSTRAINT IF EXISTS guides_device_needs_vendor_check;
ALTER TABLE public.guides
    ADD CONSTRAINT guides_device_needs_vendor_check
    CHECK (device IS NULL OR vendor_id IS NOT NULL);

-- The slug reaches the page as a URL parameter; keep the stored value to the
-- alphabet the page's allowlist accepts.
ALTER TABLE public.guides DROP CONSTRAINT IF EXISTS guides_slug_check;
ALTER TABLE public.guides
    ADD CONSTRAINT guides_slug_check
    CHECK (slug ~ '^[a-z0-9][a-z0-9-]*$' AND length(slug) <= 100);

ALTER TABLE public.guides DROP CONSTRAINT IF EXISTS guides_title_check;
ALTER TABLE public.guides
    ADD CONSTRAINT guides_title_check
    CHECK (length(btrim(title)) > 0);

-- ---------------------------------------------------------------------------
-- 4. Indexes
-- ---------------------------------------------------------------------------
-- The page loads the whole tree in one query ordered by the grouping columns;
-- the FK columns get covering indexes per sql/indexes-and-fk-coverage.sql.

DROP INDEX IF EXISTS public.guides_nav_idx;
CREATE INDEX IF NOT EXISTS guides_nav_idx
    ON public.guides (client_id, vendor_id, device, sort_order);
CREATE INDEX IF NOT EXISTS guides_client_id_idx
    ON public.guides (client_id);
CREATE INDEX IF NOT EXISTS guides_vendor_id_idx
    ON public.guides (vendor_id);
CREATE INDEX IF NOT EXISTS guides_updated_by_idx
    ON public.guides (updated_by);

-- ---------------------------------------------------------------------------
-- 5. Keep updated_at honest
-- ---------------------------------------------------------------------------
-- Edits can arrive from the app or straight from the Supabase table editor, so
-- the timestamp is maintained by the database rather than the client.

CREATE OR REPLACE FUNCTION public.guides_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS guides_set_updated_at ON public.guides;
CREATE TRIGGER guides_set_updated_at
    BEFORE UPDATE ON public.guides
    FOR EACH ROW EXECUTE FUNCTION public.guides_touch_updated_at();

-- Matches the posture of section 8 in rls-hardening.sql: nothing in public is
-- left callable by anon. Postgres checks EXECUTE on a trigger function when the
-- trigger is created, not when it fires, so this does not affect updates.
REVOKE ALL ON FUNCTION public.guides_touch_updated_at() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guides_touch_updated_at() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Row Level Security
-- ---------------------------------------------------------------------------
-- Read: staff only. is_staff() is 'technician OR manager OR super_admin', so
-- this is the one table in the schema a merchant cannot read at all — which is
-- the point, these are internal procedures, not merchant documentation.
-- Write: managers and super admins, matching clients_write / vendors_write.
--
-- Helper calls are wrapped as (SELECT ...) so Postgres evaluates them once per
-- query as an InitPlan rather than once per row.

ALTER TABLE public.guides ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS guides_select ON public.guides;
CREATE POLICY guides_select ON public.guides
    FOR SELECT TO authenticated
    USING ((SELECT public.is_staff()));

DROP POLICY IF EXISTS guides_write ON public.guides;
CREATE POLICY guides_write ON public.guides
    FOR ALL TO authenticated
    USING ((SELECT public.is_manager()))
    WITH CHECK ((SELECT public.is_manager()));

-- No new helper functions are introduced, so the revoke array in section 8 of
-- rls-hardening.sql needs no edit. New tables inherit no anon grant thanks to
-- that file's ALTER DEFAULT PRIVILEGES.

COMMIT;

-- ---------------------------------------------------------------------------
-- 7. Seed — the 2026 technician guides
-- ---------------------------------------------------------------------------
-- ON CONFLICT (slug) DO NOTHING so re-running this file never overwrites an
-- edit made since. To reset a guide to the shipped text, delete the row first.
--
-- Every body below is complete on its own. Where two guides share a procedure
-- (the Move5000 core configuration, the Verifone first boot) the steps are
-- written out in both rather than cross-referenced.

BEGIN;

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('general-reading-these-guides', NULL, NULL, NULL,
 'Reading these guides', 'Warning tiers and software policy', 0,
$md$Guides are found by narrowing down: **client** (Ingenico or Verifone — whoever
dispatched the work), then **vendor** (the bank), then the **device**, then the
variant you are working on.

Every guide is complete on its own. If two guides share a procedure the steps are
written out in both, so you never have to leave a job half-done to go and read
something else.

## Warning tiers

| Tier | Meaning |
|---|---|
| **CRITICAL** | Irreversible, or will stop the merchant transacting. |
| **NOTE** | Procedural detail or known behaviour. |
| **ADMIN** | Stock, paperwork, or upload requirement. |

## Software

All terminals should be running the latest software. Specific version numbers are
deliberately not listed anywhere in these guides — check the current version via
webchat if a job calls for it.$md$)
ON CONFLICT (slug) DO NOTHING;

-- Ingenico / CBA / Move5000 -------------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-cba-move5000-standalone', 'INGENICO', 'CBA', 'Move5000',
 'Standalone', 'Applies to: Swaps, Installs, Upgrades', 10,
$md$## Configuring

1. Power on the terminal.
2. Press **1**, enter the TID from the job sheet, then **Enter**.
3. Press **2**, enter the CAIC, then **Enter**.
4. Press **Cancel** and wait for TMS to complete.

**CRITICAL:** A serial reset **must** be done via webchat before the new terminal
will log on. On swaps, only do this while you are on site — it deactivates the
merchant's existing terminal.

## Resetting (DFS format)

1. Power on the terminal.
2. At the software version screen, quickly press the yellow **Clear** button.
3. Press **1** for DFS Format.
4. Enter password **2002** and press **Enter**.
5. Wait for the reboot, then configure as normal.$md$)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-cba-move5000-integrated', 'INGENICO', 'CBA', 'Move5000',
 'Integrated', 'Applies to: Swaps, Installs, Upgrades', 11,
$md$## 1. Configuring

1. Power on the terminal.
2. Press **FUNC** > **4 (Linkly)** and enter command **7410**.
3. Press **1** and enter the CATID (the TID on the job sheet).
4. Press **2** and enter the CAIC ID (bottom of the job sheet; always begins `3110000`).

## 2. Pairing the base

1. On the terminal, go to `Menu` > `0` (hidden menu) > password `62624371` >
   `Control Panel` > `Terminal Settings` > `Communication Means` > `Bluetooth`.
2. On the touchscreen select **Base** > **Association** > **New Base**.
3. Allow pairing to complete, then cancel out of the menu.

## 3. Integrated mode and POS comms

Bluetooth pairing and the comms method must **both** be set before logging on via
Linkly.

1. Press **FUNC** > **4 (Linkly)** > **11112227** > **Enter**.
2. At `POS COMMS METHOD` select **COM Port**, then:
   - **For USB:** select **USB SLAVE**
   - **For Serial:** select **COM0**
3. Reboot the terminal. It may install a base update.

**CRITICAL:** A serial reset **must** be done via webchat before the new terminal
will log on. On swaps, only do this while you are on site — it deactivates the
merchant's existing terminal.$md$)
ON CONFLICT (slug) DO NOTHING;

-- Ingenico / NAB / Move5000 -------------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-nab-move5000-standalone', 'INGENICO', 'NAB', 'Move5000',
 'Standalone', 'Applies to: Swaps, Installs, Upgrades', 20,
$md$## Configuring

1. Power the terminal on.
2. Press **FUNC** > **3** and enter the TID.
3. Enter/skip all settings **except** `VIEW HOST COMMS` and `VIEW TMS COMMS`.
   - Using **F2** and **F3** on the touchscreen, set both to **GPRS**.
4. Change `Standby (secs)` to **99999** so the terminal does not sleep.
5. Press **FUNC** > **103** to start the TMS download.

**NOTE:** TMS software must match or be newer than the terminal. This is not needed
on every job, but if a download fails or the terminal will not log on, check it via
the `Webchat: FSP Support` link on the job sheet — ask the helpdesk tech to set TMS
to the latest version **before** you run FUNC 103.

## Installs only

- **FUNC** > **90** — have the merchant set a 4-digit refund code.
- **FUNC** > **13** — set an auto-settlement time.

On a swap, no extras are needed: once TMS completes and the terminal logs on
successfully, it is ready.$md$)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-nab-move5000-integrated', 'INGENICO', 'NAB', 'Move5000',
 'Integrated', 'Applies to: Swaps, Installs, Upgrades', 21,
$md$## 1. Configuring

Identical to the standalone build.

1. Power the terminal on.
2. Press **FUNC** > **3** and enter the TID.
3. Enter/skip all settings **except** `VIEW HOST COMMS` and `VIEW TMS COMMS`.
   - Using **F2** and **F3** on the touchscreen, set both to **GPRS**.
4. Change `Standby (secs)` to **99999** so the terminal does not sleep.
5. Press **FUNC** > **103** to start the TMS download.

**NOTE:** TMS software must match or be newer than the terminal. This is not needed
on every job, but if a download fails or the terminal will not log on, check it via
the `Webchat: FSP Support` link on the job sheet — ask the helpdesk tech to set TMS
to the latest version **before** you run FUNC 103.

## 2. Pairing the base

1. On the terminal, go to `MENU` > `3.` or `4. Terminal (Other Functions)` >
   `3. Others` > `5. Settings` > `2. Bluetooth`.
2. On the touchscreen select **Base** > **Association** > **New Base**.
3. Allow pairing to complete, then cancel out of the menu.

## 3. Integrated mode and POS comms

Bluetooth pairing and the comms method must **both** be set before logging on via
Linkly.

1. Press **FUNC** > **11112227** > **Enter**.
2. At `POS COMMS METHOD` select **SERIAL**, then:
   - **For USB:** select **USB SLAVE**
   - **For Serial:** select **COM0**
3. Reboot the terminal. It may install a base update.

## Installs only

- **FUNC** > **90** — have the merchant set a 4-digit refund code.
- **FUNC** > **13** — set an auto-settlement time.$md$)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-nab-move5000-cloud-pceftpos', 'INGENICO', 'NAB', 'Move5000',
 'Cloud (PC-EFTPOS)', 'Applies to: Installs', 22,
$md$Comms between POS and terminal is via cloud, over Ethernet or Wi-Fi. Host and TMS
comms use the mode selected under FUNC 6.

## Before you start

- The merchant will have been supplied a **Cloud/Account ID** (11 digits) and a
  **Verification No/Password** (16 characters). Both are needed for the terminal and
  the POS.
- Confirm whether the site is using Ethernet or Wi-Fi for host comms. Ethernet
  requires Bluetooth pairing between the pinpad and base.
- The merchant's POS vendor should have already installed the POS software. If not,
  the merchant needs to contact them before you can proceed.

## Terminal setup

1. Fit the battery, connect power to the base, and place the terminal on the base to
   power up.
2. Confirm the terminal is on the latest software. Upgrade via USB if it is not.
3. Press **FUNC** > **6** and confirm it is set to Ethernet or Wi-Fi as required.
4. Set up the primary connection:
   - **Ethernet:** connect the cable, enable Bluetooth and pair the terminal to the base. Confirm the Ethernet and Bluetooth symbols are green.
   - **Wi-Fi:** scan for networks, select the network, key in the password. Confirm the Wi-Fi symbol is green.
5. Press **FUNC** > **3**, key in the TID, **Enter**. Press Enter at each selection
   until `Force TMS Comms` — confirm it is **ON**, press **Enter**, then **Cancel**.
6. Press **FUNC** > **102** to launch the TMS config download.
7. Press **FUNC** > **103** to launch the TMS software download and load the slave
   app. If the terminal is already up to date this only takes a few minutes. Confirm
   the host logon is approved.
8. Confirm the slave app is loaded: **Menu** > **Terminal** > **Others** >
   **Manager Menu** > password **0000** or **1234** > **Enter**. Application
   **8302101305** should be present.
   - If it is not, call the helpdesk to get the latest slave app added to TMS, then run FUNC 103 again.

## Cloud configuration

9. Press **FUNC** > **11112227** > **Enter**, then select Ethernet or Wi-Fi.
   - **NOTE:** to enter a letter in this menu, press the matching number key then press **FUNC** until the correct letter appears. Use upper case.
   - Host name: `PP.CLOUD.PCEFTPOS.COM`
   - Host port: `443`
   - POS Comms SSL: **ON**
   - SSL profile: **PCEFTPOS**
10. The terminal displays `INTEGRATED MODE PLEASE WAIT`, then `CLOUD ONLINE`.
11. On initial setup it displays `PINPAD PAIRING PRESS ENTER`. Press Enter and the
    terminal shows a 6-digit pairing code for the POS.
    - **NOTE:** the code times out after 30 seconds and shows `CLOUD CONNECT FAILURE`. Press Enter to generate a new one.

Once paired with the POS, the terminal returns to the idle screen.

## POS setup

The Linkly host details will already be set up in the POS software.

1. In PC-EFTPOS connection settings, enter:
   - EFT-Client address: `pos.cloud.pceftpos.com`
   - Port: `443`
2. In the terminal pairing process, enter the **Client ID**, **Password**, and the
   **pairing code** displayed on the terminal.
3. Click **Cloud Logon**.
4. Check the Result tab — it should read `CLOUD LOGON SUCCESS`.

## Pairing to Vend

1. Under the Vend **Setup** menu, go to **Payment Types**.
   - On iOS/Apple: menu icon > **Dashboard** > menu icon > **Setup** > **Payment Types**.
2. Select **Add Payment Type**, choose **NAB** from the drop-down, and name it
   (e.g. Credit/Debit).
3. Select the register you want to pair to. If multiple stores appear, choose the
   store you are at — **not** 'all stores' or 'all registers'.
4. Click **Pair a Terminal** and enter the Cloud ID/Client ID, Password and Pair Code.
5. Tick **Print receipts using terminal printer** if the merchant wants receipts from
   the terminal's built-in printer.
   - **NOTE:** if you pair before ticking this, use **FUNC 8880** to unpair and redo this step.
6. Click **PAIR**.

**NOTE:** On an `Invalid register` error, delete and re-create the NAB payment type.
With it re-created, attempt an EFTPOS sale — Vend should then prompt you to pair.

## Cloud terminal functions

- **FUNC 8880** — re-enter the Cloud ID and password (also unpairs).
- **FUNC 8888** — redisplay the pair code.

## Firewall requirements

If the POS or terminal will not connect to the cloud, check the firewall:

- The terminal must reach `pp.cloud.pceftpos.com`
- The POS must reach `pos.cloud.pceftpos.com`
- Both use port **443**$md$)
ON CONFLICT (slug) DO NOTHING;

-- Ingenico / NAB / QT850 ----------------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-nab-qt850', 'INGENICO', 'NAB', 'QT850',
 'QT850', 'Applies to: Swaps, Installs, Upgrades', 30,
$md$1. Power on the machine.
2. If the terminal asks to set up Wi-Fi, press **SKIP**. Otherwise press
   **Begin Setup**.
3. Allow the terminal to install updates and restart.
4. Once updates are installed, enter the **MID**, a space, then the **TID**.
   - Example: `123456 M5F1234`
5. Allow further updates to install.
6. Set the refund code to a default of **0000** to be changed later with the
   merchant, or set it with them on site.$md$)
ON CONFLICT (slug) DO NOTHING;

COMMIT;

BEGIN;

-- Ingenico / Westpac Group / Move5000 ---------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-wpb-move5000-standalone', 'INGENICO', 'WPB', 'Move5000',
 'Standalone', 'Covers Westpac, BankSA and St.George. Applies to: Swaps, Installs, Upgrades', 40,
$md$## 1. Configuring

1. Power the terminal on.
2. Press **FUNC** > **3** and enter the TID.
3. Enter/skip all settings **except** `VIEW HOST COMMS` and `VIEW TMS COMMS`.
   - Using **F2** and **F3** on the touchscreen, set both to **GPRS**.
4. Change `Standby (secs)` to **99999** so the terminal does not sleep.
5. Press **FUNC** > **103** to start the TMS download.

**NOTE:** TMS software must match or be newer than the terminal. This is not needed
on every job, but if a download fails or the terminal will not log on, check it via
the `Webchat: FSP Support` link on the job sheet — ask the helpdesk tech to set TMS
to the latest version **before** you run FUNC 103.

## 2. Activation

Once the terminal has downloaded and failed to log on, activate it by phone.

1. Call **1300 650 103** and say you are calling from Ingenico to activate a pinpad ID.
2. Provide the technician with:
   - The TID
   - The business name, suburb and state
   - The pinpad ID — **FUNC** > **3824** > **3**, or from the failed logon receipt
   - The last 8 digits of the serial number, typically starting from the '1'

**CRITICAL:** Do not pre-activate a terminal off site if it is an upgrade or swap.
This will stop the merchant's current terminal from transacting.

## Installs only

- **FUNC** > **90** — have the merchant set a 4-digit refund code.
- **FUNC** > **13** — set an auto-settlement time.$md$)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-wpb-move5000-integrated', 'INGENICO', 'WPB', 'Move5000',
 'Integrated', 'Covers Westpac, BankSA and St.George. Applies to: Swaps, Installs, Upgrades', 41,
$md$## 1. Configuring

1. Power the terminal on.
2. Press **FUNC** > **3** and enter the TID.
3. Enter/skip all settings **except** `VIEW HOST COMMS` and `VIEW TMS COMMS`.
   - Using **F2** and **F3** on the touchscreen, set both to **GPRS**.
4. Change `Standby (secs)` to **99999** so the terminal does not sleep.
5. Press **FUNC** > **103** to start the TMS download.

**NOTE:** TMS software must match or be newer than the terminal. This is not needed
on every job, but if a download fails or the terminal will not log on, check it via
the `Webchat: FSP Support` link on the job sheet — ask the helpdesk tech to set TMS
to the latest version **before** you run FUNC 103.

## 2. Pairing the base

1. On the terminal, go to `MENU` > `3. Terminal (Other Functions)` > `3. Others` >
   `4. Settings` > `2. Bluetooth`.
2. On the touchscreen select **Base** > **Association** > **New Base**.
3. Allow pairing to complete, then cancel out of the menu.

## 3. Integrated mode and POS comms

Bluetooth pairing and the comms method must **both** be set before logging on via
Linkly.

1. Press **FUNC** > **11112227** > **Enter**.
2. At `POS COMMS METHOD` select **SERIAL**, then:
   - **For USB:** select **USB SLAVE**
   - **For Serial:** select **COM0**
3. Reboot the terminal. It may install a base update.

## 4. Activation

Once the terminal has downloaded and failed to log on, activate it by phone.

1. Call **1300 650 103** and say you are calling from Ingenico to activate a pinpad ID.
2. Provide the technician with:
   - The TID
   - The business name, suburb and state
   - The pinpad ID — **FUNC** > **3824** > **3**, or from the failed logon receipt
   - The last 8 digits of the serial number, typically starting from the '1'

**CRITICAL:** Do not pre-activate a terminal off site if it is an upgrade or swap.
This will stop the merchant's current terminal from transacting.

## Installs only

- **FUNC** > **90** — have the merchant set a 4-digit refund code.
- **FUNC** > **13** — set an auto-settlement time.$md$)
ON CONFLICT (slug) DO NOTHING;

-- Ingenico / Suncorp / Move5000 ---------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-sun-move5000-standalone', 'INGENICO', 'SUN', 'Move5000',
 'Standalone', 'Applies to: Swaps, Installs, Upgrades', 50,
$md$## Configuring

1. Power the terminal on.
2. Press **FUNC** > **3** and enter the TID.
3. Enter/skip all settings **except** `VIEW HOST COMMS` and `VIEW TMS COMMS`.
   - Using **F2** and **F3** on the touchscreen, set both to **GPRS**.
4. Change `Standby (secs)` to **99999** so the terminal does not sleep.
5. Press **FUNC** > **103** to start the TMS download.

**NOTE:** TMS software must match or be newer than the terminal. This is not needed
on every job, but if a download fails or the terminal will not log on, check it via
the `Webchat: FSP Support` link on the job sheet — ask the helpdesk tech to set TMS
to the latest version **before** you run FUNC 103.

## Swaps

Once TMS completes and the terminal logs on successfully, it is ready to go — no
extras needed.

## Installs

- **FUNC** > **90** — have the merchant set a 4-digit refund code.
- **FUNC** > **13** — set an auto-settlement time.$md$)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('ingenico-sun-move5000-integrated', 'INGENICO', 'SUN', 'Move5000',
 'Integrated', 'Applies to: Swaps, Installs, Upgrades', 51,
$md$## 1. Configuring

1. Power the terminal on.
2. Press **FUNC** > **3** and enter the TID.
3. Enter/skip all settings **except** `VIEW HOST COMMS` and `VIEW TMS COMMS`.
   - Using **F2** and **F3** on the touchscreen, set both to **GPRS**.
4. Change `Standby (secs)` to **99999** so the terminal does not sleep.
5. Press **FUNC** > **103** to start the TMS download.

**NOTE:** TMS software must match or be newer than the terminal. This is not needed
on every job, but if a download fails or the terminal will not log on, check it via
the `Webchat: FSP Support` link on the job sheet — ask the helpdesk tech to set TMS
to the latest version **before** you run FUNC 103.

## 2. Pairing the base

1. On the terminal, go to `MENU` > `3.` or `4. Terminal (Other Functions)` >
   `3. Others` > `5. Settings` > `2. Bluetooth`.
2. On the touchscreen select **Base** > **Association** > **New Base**.
3. Allow pairing to complete, then cancel out of the menu.

## 3. Integrated mode and POS comms

Bluetooth pairing and the comms method must **both** be set before logging on via
Linkly.

1. Press **FUNC** > **11112227** > **Enter**.
2. At `POS COMMS METHOD` select **SERIAL**, then:
   - **For USB:** select **USB SLAVE**
   - **For Serial:** select **COM0**
3. Reboot the terminal. It may install a base update.

## Installs only

- **FUNC** > **90** — have the merchant set a 4-digit refund code.
- **FUNC** > **13** — set an auto-settlement time.$md$)
ON CONFLICT (slug) DO NOTHING;

-- Verifone / CBA / CM5P -----------------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('verifone-cba-cm5p', 'VERIFONE', 'CBA', 'CM5P',
 'CM5P', 'Applies to: Swaps, Installs, Upgrades', 10,
$md$## 1. First boot and download

1. Power on. Leave all settings default and press Enter through until you are asked
   for the Terminal ID (shown as **Device ID** on some models).
2. Enter the TID and press **Submit**. The CBA CM5P TID always begins **1007**.
3. Press Submit again and allow the download to run.
   - **NOTE:** if the download has not started once `Checking For Updates...` passes 5%, call Verifone Technical Support on **1800 656 870**. They will need the TID and the device serial, then ask you to reboot — this should start the download.
4. Set passwords. This requires a Verifone daily password, provided by Verifone
   email. The **manager** password is the merchant's main password; the **cashier**
   password is for staff. Both must be six digits and different from each other.

## 2. Logon

1. Press both logons on the screen.
2. Confirm the receipt shows **APPROVED 00** and the correct business name.

## 3. Stock

**ADMIN:** If you are upgrading the merchant from an Ingenico terminal, record the
incoming Ingenico devices as **INCOMING LEGACY**. Enter the device name and serial,
then mark with a sticker or bundle them separately — the stock return process is
different.$md$)
ON CONFLICT (slug) DO NOTHING;

COMMIT;

BEGIN;

-- Verifone / CBA / P630 -----------------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('verifone-cba-p630-ip-dongle', 'VERIFONE', 'CBA', 'P630',
 'Integrated (IP Dongle)', 'Applies to: Installs', 20,
$md$**Required:** P630 pinpad, non-PoE IP dongle and power supply, one additional
Ethernet cable per POS.

**NOTE:** You will likely need the site's IT administrator to install software or
change POS configuration. Contact details are in the site survey.

## 1. Connect the pinpad

1. Unplug the Ethernet cable from the wall socket and connect it to the IP dongle
   (either port). Run the additional Ethernet cable from the dongle to the wall
   socket, then connect the dongle's power supply. Feed the pinpad cable to the
   counter top.
2. The pinpad displays Verifone and Android screens. Select **English (Australia)**
   and tap **NEXT**.
3. Tap **ETHERNET**. Leave the setting as **DHCP** and press **SAVE**.
4. Back at the Network screen, press **NEXT** to run the network test. You should get
   three green ticks.

## 2. Configure the P630

1. Key in the DID from the job sheet. The terminal downloads its profile from VHQ.
   - **NOTE:** the screen may appear frozen. Leave it — the device is working in the background and this can take a few minutes.
2. Any updates are applied automatically.
3. Press **OK**, enter the daily admin passcode, then have the site's authorised
   contact set a **Manager passcode** and a **Cashier passcode**.
4. On a successful logon press **NEXT** (swipe up to reveal the button).
   - If logon fails with a **T907 comms error**, press the red **X** to return to the 'Device is ready' screen.
5. Tap **OK** to complete setup.

## 3. Firewall settings (POS)

Open port **2012** inbound and outbound in Windows Defender Firewall.

1. Search **Firewall** and open **Windows Defender Firewall** in Control Panel.
2. Click **Advanced Settings** > **Inbound Rules** > **New Rule**.
3. Select **Port** > **Next**. Enter **2012** under Specific Local Ports > **Next**.
4. Ensure **Allow the connection** is selected > **Next**.
5. Allow all connection types — disable **Public** only if site IT requests it >
   **Next**.
6. Name the rule **Linkly Inbound**.
7. Repeat steps 2–6 under **Outbound Rules**, naming the rule **Linkly Outbound**.

## 4. Install Linkly

1. Make a copy of the `C:\PC_EFT` folder and rename the copy to `PC_EFT_OLD`, then
   **completely uninstall** the existing Linkly.
2. On the POS, browse to **linkly.com.au** > **Resources and Support** >
   **Software Downloads** > **New Installs**. Run the downloaded installer.
3. Accept the agreement, leave the install location as default.
4. Select **Linkly Client and Server (A pinpad will be attached to this PC)**.
5. At **Select Additional Tasks**, for IP dongle tick **EMS Client Service** only.
6. Click **Install** and wait — this may take a few minutes — then **Next**.
7. **Detect** is optional. If you use it, the P630 may not be detected; that is
   expected. Click **Next**.
8. Choose bank **CBA**. Set Pinpad Port to **TCPIP**.
9. Untick the first checkbox and tick the bottom one > **Next** > **Skip** >
   **Complete** > **Finish**.

The Linkly icons now appear under "show hidden icons" in the system tray.

## 5. Hostname configuration — standard method

This replaces the need to set the POS to a static IP, so the pinpad will not
disconnect if the POS IP changes.

1. Open the Linkly client GUI from the taskbar and record the PC name in the
   **Hostname** field.
2. Open the **Linkly Connect App** on the P630 > **Function** > enter **11112227** >
   **Enter**.
3. Check the POS Address matches the hostname in the Linkly client, then select
   **Change IP Address**.
4. Toggle on **Hostname Input**, enter the hostname address, press the **green tick**.
5. Press the back arrow to return to the CBA logo screen.
6. **CRITICAL:** Reboot the terminal — the hostname change does not apply until you do.
7. The Linkly client GUI should turn green. You can also check the Linkly Connect app
   for **POS Connected**.
8. Perform a host logon and confirm the TID and merchant details are correct.
9. Perform a 1c test transaction. Recommended but not mandatory.

**ADMIN:** Upload to the work order — a photo of the Linkly Connect app showing the
hostname connection, a photo of the Linkly host logon, and a photo of the 1c receipt
if applicable. Add job notes confirming hostname setup was successful.

## 6. Static IP configuration — legacy fallback

Only needed if the terminal is running older software that has no Hostname Input
option, or if the Linkly client has no Hostname field. Update the terminal first
where possible and use the hostname method instead.

**On the pinpad:**

1. Access the pinpad menu by slowly pressing each corner of the screen clockwise,
   starting top-left, then entering the manager passcode. For the launcher, swipe up
   from the bottom of the screen.
2. Open the **Settings** app > **Network and Internet**.
3. Toggle **Wi-Fi off**, then select **Advanced Options** > **IP over USB** > set mode
   to **OFF** > **Save**.
4. Press the back arrow to **App Info**, then **Apps and Notifications** >
   **App info** > **Linkly Connect App** > **Open**.
5. Select **Function** > enter **11112227** > **Enter**.
6. Select **Change IP address**, enter the **static IP of the POS**, leave the port as
   **2012**, then press the back arrow. It should display **POS connected**.
   - **NOTE:** if it shows 'Connecting to POS', leave it a few minutes to auto-refresh. If it does not, go back to the network app, select Ethernet, and press Save on the IP address.

**On the POS — set the IP to static:**

1. Sign out of the POS user and sign in as Administrator. Credentials come from the
   site's IT support.
2. Right-click the Network icon > **Open Network & Internet Settings** >
   **Properties**.
3. Under **IP settings** > **IP assignment**, click **Edit** > **Manual** > toggle
   **IPv4** on.
4. Enter the POS IP address, subnet prefix length **24**, gateway, preferred DNS and
   alternate DNS.
   - To get the DNS numbers, open Command Prompt and run `ipconfig /all`. They are listed under the Ethernet adapter config.
5. Press **Save**.

## 7. Log on and hand over

1. In the Linkly client, click **Ctrl Panel...** > **Logon**. Confirm the logon is
   successful.
   - **ADMIN:** photograph the screen with the merchant receipt and upload to Salesforce.
2. The POS vendor must establish the connection to the Linkly client before
   transactions will work. Contact them per the details in the Salesforce job or the
   site pre-installation survey.
3. Once the vendor confirms the link, ask the merchant to put a transaction through
   ($0.01 if possible) and confirm the P630 prompts for card entry.
4. If the transaction is $0.01, complete the sale and a refund using your supplied CBA
   test card.

## Escalation

| Issue | Contact |
|---|---|
| Technical — P630 | Verifone helpdesk, 1800 656 870, option 5 |
| Further escalation | Refer to the Verifone helpdesk |
| CBA Fraud & Risk — **tech line only, do not give to merchants** | 1800 023 919, option 1, option 3 |

**NOTE:** Known gap — the Windows 7 IP change procedure for the P630 exists in the
source document as screenshots only, with no step text, so it is not reproduced here.
If a site still needs it, the steps have to be written from scratch.$md$)
ON CONFLICT (slug) DO NOTHING;

-- Verifone / NAB / T650P ----------------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('verifone-nab-hicaps-t650p', 'VERIFONE', 'NAB', 'T650P',
 'HICAPS T650P', 'HICAPS sits under NAB. Applies to: Swaps, Installs, Upgrades', 10,
$md$The steps below are specific to the HICAPS build.

## 1. First boot and download

1. Power on. Leave all settings default and press Enter through until you are asked
   for the Terminal ID (shown as **Device ID** on some models).
2. Enter the TID and press **Submit**. The HICAPS T650P TID always begins **100900**.
3. Press Submit again and allow the download to run.
   - **NOTE:** if the download has not started once `Checking For Updates...` passes 5%, call Verifone Technical Support on **1800 656 870**. They will need the TID and the device serial, then ask you to reboot — this should start the download.
4. Set the password via **Settings** > **Security**. This requires a Verifone daily
   password, provided by Verifone email.

## 2. Pairing Bluetooth

1. Swipe down from the top of the screen.
2. Press the nine dots to open the app launcher.
3. Select the **Base Control** app.
4. Select **Pair a New Dock** and press Enter through the menus.
5. If the terminal is on the base, remove it and place it back on. If it is not, sit
   it on the base. It should pair automatically.
6. Press the home button to return to the HICAPS POS screen.

## 3. Manager and cashier passwords

1. Swipe down from the top of the screen.
2. Press the nine dots to open the app launcher.
3. Open the **Connect...** app with the Verifone logo — this launches the payment app.
4. Press the main menu button in the top right, then **Settings**.
5. Press **Security**. This requires a Verifone daily password, provided by email.
6. Have the merchant set a six-digit manager code and a six-digit cashier code. Both
   must be six digits and different from each other.

## 4. Stock

**ADMIN:** If you are upgrading the merchant from an Ingenico terminal, record the
incoming Ingenico devices as **INCOMING LEGACY**. Enter the device name and serial,
then mark with a sticker or bundle them separately — the stock return process is
different.$md$)
ON CONFLICT (slug) DO NOTHING;

-- Verifone / Westpac Group / T650P ------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('verifone-wpb-t650p', 'VERIFONE', 'WPB', 'T650P',
 'T650P', 'Covers Westpac, BankSA and St.George. Applies to: Swaps, Installs, Upgrades', 10,
$md$## 1. First boot and download

1. Power on. Leave all settings default and press Enter through until you are asked
   for the Terminal ID (shown as **Device ID** on some models).
2. Enter the TID and press **Submit**. The TID always begins **100381** (Westpac) or
   **1006P** (BankSA and St.George).
   - **CRITICAL:** When entering a BankSA TID beginning `1006P`, the **P must be capital** or you will brick the terminal.
3. Press Submit again and allow the download to run.
   - **NOTE:** if the download has not started once `Checking For Updates...` passes 5%, call Verifone Technical Support on **1800 656 870**. They will need the TID and the device serial, then ask you to reboot — this should start the download.
4. Set the password via **Settings** > **Security**. This requires a Verifone daily
   password, provided by Verifone email. The **manager** password is the merchant's
   main password; the **cashier** password is for staff. Both must be six digits and
   different from each other.

## 2. Activation

Activate via the reply email from wbcprod — follow the link and enter the TID and the
terminal serial number.

If you cannot activate by email, call **1300 650 103** with the TID, merchant name,
suburb, state and device serial. BankSA and St.George also use this number.

**CRITICAL:** Do not pre-activate a terminal off site if it is an upgrade or swap.
This will stop the merchant's current terminal from transacting.

## 3. Stock

**ADMIN:** If you are upgrading the merchant from an Ingenico terminal, record the
incoming Ingenico devices as **INCOMING LEGACY**. Enter the device name and serial,
then mark with a sticker or bundle them separately — the stock return process is
different.$md$)
ON CONFLICT (slug) DO NOTHING;

-- Verifone / Hungry Jacks / P400 --------------------------------------------

INSERT INTO public.guides (slug, client_id, vendor_id, device, title, subtitle, sort_order, body_md) VALUES
('verifone-hjk-p400', 'VERIFONE', 'HJK', 'P400',
 'P400', 'Applies to: Swaps, Installs, Upgrades', 10,
$md$**Menu access:** press **9** + the green button.

**Password (new):** 9223 · **Password (old):** 3133

## Configuring — swaps

1. Plug the terminal in.
2. Press **Configure Network**.
3. Press **Network** on the touchscreen, or press **2**.
4. **Untick** the `USE DHCP` checkbox.
5. Enter the IP address, subnet mask, default gateway, primary DNS and alternate DNS
   as specified on the job sheet.
   - **NOTE:** press the **1** key twice to enter a `.` between numbers.
6. Press **Apply**, then press the red **X** to exit once complete.
7. Press **BOARD THE TERMINAL**.
8. Search by suburb (`Darwin`, `Cas`, `Palm`) and select the correct store.
9. Once the terminal has boarded, it will download.
10. Once the download completes, ask the store manager to restart the EFTPOS service
    on the POS.
11. Call NCR and run a dummy sale to confirm the POS is sending totals to the terminal.

## Contacts

| Team | Number |
|---|---|
| NCR Service Desk — Hungry Jacks (technical support for VF technicians) | 1800 931 747 |$md$)
ON CONFLICT (slug) DO NOTHING;

COMMIT;
