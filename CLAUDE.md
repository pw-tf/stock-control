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
| **merchant** | External partner — only sees guides.html (placeholder) |
| **super_admin** | Full access — creates depots, manages users across all depots, assigns roles |

**Access control**: `initAuth(requiredRoles)` in auth.js enforces role on page load. Users without an agent_id (except super_admin) are redirected to pending.html until assigned.

---

## Pages

### Authentication Pages

| Page | Purpose |
|------|---------|
| **index.html** | Login. Routes merchants → guides.html, others → home.html. Forces password change if `must_change_password=true` |
| **signup.html** | Token-based registration via `invitation_tokens` table. Creates user with role=technician, no agent |
| **change-password.html** | Mandatory first-login password change |
| **forgot-password.html** | Sends Supabase password reset email |
| **reset-password.html** | Completes password reset from email link (listens for PASSWORD_RECOVERY event) |
| **pending.html** | Holding page for users awaiting agent assignment. "Check Status" polls `user_roles` |
| **guides.html** | Merchant-only placeholder ("Coming Soon") |

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
| Daily Job List | `daily-job-list` | all | Pre-planned jobs from `prefilled_jobs` table. Add/edit/delete jobs (client, vendor, job type, job number, notes). Up/down reordering. Incomplete jobs persist indefinitely until deleted or completed — jobs ≥24h old show an age label ("1 day old", "2 days old", etc.) near the action buttons. Click incomplete job → stock-entry.html?prefilled_job=UUID pre-fills the form. Completed jobs grey out at the bottom and only show for the day they were completed |
| Open Boxes | `open-boxes` | all | Own open boxes count + jobs total. Dropdown filters by client (all) and agent (manager+). Each box clickable → inventory.html?box=ID |
| Active Shift | `active-shift` | all (shifts_enabled) | Live elapsed timer for active shift, start time, start kms |
| This Week | `week-stats` | all | Own completed shifts this week — shifts, hours, km, jobs |
| Depot Summary | `depot-summary` | manager+ | 4-stat grid: users, agents, open boxes, jobs today for depot |
| Team Activity | `team-activity` | manager+ | List of technicians currently on shift with elapsed time |
| Depot Jobs This Week | `depot-week` | manager+ | Bar chart of depot-wide jobs per day Mon–Sun |
| All Depots Overview | `all-depots` | super_admin | Table of all depots with user/agent/open box/jobs-today counts |
| System Stats | `system-stats` | super_admin | System-wide totals: total users, open boxes, jobs today |

**Deep-linking**: `inventory.html?box=UUID` auto-opens box detail. `inventory.html?job=UUID` auto-opens job detail. Both handled in inventory.html's DOMContentLoaded by reading `URLSearchParams`.

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
- Validates no duplicate serials within depot
- **Pre-fill via URL param**: `?prefilled_job=UUID` fetches a `prefilled_jobs` row and pre-selects client, vendor, job type, and job number. Shows a banner confirming pre-fill. On successful job submit, marks the `prefilled_jobs` row as completed (`is_completed=true`, `completed_job_id=job.id`)

**Box management**:
- Box ID format: `{agent}-{client_code}-{box_number}` (e.g., 804-AMT-001)
- Auto-increments box_number per agent+client
- "New Box" closes current box and creates next one

