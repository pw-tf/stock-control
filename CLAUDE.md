# Stock Submission System — Reference Guide

## Overview

A multi-tenant inventory management platform for field technicians who swap/install/deinstall stock equipment. Built as a client-side SPA with Supabase (PostgreSQL + Auth + Storage) and vanilla JavaScript, served by Apache. No backend server — all logic runs in the browser.

**Tech stack**: HTML5, vanilla JS, Supabase JS SDK, CSS custom properties, Lucide icons, JsBarcode (CODE128), Apache (.htaccess routing)

---

## User Roles

| Role | Description |
|------|-------------|
| **technician** | Field worker — enters jobs, serials, shifts. Can only see/edit own data |
| **manager** | Depot admin — manages users/agents/clients/vendors, views all shift reports, edits any shift/job in their depot |
| **merchant** | External partner — no workspace page. Guides are internal, so a merchant is routed to pending.html and the `guides` read policy returns them nothing |
| **super_admin** | Full access — creates depots, manages users across all depots, assigns roles |

**Access control**: `initAuth(requiredRoles)` in auth.js enforces role on page load. Users without an agent_id (except super_admin) are redirected to pending.html until assigned.

---

## Pages

### Authentication Pages

| Page | Purpose |
|------|---------|
| **index.html** | Login. Routes merchants → pending.html, others → home.html. Forces password change if `must_change_password=true` |
| **signup.html** | Token-based registration. **Currently broken** — it still reads `invitation_tokens` directly, and `anon` lost table access in `sql/rls-hardening.sql`. The replacement is server-side and already deployed: `validate_invitation_token(p_token)` to check a link, then `redeem_invitation_token(p_token)` to spend it and create the `user_roles` row in one statement, taking the depot from the token rather than the browser. Until signup.html calls those two RPCs, a new invitation link will not work |
| **change-password.html** | Mandatory first-login password change |
| **forgot-password.html** | Sends Supabase password reset email |
| **reset-password.html** | Completes password reset from email link (listens for PASSWORD_RECOVERY event) |
| **pending.html** | Holding page for users awaiting agent assignment. "Check Status" polls `user_roles`. Also the landing page for merchants, who get "No workspace access" copy and no Check Status button — they are not waiting on anything. It never bounces a merchant to home.html, which would ping-pong because home.html rejects them too |

### Core Pages

#### home.html — Landing Page & Analytics Dashboard
Post-login landing page for all non-merchant roles. Displays a customisable widget grid.

**Widget system**:
- Widgets defined in `WIDGET_REGISTRY` array, each with `id`, `title`, `icon`, `roles[]`, optional `shiftsOnly`, and async `render(container, user)` function
- Layout preferences stored in localStorage (`home_widget_order`, `home_widget_hidden`) as a local cache, and synced to `user_widget_config` table in Supabase for cross-device persistence
- `loadWidgetConfig()` fetches from Supabase on page load and populates localStorage; `saveWidgetConfig()` writes to localStorage immediately then upserts to Supabase asynchronously
- "Edit Layout" button (bottom of page) toggles edit mode — shows up/down reorder arrows and eye toggle per widget
- In edit mode, hidden widgets appear dimmed (so they can be re-enabled); outside edit mode they're removed from the DOM entirely. Changes save instantly

**Widgets by role**:

| Widget | ID | Roles | Data |
|--------|-----|-------|------|
| Quick Navigation | `quick-nav` | all | Static links to pages, role-aware. Plus user-defined custom links to external sites (http/https only, opened in a new tab) with a letter icon from the title's first character. Stored in localStorage (`home_quick_links`) and synced to `user_widget_config.quick_links` (JSONB); works device-locally if that column is missing |
| Jobs Today | `today-jobs` | all | Own agent's jobs today — count, type breakdown, scrollable list (newest first), click to open in inventory |
| Upcoming Jobs | `daily-job-list` | all | Planner entries from `prefilled_jobs` — booked stock jobs *and* tasks (misc entries are excluded: they are calendar markers, not work to do). A multi-day task is listed once under its start date with the range as a sub-line (e.g. "15–17 Aug"). **Defaults to "My Jobs" for every role** — the signed-in agent's entries *plus* unassigned tasks. The My Jobs / Depot toggle (remembered in localStorage `upcoming_jobs_view`) is **manager+ only**; technicians never see the depot-wide view. A manager with no agent (super_admin) gets no toggle and falls back to the depot view. Grouped by date: "Overdue (n)" first, then Today / Tomorrow / weekday date. Paginated 10 entries per page with ← → arrows at the bottom (`x–y of n`); the page breaks on the flat list, so each page carries the date headers it needs and switching Depot/My Jobs resets to page 1. Add/edit/delete jobs inline (client, vendor, job type, job number, date, notes); editing a *task* hands off to `planner.html?entry=UUID`. Up/down reordering within a day, offered only in the My Jobs view (`sort_order` is per agent per day). Click an incomplete stock job assigned to your agent → `stock-entry.html?prefilled_job=UUID` pre-fills the form. Completed entries grey out at the bottom of their day and only show on the day they were completed. Widget id stays `daily-job-list` so saved layouts keep the card |
| Open Boxes | `open-boxes` | all | Own open boxes count + jobs total. Dropdown filters by client (all) and agent (manager+). Each box clickable → inventory.html?box=ID |
| Active Shift | `active-shift` | all (shifts_enabled) | Live elapsed timer for active shift, start time, start kms |
| This Week | `week-stats` | all | Own completed shifts this week — shifts, hours, km, jobs |
| Depot Summary | `depot-summary` | manager+ | 4-stat grid: users, agents, open boxes, jobs today for depot |
| Team Activity | `team-activity` | manager+ | List of technicians currently on shift with elapsed time |
| Depot Jobs This Week | `depot-week` | manager+ | Bar chart of depot-wide jobs per day Mon–Sun |
| All Depots Overview | `all-depots` | super_admin | Table of all depots with user/agent/open box/jobs-today counts |
| System Stats | `system-stats` | super_admin | System-wide totals: total users, open boxes, jobs today |