#### inventory.html — Search & Browse
- Filter by: agent, client, date range (quick filters or custom)
- Text search: job number or serial number (min 3 chars, supports * wildcards, uses SQL ILIKE)
- Results grouped by: boxes, jobs, serials — each expandable
- Actions: view/download receipt, edit job (manager or owning tech), delete job (manager or owning tech). Deleting a job also removes its receipt from storage and detaches any `prefilled_jobs.completed_job_id` reference
- **Close box on behalf** (manager/super_admin): box drawer has a "Close box" action for open boxes — closes the box and auto-opens the next box for the same agent+client (mirrors the technician's New Box flow, including the ≥1-job requirement)
- Print: generates PDF with serials and CODE128 barcodes, uses `page-break-inside: avoid` on job sections
- **Deep-link params**: `?box=UUID` auto-opens box detail view; `?job=UUID` auto-opens job detail modal on page load; `?shift=UUID` loads every job logged against that shift (plus their serials) as results, with a removable "Shift" filter chip and the shift's date/agent/time window in the page subtitle. Clearing the chip or running a new search drops the shift scope and strips the URL param

#### user.html — Profile & Shift History
- **Shift Reports tab**: date-filtered list of own shifts with summary stats (total shifts, hours, km, jobs). CSV export with dynamic client columns
- **Settings tab**: view email/role/agent, change password, sign out
- **Appearance card**: theme picker (themes: Ocean, Forest, Sunset, Slate, Cherry, Lavender, Teal, Sand, Perry's Beach) × Dark/Light mode. Saved to localStorage (`theme`, `mode`) for instant flash-free apply, AND synced to `user_widget_config.theme` / `theme_mode` in Supabase for cross-device persistence. On every page load, `initAuth()` (in auth.js) fetches the saved values and updates localStorage + DOM if different. Applied site-wide via `data-theme` and `data-mode` attributes on `<html>`

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
- Shift detail modal actions: Close, View jobs (→ `inventory.html?shift=UUID`), Copy, Edit
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
boxes:            id (UUID), box_id ("804-AMT-001"), agent, client, box_number, status (open/closed), depot_id, created_at, closed_at
jobs:             id (bigint), job_number, vendor, job_type, box_id (FK), receipt_url, shift_id (FK), depot_id, created_at
serials:          id (UUID), serial_number, job_id (FK), box_id (FK), depot_id, created_at
shifts:           id (UUID), user_id, agent_id, start_time, end_time, start_kms, end_kms, extra_jobs, shift_notes, status (active/completed), depot_id
depot_clients:    client_id + depot_id (composite PK), receipt_swap_upgrade_enabled, receipt_install_enabled, receipt_deinstall_enabled
clients_vendors:  client_id + vendor_id + depot_id (composite PK)
vendors:          vendor_id (PK)
invitation_tokens: token (PK), email, depot_id, used, used_at, expires_at
prefilled_jobs:   id (UUID), user_id (FK auth), depot_id, client_id, vendor_id, job_type, job_number, notes, planned_date (date), assigned_agent_id, is_completed, completed_job_id (FK jobs.id bigint), sort_order (int), created_at
user_widget_config: user_id (UUID PK FK auth), widget_order (JSONB), widget_hidden (JSONB), widget_spans (JSONB), quick_links (JSONB), theme (text), theme_mode (text), updated_at
```

**Key relationships**: All operational data scoped by `depot_id`. Boxes belong to an agent+client. Jobs belong to a box. Serials belong to a job+box. Shifts belong to a user. `prefilled_jobs` and `user_widget_config` are scoped per user (RLS: auth.uid() = user_id).

---

## JavaScript Modules

| File | Purpose | Key Exports |
|------|---------|-------------|
| **auth.js** | Supabase client init (`db` global), auth functions | `checkAuth()`, `getCurrentUser()`, `initAuth(requiredRoles)`, `logout()`, `hasRole()`, `restrictByRole()` |
| **utils.js** | Shared utilities | `escapeHTML()`, `showAlert()`, `showLoading()`, `formatDateTime()`, `checkDuplicateSerials()` (throws on query failure — fail closed), `fetchAllRows()` (pages past Supabase's 1000-row cap), `formatBoxId()`, `downloadCSV()`, `escapeCSV()` (quotes + guards spreadsheet formula injection), `getTheme()`, `setTheme()`, `applyTheme()` |
| **sidebar.js** | Navigation sidebar component | `initSidebar(user)`, `setActivePage()` — role-based menu items, mobile hamburger |
| **icons.js** | Lucide icon initialization | Called after DOM updates to render `<i data-lucide="...">` elements |

**Global variable**: `db` (Supabase client) — initialized in auth.js, used by all pages for queries

---

## Key Business Rules

- **Duplicate serials**: checked per-depot scope. Same serial allowed in different depots
- **Install jobs**: no serials required or accepted
- **Nil swap**: entering the serial `nilswap` (exact string) on a swap-upgrade job submits the job with no serials — the sentinel is never saved as a serial and skips the duplicate check. Rejected on other job types
- **Receipt requirements**: configurable per client per job type (swap-upgrade, install, deinstall) via `depot_clients` toggles
- **Box auto-creation**: selecting a client checks for an open box for that agent+client; creates one if none exists
- **Shift time multipliers**: Mon-Fri 1x, Sat 1.5x, Sun 2x — used in shift reports and CSV exports
- **Image compression**: client-side canvas resize (max 1200px), iterative quality reduction until < 100KB, saved as JPEG to `job-receipts` Supabase storage bucket
- **Stale shifts**: active shift from a previous day must be completed before starting a new one

---

## Design System

**Themes**: 9 themes × 2 modes (dark/light) = 18 combinations. Default: Ocean Dark. Theme applied via `data-theme` + `data-mode` attributes on `<html>`, driven by CSS `[data-theme][data-mode]` variable overrides. Each page has an inline `<script>` in `<head>` that reads localStorage and sets attributes before the stylesheet loads (prevents flash). Theme names: Ocean, Forest, Sunset, Slate, Cherry, Lavender, Teal, Sand, Perry's Beach.

**Fonts**: Inter (UI), JetBrains Mono (IDs, codes, numbers)

**Key CSS variables**: `--bg-primary`, `--bg-secondary`, `--bg-tertiary`, `--accent-primary`, `--text-primary`, `--text-secondary`, `--success`, `--error`, `--warning`

**Responsive breakpoints**: 1024px (tablet), 600px (phone). Sidebar becomes hamburger at 960px. Touch targets min 44px at mobile sizes.

**Print stylesheet**: custom rules for barcode printing with `page-break-inside: avoid` on job sections.

---

## File Structure

```
├── index.html              Login → home.html
├── signup.html              Token-based registration → home.html
├── change-password.html     Forced password change → home.html
├── forgot-password.html     Request reset email
├── reset-password.html      Complete reset
├── pending.html             Awaiting agent assignment → home.html
├── guides.html              Merchant placeholder
├── home.html                Landing page + analytics widgets (post-login)
├── stock-entry.html         Stock entry + shifts (supports ?prefilled_job= param)
├── inventory.html           Search + browse + print (supports ?box= and ?job= params)
├── user.html                Profile + shift history + theme picker
├── my-depot.html            My Depot — depot config (manager)
├── shifts.html              Shift reports (manager)
├── manage-depots.html       Multi-depot admin (super_admin)
├── auth.js                  Supabase auth
├── utils.js                 Shared utilities + theme functions
├── sidebar.js               Navigation (Home is first menu item)
├── icons.js                 Lucide icons
├── styles.css               Full design system + 9 theme variants
└── .htaccess                Apache routing + cache headers
```

---

## Security

- **XSS prevention**: `escapeHTML()` applied to all database-sourced values in innerHTML templates
- **Auth**: Supabase session-based, role enforced on page load via `initAuth()`
- **Data isolation**: all queries scoped by `depot_id`
- **File uploads**: image/* only, compressed client-side, sanitized filenames (`{timestamp}-{jobId}`)
- **Error messages**: generic user-facing messages, detailed errors only in console.error()
- **Passwords**: minimum 8 characters, forced change on first login
- **RLS is the real enforcement boundary**: all role/ownership checks in the UI are advisory — with a public anon key, Supabase Row Level Security policies must enforce depot scoping and role permissions on every table (jobs, serials, boxes, shifts, prefilled_jobs, user_widget_config) and the `job-receipts` bucket
- **Recommended DB constraint**: `UNIQUE (depot_id, box_id)` on `boxes` — box numbers are computed client-side (max+1), so concurrent sessions for the same agent+client can race; only a DB constraint fully prevents duplicate box IDs