**Deep-linking**: `inventory.html?box=ID` auto-opens box detail. `inventory.html?job=ID` auto-opens job detail. Both are bigints, both handled in inventory.html's DOMContentLoaded by reading `URLSearchParams`, and both are scoped to the caller's depot — an id from another depot renders "doesn't exist in this depot" rather than the record.

**Open Boxes filtering**: Only shows boxes whose client still exists in `depot_clients` for the depot (prevents showing historically deleted clients).

#### stock-entry.html — Stock Entry & Shift Tracking
The primary work page for technicians.

**Shift management** (when `shifts_enabled=true`):
- Start shift: records start_time, start_kms (odometer)
- End shift: records end_time, end_kms, extra_jobs, notes
- Validates: end_kms >= start_kms, same calendar day, end > start
- Stale shift detection: if shift started before today, forces completion before new shift
- Shift report with time multipliers: weekday 1x, Saturday 1.5x, Sunday 2x

**Job entry**:
- Select client → auto-creates/loads open box for agent+client
- Select vendor (filtered by client via `clients_vendors` table)
- Choose job type: swap-upgrade, install, or deinstall
- Enter job number
- Enter serials (individual fields or bulk textarea toggle) — install jobs skip serials
- Optional receipt photo (if client requires it for that job type) — compressed to ~100KB JPEG
- Optional custom timestamp
- Checks serials against the depot: an existing serial raises a confirm ("Duplicate serial found … are you sure you want to continue?") rather than blocking, so a duplicate can be logged deliberately. A failed lookup still blocks submission
- **Pre-fill via URL param**: `?prefilled_job=UUID` fetches a `prefilled_jobs` row and pre-selects client, vendor, job type, and job number. Shows a banner confirming pre-fill. On successful job submit, marks the `prefilled_jobs` row as completed (`is_completed=true`, `completed_job_id=job.id`). Refuses rows that are already completed, assigned to another agent, or not `entry_type='job'` (tasks are ticked off in the Planner, misc entries are markers)

**Box management**:
- Box ID format: `{agent}-{client_code}-{box_number}` (e.g., 804-AMT-001)
- Auto-increments box_number per agent+client
- "New Box" closes current box and creates next one

#### planner.html — Calendar Planner
Calendar for booking work onto dates. Open to technicians, managers and super_admins (merchants bounce to pending.html). Every entry is a `prefilled_jobs` row:

- **Stock job** (`entry_type='job'`) — client, vendor, job type, job number. Completed through stock entry, exactly like the old planned jobs. **Always needs an agent**, because stock entry opens the box under that agent, and always **single-day**
- **Task** (`entry_type='task'`) — a title and notes only, for work that needs no stock entry. Ticked off in the Planner or the home widget; never opens stock entry
- **Misc** (`entry_type='misc'`) — a non-work marker: leave, training, a vehicle off the road, a public holiday. **Never ticked off** (no complete action, and a DB constraint keeps `is_completed` false), **never overdue**, and **never shown in the home widget** — it lives on the calendar only

**The agent is optional on tasks and misc entries**: an unassigned one is a depot-wide item that anyone in the depot can edit, tick off or delete (technicians get the agent field on those types purely so they can choose "Unassigned"). Unassigned entries appear in *both* scopes — "My Jobs" means assigned to you **or** to nobody.

**Date ranges**: tasks and misc entries take an optional `end_date` ("Last day" in the modal). It defaults to blank, meaning a single day, and a range equal to the start date is stored as `null` rather than a redundant range. A ranged entry is drawn as one continuous bar across its days — split into clipped segments at week boundaries, and stacked into lanes when ranges overlap — instead of a chip per day. It belongs to every day it covers, so the day panel, dots and counts all include it, and dragging it moves the whole range. A ranged entry is only overdue once its **last** day has passed.

**Views**: Month (whole weeks, chips per day capped at 3 + "+N more"), Week (7 day columns), Day (the day panel alone — the grid is hidden rather than repeating one cell). The month and week grids are built as `.pl-week` rows, each holding a 7-column `.pl-week-cells` grid plus an absolutely-positioned `.pl-week-bars` layer on the same 7-column template — a grid item spanning n columns covers the gaps between them, which is what makes a multi-day bar continuous. Each cell reserves a `.pl-span-space` band so chips sit below the bars. Prev / Next / Today navigate the current period.

**Scope**: "My Jobs" by default for every role — the signed-in agent's entries plus unassigned tasks (`assigned_agent_id.eq.<agent>,assigned_agent_id.is.null`; only tasks may be unassigned, so a null agent is enough to match them). The My Jobs / Depot toggle is **manager+ only** — technicians never see the depot-wide view, and `#scopeSeg` is hidden for them entirely. Managers get an extra per-agent dropdown on top of the depot view (disabled in My Jobs scope); a manager with no agent starts on Depot.

**Interaction**:
- Click a day to select it → the day panel below lists that day's entries with full actions (open in stock entry, complete/reopen, edit, delete)
- Double-click empty space in a day to book a new entry on it
- Drag a chip onto another day to reschedule (desktop; touch uses the date field in the edit modal). Only entries you may edit are draggable
- Click a chip to open the entry modal (create/edit/delete in one place: type, date, time, agent, job or task fields, notes)
- An "Overdue & unfinished" card lists every open entry dated before today, each with a one-click "Move to today"

**Permissions** (UI mirror of the RLS policies in `sql/planner.sql`): managers and super_admins may edit anything in their depot; technicians only entries assigned to their own agent, plus unassigned tasks and misc entries. Reads are scoped exactly the same way, so a technician cannot even fetch another agent's entry — messages therefore never name another agent, they just say the entry belongs to someone else or is unavailable.

**Deep-link params**: `?date=YYYY-MM-DD` opens on that day, `?view=month|week|day` picks a view, `?entry=UUID` jumps to the entry's date and opens its modal (used by the home widget when editing a task).

**Mobile**: the toolbar card (`#plannerToolbar`) is hidden and replaced by a compact stepper (`#plannerMobileNav`) above the calendar — ‹ month name › to page through months, tap the name to jump back to today. The view and scope toggles stay desktop-only. Month cells collapse to coloured dots (accent = job, amber = task, slate = misc, red = overdue, green = done — a ranged entry contributes a dot to every day it covers, since there is no bar layer at this width), week view stacks into one column, and modal actions reflow full-width.

#### guides.html — Technician Guides
Terminal configuration procedures, stored as rows in `guides` rather than hardcoded markup so a manager can fix a menu path or phone number without a deploy. Open to technicians, managers and super_admins; **merchants are excluded** — `initAuth` bounces them and the RLS read policy (`is_staff()`) returns them nothing.

**Every guide is self-contained.** An earlier revision factored the shared setup steps into five "common procedure" entries that the device guides linked into. That reads badly in the field — a tech halfway through a swap should not be sent to open something else — so those steps are now written out in full in each guide that needs them. The cost is deliberate and worth knowing before editing: a change to a shared step (the Bluetooth menu path, say) has to be made in **each** guide that carries it. No guide body cross-references another.

**Drill-down**: client → vendor → device → guide. In this schema that means Ingenico/Verifone (who dispatched the work) → the bank (CBA, NAB, WPB, SUN, HJK) → the terminal model (Move5000, QT850, CM5P, P630, T650P, P400) → the variant (Standalone, Integrated, Cloud). Note this is the reverse of the trade documents' wording, which calls the banks "clients".
- Each level replaces the last in the page body, and cards carry a count sub-line ("2 vendors", "3 guides")
- **The breadcrumb is the page-head subtitle**, sitting under the "Guides" title beside the book mark — it is the only place the location is shown, and each ancestor in it is a button back to that level. There is deliberately no second breadcrumb inside the content card
- The search box sits above the content card, under the topbar, so it reads as searching the whole section rather than the level you happen to be on
- **A device with only one guide opens it directly**, skipping a one-item list
- Every level `history.pushState`s, so the browser back button walks back up; `popstate` re-renders from the URL
- A guide with no client is a General guide, linked below the client cards on the home screen. None are seeded — the nullable columns keep the option open rather than shipping one
- `sanitiseView()` trims a path back to the deepest level that still exists, so a stale URL or a just-deleted guide lands somewhere real rather than on an empty level

**Sidebar**: on this page the shared sidebar is taken over by a full expandable guides tree (client ▸ vendor ▸ device ▸ guide) via `setSidebarAltNav()` / `setSidebarMode()` in sidebar.js. A `← Return to main menu` item at the top swaps back to the app menu **in place** — a DOM toggle, no navigation, so the guide stays on screen — and the Guides item in that menu swaps back. The sidebar is an off-canvas drawer at every width in this app, so the same applies on mobile. Ancestors of the open guide are expanded by default; `treeCollapsed` remembers anything the user folds by hand.

**Markdown**: bodies are rendered by `markdown.js` — dependency-free and **escape-first**, so the source is run through `escapeHTML()` before a single block is parsed and author HTML is inert by construction. Supports headings, nested lists, bold/italic/code, GFM tables (wrapped in an `overflow-x:auto` div so they scroll rather than break the layout), rules, and links restricted to `http(s)` plus the internal `?guide=` form. The **CRITICAL / NOTE / ADMIN** warning tiers render as coloured callouts — that is what makes a guide scannable on a phone.

**Editing** (manager/super_admin): "New guide" plus Edit on the open guide, in one modal keyed on `editingGuideId` — title (the variant name), subtitle, client, vendor, device, slug, sort order, published toggle, and a body textarea with an Edit/Preview toggle running the real renderer. Vendor is disabled until a client is picked and device until a vendor is, mirroring the two DB check constraints. The device field is a text input backed by a `<datalist>` of devices already used under that vendor, so picking an existing one is a click and a new one is just typing. Creating from inside a device pre-fills that path. The slug auto-derives from client-vendor-device-title while creating and is never touched afterwards, because it is a URL people may have shared. Unpublished guides stay visible to managers, flagged "draft", and hidden from technicians.

**Card artwork**: every card — client, vendor and device alike — carries its mark in the same 72×44 landscape slot (64×40 below 600px), so a card is the same height wherever you are in the drill-down. The terminals are presented lying at their photographed angle rather than stood upright; upright was tried and read oddly, because a terminal standing on nothing looks wrong. Files are found by convention rather than a lookup table, so adding artwork is a filename and never a code change:

```
assets/logos/<client or vendor id>.svg|.webp
assets/devices/<vendor>-<device>.webp     bank-specific, tried first
assets/devices/<device>.webp              generic fall-back
```

- Anything missing falls back to a lettered chip — a vendor the depot uses but has no artwork for still renders, and dropping `<id>.webp` into `assets/logos/` gives that card its mark with no other change
- **The chip text is the catalogue id from the database**, via `catalogueMark()` — not initials derived from the display name. Vendors are stored as three-letter codes (CBA, NAB, **WPB**, SUN, HJK) and those are what appear on job sheets; deriving from "Westpac Group" produced "WG", a code that exists nowhere. It is set in JetBrains Mono, the face this app uses for ids and codes everywhere else
- **Client wordmarks and vendor logos are treated differently**, because the artwork is different in kind. The two manufacturer wordmarks (Ingenico, Verifone) are flat dark-on-transparent lettering, so they are masked to `currentColor` and carry no tile. The five bank logos are full-colour pictorial marks — Hungry Jack's alpha channel is its entire red square, which would mask to a featureless blob — so they render as ordinary images on the same light tile the device photos use
- **All five bank marks ship**: `cba`, `nab`, `wpb`, `sun`, `hjk`. `wpb` is the Westpac mark: the vendor id `WPB` is Westpac Group, which covers Westpac, BankSA and St.George, so there is no separate BankSA card to give a BankSA logo to
- The bank-specific device step exists because the **Move5000 is used under four banks but the supplied photo is CBA-branded**: `cba-move5000.webp` wins under CBA, everyone else gets `move5000.webp` with the branding painted out. The CM5P and P630 keep their CBA branding because those models only ever appear under CBA
- The lettered chip fallback fills the same slot, so a row mixing artwork and fallbacks still has one card height. A device chip differs from a catalogue chip only in its type face: a truncated model name is set in the UI face, an id in JetBrains Mono
- Device photos and bank marks both sit on a light tile — the hardware is mostly black, several bank marks are dark lettering, and the card is dark in nine of the eleven themes. The two wordmarks are dark-on-transparent, so instead of a tile they are painted through their own alpha channel with `currentColor` (`-webkit-mask`/`mask`), which serves all 22 theme/mode combinations from one copy of each file. The ink is deliberately **not** `--text-primary`: every dark theme's text colour is a tinted off-white (Tokyo Night's is `#c0caf5`) and a wordmark in it sits back into the card rather than reading as a logo, so it is fixed white in dark mode and a fixed near-black in light mode. A CSS mask fires no load event, so `bindArtFallbacks()` probes the file with an `Image()` before deciding the slot can stay
- Source artwork is normalised by `tools/process-guide-art.mjs` (a dev utility needing `npm i sharp`; the app itself stays dependency-free). The pipeline is **measure → level → mirror → repair → present**: the angle comes from a PCA of the alpha mask rather than from eye, and levelling first is what lets the Move5000 branding repair be specified in fixed pixel coordinates, since those are measured against the horizontal pose and survive any change to how the device is finally presented — which is what made switching the cards back to landscape a one-constant change (`FINAL_TURN`, 0 for landscape, -90 to stand them upright). Everything is then trimmed, scaled to a common content box and centred on one 320×200 canvas so no card looks heavier than its neighbour. The same tool normalises the brand marks onto a 288×176 landscape canvas, scaled by **equal area** rather than equal width or height — the marks run from near-square (Hungry Jack's) to 5:1 (Westpac), and matching their heights would have made the wide ones dominate the row — then clamped so nothing overflows the box. Re-run it when new artwork arrives

**Search**: a box on every level matches title, subtitle, device, client, vendor and body text (via `markdownToText()`), and jumps straight to a guide.

**Deep-links**: `?guide=<slug>` opens a guide; `?client=`, `?client=&vendor=`, `?client=&vendor=&device=` open a browse level.

#### inventory.html — Search & Browse
- Filter by: agent, client, date range (quick filters or custom)
- Text search: job number or serial number (min 3 chars, supports * wildcards, uses SQL ILIKE)
- Results grouped by: boxes, jobs, serials — each expandable
- Actions: view/download receipt, edit job (manager or owning tech), delete job (manager or owning tech). Deleting a job detaches any `prefilled_jobs.completed_job_id` reference and removes its receipt from storage — the receipt is deleted *before* the job row, because the storage policy resolves a file's depot through its job. A receipt that cannot be removed is reported in the success toast rather than swallowed
- **Close box on behalf** (manager/super_admin): box drawer has a "Close box" action for open boxes — closes the box and auto-opens the next box for the same agent+client (mirrors the technician's New Box flow, including the ≥1-job requirement)
- Print: generates PDF with serials and CODE128 barcodes, uses `page-break-inside: avoid` on job sections
- **Bulk receipt download** (Advanced panel): paste job numbers (one per line, or comma/tab separated) and get a single `.zip` of every receipt found. Matching is exact on `job_number` within the depot, with each number's uppercase form also probed so a lowercased paste still resolves; lookups run in chunks of 100 and receipts are fetched 5 at a time. Capped at 500 numbers. The Agent/Client/date filters beside it deliberately **do not** narrow it — the pasted list is the whole scope. Entries are named from the stored `job_number`, suffixed `-1`, `-2` … when one number covers several jobs (`DOA` covers 41). A `_manifest.txt` in the zip and an on-screen summary both break the result into downloaded / no receipt on file / not found in this depot / failed. Only ~1 in 3 jobs has a receipt, so "no receipt" is the normal case, not an error
- **Drawer navigation**: opening a job from a box's job list stacks it on top of the box. A back button appears beside the X (titled with the box id), and clicking the overlay or pressing the browser's back button peels one layer back to the box rather than closing outright. The X always closes completely. A job reached from the search results or a `?job=` link has nothing behind it, so it gets no back button and closes on any of those actions
- **Deep-link params** (all bigint ids, all depot-scoped): `?box=ID` auto-opens box detail view; `?job=ID` auto-opens job detail modal on page load; `?shift=ID` loads every job logged against that shift (plus their serials) as results, with a removable "Shift" filter chip and the shift's date/agent/time window in the page subtitle. Clearing the chip or running a new search drops the shift scope and strips the URL param

#### user.html — Profile & Shift History
- **Shift Reports tab**: date-filtered list of own shifts with summary stats (total shifts, hours, km, jobs). CSV export with dynamic client columns. Shift detail modal actions: Close, View jobs (→ `inventory.html?shift=ID`), Copy
- **Settings tab**: view email/role/agent, change password, sign out
- **Appearance card**: theme picker (themes: Ocean, Forest, Sunset, Slate, Cherry, Lavender, Teal, Sand, Midnight, Nord, Indigo) × Dark/Light mode. Saved to localStorage (`theme`, `mode`) for instant flash-free apply, AND synced to `user_widget_config.theme` / `theme_mode` in Supabase for cross-device persistence. On every page load, `initAuth()` (in auth.js) fetches the saved values and updates localStorage + DOM if different. Applied site-wide via `data-theme` and `data-mode` attributes on `<html>`

### Admin Pages

#### my-depot.html — My Depot (manager+)
Four tabs:
- **Users**: table with assign agent, view stats, delete
- **Agents**: add/delete agents (can't delete if users assigned)
- **Clients**: configure receipt requirements per job type, link/unlink vendors
- **Vendors**: add vendors (shared catalogue across depots); remove vendor from this depot (unlinks it from the depot's clients only — never deletes the vendor globally or affects other depots)

#### shifts.html — Shift Reports (manager+)
- Filter by technician and date range
- Summary stats + shift cards with click-to-detail
- Shift detail modal actions: Close, View jobs (→ `inventory.html?shift=ID`), Copy, Edit
- Edit any shift (end_time, end_kms, extra_jobs, notes)
- Copy report text or download CSV

#### analytics.html — Depot Analytics (manager+)
- Date-range presets (this week, this month, last 30/90 days) + custom from/to
- Headline totals (jobs, shifts, hours, km), jobs by type, jobs per day (daily ≤31 days, weekly buckets beyond), jobs by weekday (total + avg per weekday occurrence)
- Per-technician table (shifts, raw/adjusted hours, km, jobs, jobs/shift, jobs/hr) with CSV export
- Jobs by client and by vendor breakdowns, averages strip
- Queries use `fetchAllRows()` so long ranges aren't silently truncated at Supabase's 1000-row cap

#### manage-depots.html — Multi-Depot Management (super_admin only)
- Create/delete depots
- Create users (sets must_change_password=true)
- Assign agents, change roles, reset passwords, move users between depots
- Add/delete agents per depot

---

## Database Schema

### Core Tables

```
depots:           depot_id (PK), depot_name, created_at
agents:           agent_id (PK, e.g. "804"), depot_id
user_roles:       user_id (FK auth), email, role, agent_id, depot_id, shifts_enabled, must_change_password, created_at
boxes:            id (bigint), box_id ("804-AMT-001"), agent, client, box_number, status (open/closed), depot_id, created_at, closed_at
jobs:             id (bigint), job_number, vendor, job_type, box_id (FK), receipt_url, shift_id (FK), depot_id, created_at
serials:          id (bigint), serial_number, job_id (FK), box_id (FK), depot_id, created_at
shifts:           id (bigint), user_id, agent_id, start_time, end_time, start_kms, end_kms, extra_jobs, shift_notes, status (active/completed), depot_id
clients:          client_id (PK), display_name — global registry of client names, shared across depots
depot_clients:    client_id + depot_id (composite PK), receipt_swap_upgrade_enabled, receipt_install_enabled, receipt_deinstall_enabled
clients_vendors:  client_id + vendor_id + depot_id (composite PK)
vendors:          vendor_id (PK), display_name
invitation_tokens: token (PK), email, depot_id, used, used_at, expires_at
prefilled_jobs:   id (UUID), user_id (FK auth), depot_id, entry_type ('job'|'task'|'misc'), title, client_id, vendor_id, job_type, job_number, notes, planned_date (date, NOT NULL), end_date (date, nullable — task/misc only), planned_time (time, nullable), assigned_agent_id, is_completed, completed_job_id (FK jobs.id bigint), sort_order (int), created_at
user_widget_config: user_id (UUID PK FK auth), widget_order (JSONB), widget_hidden (JSONB), widget_spans (JSONB), quick_links (JSONB), theme (text), theme_mode (text), updated_at
guides:           id (UUID), slug (unique, url-safe), client_id (FK clients, nullable), vendor_id (FK vendors, nullable), device (text, nullable), title, subtitle, body_md, sort_order (int), is_published (bool), updated_by (FK auth), created_at, updated_at — global, NOT depot-scoped
```

**Key relationships**: `clients` and `vendors` are global catalogues; which of them a depot uses is decided by `depot_clients` and `clients_vendors`, both of which are depot-scoped. All operational data scoped by `depot_id`. Boxes belong to an agent+client. Jobs belong to a box. Serials belong to a job+box. Shifts belong to a user. `user_widget_config` is scoped per user (RLS: auth.uid() = user_id). `guides` is global like the catalogues it hangs off — terminal procedures are national, so every depot reads the same rows. `prefilled_jobs` is depot-scoped, then agent-scoped for reads *and* writes alike: managers and super_admins reach anything in their depot, technicians only entries assigned to their own agent plus unassigned tasks and misc entries (`can_write_planner_entry()`).

**Migrations**: `sql/rls-hardening.sql` installs the RLS model described under Security — run it before anything else if you are standing up a new environment. `sql/planner.sql` adds the planner columns (`entry_type`, `title`, `planned_time`, `end_date`), relaxes `client_id`/`job_number` to nullable for tasks, adds shape/integrity constraints, indexes the date lookups, and installs the RLS policies above. Run it once in the Supabase SQL editor before deploying the Planner. `sql/guides.sql` creates the `guides` table with its constraints, indexes, `updated_at` trigger and RLS, adds the nullable `display_name` column to `clients` and `vendors`, and seeds the 16 self-contained 2026 guides — its inserts are `ON CONFLICT (slug) DO NOTHING`, so re-running it never clobbers an edit made since.

---

## JavaScript Modules

| File | Purpose | Key Exports |
|------|---------|-------------|
| **auth.js** | Supabase client init (`db` global), auth functions | `checkAuth()`, `getCurrentUser()`, `initAuth(requiredRoles)`, `logout()`, `hasRole()`, `restrictByRole()` |
| **utils.js** | Shared utilities | `escapeHTML()`, `showAlert()`, `showLoading()`, `formatDateTime()`, `checkDuplicateSerials()` (throws on query failure — fail closed), `isUniqueViolation()` (23505 / HTTP 409, used for the serials and box-id races), `fetchAllRows()` (pages past Supabase's 1000-row cap), `formatBoxId()`, `downloadCSV()`, `triggerDownload()` (Blob → save), `createZipBlob()` / `crc32()` (STORE zip, no dependency — receipts are already-compressed JPEGs so DEFLATE would buy ~1%), `escapeCSV()` (quotes + guards spreadsheet formula injection), `localDateString()` / `parseLocalDate()` / `addDays()` / `startOfWeek()` (calendar maths in the browser's timezone — never `toISOString()` for a date), `getTheme()`, `setTheme()`, `applyTheme()` |
| **sidebar.js** | Navigation sidebar component | `initSidebar(user)`, `setActivePage()` — role-based menu items, hamburger drawer. `setSidebarAltNav(html, label)` / `setSidebarMode('app'\|'alt')` let a page (guides.html) swap its own navigation tree into the sidebar and back, without navigating |
| **markdown.js** | Escape-first markdown renderer for guide bodies | `renderMarkdown(src)`, `markdownToText(src)` — no dependencies; escapes before parsing so author HTML is inert |
| **icons.js** | Lucide icon initialization | Called after DOM updates to render `<i data-lucide="...">` elements |

**Global variable**: `db` (Supabase client) — initialized in auth.js, used by all pages for queries

---

## Key Business Rules

- **Duplicate serials**: checked per-depot scope. Same serial allowed in different depots. On stock entry a duplicate is a confirmable warning, not a hard stop — the tech confirms and the serial is saved; the inventory edit form still rejects duplicates outright. A serial repeated *within one job* (a doubled bulk line or scan) is collapsed before the insert — one batch cannot carry the same serial twice — and the success toast says how many lines were ignored. Logging a duplicate needs the database to allow it: `serials` carried two UNIQUE constraints (`(serial_number, depot_id)` and a global `(serial_number)`) that made the insert fail with 23505/409, and `sql/allow-duplicate-serials.sql` dropped both. The global one had also been blocking the same serial across two depots, contrary to the per-depot scoping above. If a unique index on `serial_number` is ever restored, the insert 409s, the job rolls back and the app says so
- **Install jobs**: no serials required or accepted
- **Nil swap**: entering the serial `nilswap` (exact string) on a swap-upgrade job submits the job with no serials — the sentinel is never saved as a serial and skips the duplicate check. Rejected on other job types
- **Receipt requirements**: configurable per client per job type (swap-upgrade, install, deinstall) via `depot_clients` toggles
- **Box auto-creation**: selecting a client checks for an open box for that agent+client; creates one if none exists
- **Planner entries**: a `prefilled_jobs` row is either a stock job (needs client + job number) or a task (needs a title) — enforced by a DB check constraint as well as the UI. Tasks never reach stock entry and never carry a `completed_job_id`
- **Unassigned entries**: only a task or misc entry may have a null `assigned_agent_id`. Such an entry belongs to the depot, not an agent — anyone in the depot may write it (`can_write_planner_entry()` in `sql/planner.sql`). A stock job always carries an agent
- **Planner scheduling**: `planned_date` is required and defaults to today; `planned_time` is optional and only orders entries within a day (timed first, then manual `sort_order`). Completed entries sink to the bottom of their day
- **Date ranges**: only a task or misc entry may carry an `end_date`, and never one earlier than `planned_date` (DB constraint). A job is single-day — one job is worked on one day, under one box
- **Misc entries**: markers, not work. Never completed, never overdue, never in the home widget. Colour-coded slate with a diagonal hatch rather than a saturated hue, because every saturated colour collides with one of the nine theme accents
- **Who may change an entry**: the assigned agent, or any manager/super_admin in the depot. Only the assigned agent can complete a stock job through stock entry, because the box is opened under the logged-in user's agent
- **Guide grouping**: a guide is either general (no client, vendor or device) or a full path — client, vendor and device. A vendor without a client is rejected by `guides_vendor_needs_client_check` and a device without a vendor by `guides_device_needs_vendor_check`: neither would have a branch to render on
- **Guide devices**: the level between vendor and guide. Several guides share one device when it has variants (Move5000 → Standalone / Integrated / Cloud); a device with a single guide is opened directly rather than showing a one-item list. Devices are ordered by the lowest `sort_order` among their guides
- **Guide bodies are self-contained**: no body refers the reader to another guide. Shared steps are duplicated on purpose, so editing one means editing every guide that carries it
- **Guide artwork is looked up by filename**, never registered in code: `assets/devices/<vendor>-<device>.webp` then `assets/devices/<device>.webp`, falling back to a lettered chip. A device photo carrying one bank's branding must therefore be filed under that bank and a neutral copy provided for the rest — as the Move5000 is
- **Guide slugs**: lowercase letters, digits and hyphens (DB check constraint), because the slug travels as a `?guide=` URL parameter. Renaming one breaks every link anyone has shared
- **Shift time multipliers**: Mon-Fri 1x, Sat 1.5x, Sun 2x — used in shift reports and CSV exports
- **Image compression**: client-side canvas resize (max 1200px), iterative quality reduction until < 100KB, saved as JPEG to `job-receipts` Supabase storage bucket
- **Stale shifts**: active shift from a previous day must be completed before starting a new one

---

## Design System

**Themes**: 11 themes × 2 modes (dark/light) = 22 combinations. Default: Ocean Dark. Theme applied via `data-theme` + `data-mode` attributes on `<html>`, driven by CSS `[data-theme][data-mode]` variable overrides. Each page has an inline `<script>` in `<head>` that reads localStorage and sets attributes before the stylesheet loads (prevents flash). Theme names: Ocean, Forest, Sunset, Slate, Cherry, Lavender, Teal, Sand, Midnight, Nord, Indigo. The canonical id list is `THEME_IDS` in auth.js (mirrored inline in each page's bootstrap, which has to run before any script loads) — a retired or unknown id falls back to Ocean Dark instead of reaching the DOM, where it would match no CSS block and leave a "light" user in `:root`'s dark colours.

**Fonts**: Inter (UI), JetBrains Mono (IDs, codes, numbers)

**Key CSS variables**: `--bg-primary`, `--bg-secondary`, `--bg-tertiary`, `--accent-primary`, `--text-primary`, `--text-secondary`, `--success`, `--error`, `--warning`

**Responsive breakpoints**: 1024px (tablet), 600px (phone). Sidebar becomes hamburger at 960px. Touch targets min 44px at mobile sizes.

**Print stylesheet**: custom rules for barcode printing with `page-break-inside: avoid` on job sections.

**App icon**: one master, `tools/icon-src.png`, built into the shipped set by `tools/make-favicons.mjs` (`npm i sharp`, same dev-only footing as the guide-art tool). Every page's `<head>` declares the same four links. Notes worth keeping:
- `favicon.ico` lives at the web root because browsers probe `/favicon.ico` whether or not a `<link>` points at it. It holds 16/32/48 as **PNG** entries rather than BMP — universally supported, and a fraction of the size. Chromium picks it over the PNG links at both 1x and 2x, so the PNGs are there for engines that prefer an explicit one
- `favicon-180.png` (apple-touch-icon) is the one icon flattened onto **white**. iOS composites a transparent home-screen icon onto black, and this artwork is black-outlined, so it would otherwise disappear
- `icon-192.png` / `icon-512.png` are the manifest's `any` icons, kept transparent
- `icon-maskable-512.png` is the `maskable` one. Android crops a maskable icon to a circle and only guarantees the central 80% diameter, so the artwork is drawn at **56%** of the canvas (a square inscribed in that circle) on an opaque white ground. Declaring the plain icon maskable instead would clip the book's edges
- Verifying a favicon needs **server-side** request logging: Chromium fetches it from the browser process, so it never appears in `page.on('response')`

**Installable (PWA)**: `manifest.json` + `sw.js`, registered from the bottom of auth.js because that is the one script every page loads.

- Android Chrome needs the manifest to offer a real install (a WebAPK with its own launcher icon and app-switcher entry). Without one it only makes a bookmark shortcut that opens in a browser tab. iOS Safari makes a home-screen web app regardless, which is why iPhone users had a full-screen app long before this existed
- `start_url` is `/`, **not** `/index.html`: the `.htaccess` 301-redirects `/index.html`, and a redirecting start URL can break the install
- **The service worker caches exactly one file: `offline.html`.** This app has no build step and no asset versioning — `styles.css` is `styles.css` forever — so a conventional precache would pin technicians to whatever JS was current when they first loaded the app, and a bad deploy would be unfixable from the server. That is worse than opening in a tab. So every request for HTML, JS, CSS, images and Supabase data goes to the network every time, and the only cached response the worker can ever produce is the offline page, only after a *navigation* has already failed. The app cannot go stale because there is nothing stale to serve
- A non-navigation request is never intercepted at all (no `respondWith`), and a non-GET never is either — a Supabase write must fail loudly rather than pass through this. A 404 or 500 is a *successful* fetch, so real server errors still surface as server errors
- `offline.html` is entirely self-contained: it cannot reference styles.css or the fonts, because nothing else is cached. Its colours are Ocean Dark's, hardcoded
- Bump `VERSION` in sw.js when offline.html changes; `activate` then deletes every other cache
- `.htaccess` gives `sw.js` `no-cache` explicitly. It would otherwise inherit the week-long `\.(css|js)$` rule — a stale copy of the update mechanism itself. The `manifest.json` and `offline.html` rules exist for the same reason
- Not verifiable in this environment: `beforeinstallprompt` does not fire in headless Chromium, so the install prompt itself has to be confirmed on a real device. Chrome's own manifest parser (CDP `Page.getAppManifest`) does report zero errors

---

## File Structure

```
├── index.html              Login → home.html
├── signup.html              Token-based registration → home.html
├── change-password.html     Forced password change → home.html
├── forgot-password.html     Request reset email
├── reset-password.html      Complete reset
├── pending.html             Awaiting agent assignment → home.html
├── guides.html              Technician guides — client → vendor → device drill-down
├── home.html                Landing page + analytics widgets (post-login)
├── planner.html             Calendar planner — book jobs + tasks (?date= ?view= ?entry=)
├── stock-entry.html         Stock entry + shifts (supports ?prefilled_job= param)
├── inventory.html           Search + browse + print (supports ?box= and ?job= params)
├── user.html                Profile + shift history + theme picker
├── my-depot.html            My Depot — depot config (manager)
├── shifts.html              Shift reports (manager)
├── manage-depots.html       Multi-depot admin (super_admin)
├── auth.js                  Supabase auth
├── utils.js                 Shared utilities + theme functions
├── sidebar.js               Navigation (Workspace: Home, Stock Entry, Inventory, Planner, Guides)
├── icons.js                 Lucide icons
├── markdown.js              Escape-first markdown renderer for guide bodies
├── manifest.json            Web app manifest — makes Android offer a real install
├── sw.js                    Service worker: caches ONLY offline.html, never app code
├── offline.html             Self-contained offline fallback (the one cached file)
├── favicon.ico              16/32/48 in one file — the bare /favicon.ico probe
├── assets/logos/            Manufacturer wordmarks, masked to currentColor
├── assets/devices/          Normalised terminal photos for the device cards
├── assets/icons/            Favicon PNGs, apple-touch-icon, and the 192/512 plus
│                              maskable app-icon sizes
├── tools/icon-src.png       App icon master (1024px), committed so the set
│                              can be regenerated
├── tools/make-favicons.mjs  Dev utility: build the icon set from that master
├── tools/process-guide-art.mjs  Dev utility: rotate/trim/scale source artwork
├── styles.css               Full design system + 11 theme variants
├── sql/planner.sql          One-off migration: planner columns, constraints, RLS
├── sql/guides.sql           One-off migration: guides table, RLS, catalogue display
│                              names, and the 16 seeded 2026 guides
├── sql/allow-duplicate-serials.sql  One-off migration: drop the serials unique constraints
├── sql/rls-hardening.sql    One-off migration: depot/role RLS on every table, storage
│                              policies, anon revoke, invitation-token RPCs
├── sql/rls-hardening-rollback.sql   Restores the pre-hardening state (insecure —
│                              escape hatch only)
├── sql/indexes-and-fk-coverage.sql  FK covering indexes, and why the "unused"
│                              indexes were left in place
└── .htaccess                Apache routing + cache headers
```

---

## Security

- **XSS prevention**: `escapeHTML()` applied to all database-sourced values in innerHTML templates. Guide bodies go through `renderMarkdown()` (markdown.js), which escapes the whole source *before* parsing, so a manager-authored body cannot inject markup; its link rule emits anchors only for `http(s)` and internal `?guide=` hrefs, so `javascript:` and `data:` render as plain text
- **Values interpolated into inline `onclick` attributes** must be escaped for JS *first*, then for HTML — HTML-escaping alone is useless there, because the parser decodes `&#39;` back to a quote before the JS is compiled. See `jsStr()` in guides.html
- **Auth**: Supabase session-based, role enforced on page load via `initAuth()`
- **Data isolation**: all queries scoped by `depot_id` in the client, and enforced again by RLS (below)
- **File uploads**: image/* only, compressed client-side, sanitized filenames (`{timestamp}-{jobId}`)
- **Error messages**: generic user-facing messages, detailed errors only in console.error()
- **Passwords**: minimum 8 characters, forced change on first login
- **RLS is the real enforcement boundary**: every role and ownership check in the UI is advisory — the anon key is public, so the policies are what actually hold. `sql/rls-hardening.sql` installs them on every table and on the `job-receipts` bucket. The model is:
  - **super_admin** — unrestricted across all depots
  - **manager** — anything within their own `depot_id`
  - **technician** — reads within their own depot; writes only rows under their own agent
  The one table that narrows by *role* rather than depot is `guides`: its read policy is `is_staff()`, which is technician/manager/super_admin, so a merchant reads nothing. Writes are `is_manager()`, matching `clients_write`/`vendors_write`. It is the only place in the schema where the merchant role is excluded outright — every other table lets a merchant with a depot_id read that depot.
  Reads are depot-wide rather than agent-wide by design: the duplicate-serial check is per-depot, and inventory search offers every agent in the depot to technicians too. Ownership bites on writes, mirroring the `canEdit` checks in inventory.html.
- **`anon` has no table access at all**: no grants, and no policy names it. The only things it may call are `validate_invitation_token()` and `redeem_invitation_token()`, which signup needs before a session exists
- **Privileged columns**: only a super_admin may change `user_roles.role` or `user_roles.depot_id`. Managers may edit `agent_id`, `shifts_enabled` and `must_change_password` within their depot; any user may clear their own `must_change_password`. This is what stops a manager promoting themselves
- **Helper functions are not RPC-exposed**: PostgREST publishes everything in `public` as `/rest/v1/rpc/<name>`, so the RLS helpers are `REVOKE`d from `anon` and granted to `authenticated` only — `authenticated` needs `EXECUTE` because policy expressions run as the querying role
- **HTTP headers**: `.htaccess` sets CSP, HSTS, `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` and `Permissions-Policy`, and forces HTTPS. The CSP still needs `'unsafe-inline'` for script and style (~200 `onclick` attributes, ~275 `style` attributes, and the per-page theme bootstrap); its real value is `connect-src`, which pins outbound requests to the app's own Supabase project
- **Box ID uniqueness**: `boxes` carries `UNIQUE (box_id)` *and* `UNIQUE (agent, client, box_number)`. Box numbers are computed client-side (max+1), so concurrent sessions for the same agent+client do race — the database rejects the loser with 23505 and the UI asks the tech to retry
