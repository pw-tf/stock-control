---
name: verify
description: Drive stock-control pages end-to-end in a headless browser without real Supabase credentials.
---

# Verifying stock-control changes

This is a no-build static SPA (vanilla JS + Supabase). There is no test suite;
verify changes by driving the real pages in Chromium via Playwright.

## Recipe

1. **Serve the repo** with any static file server on `127.0.0.1` (e.g. a 15-line
   `http.createServer` reading files from the repo root). `localhost` counts as a
   secure context, so camera/clipboard APIs work.
2. **Playwright**: `npm install playwright` in a scratch dir; launch with
   `executablePath: '/opt/pw-browsers/chromium'` (never `playwright install`).
3. **Fake the login** — no real credentials needed:
   - Seed localStorage before load with key `sb-lfydtctndrzzdyavmlva-auth-token`
     and a session JSON: `{ access_token: <any 3-part base64url JWT with future exp>,
     token_type: 'bearer', expires_at: <future epoch>, refresh_token: 'x',
     user: { id: <uuid>, email, aud: 'authenticated', role: 'authenticated' } }`.
     supabase-js reads the session from localStorage and never hits the network
     while the token is unexpired.
   - Route-intercept `https://lfydtctndrzzdyavmlva.supabase.co/rest/v1/**` and
     return canned JSON per table. Requests with `Accept: …object…` are
     `.single()`/`.maybeSingle()` calls — return an object, otherwise an array.
     Minimum for most pages: `user_roles` (role/agent_id/depot_id/shifts_enabled)
     and `user_widget_config`. For stock-entry job flows also model
     `depot_clients`, `clients_vendors`, `boxes` (GET filters like `client=eq.AMT`,
     POST insert echo with an id), `jobs`, `serials` (`serial_number=in.(A,B)` for
     the duplicate check).
4. **CDN scripts are blocked by the egress proxy** (jsdelivr/unpkg 403), but
   `registry.npmjs.org` is allowed. `npm install @supabase/supabase-js lucide
   @zxing/library jsbarcode` and route-intercept each CDN URL to the matching
   local `dist/umd` file.
5. **Assert at the UI**: toasts land in `#toastContainer .toast`; record
   intercepted REST calls in the route handler to assert what was (not) written.

## Gotchas

- Top-level `let` bindings in page scripts (`chips`, `currentBox`…) are global
  *lexical* bindings — reachable from `page.evaluate` as bare identifiers, but
  NOT as `window.chips`.
- Chromium's `--use-fake-device-for-media-capture` does NOT work in this
  container (no video devices, headless or under xvfb). To test camera flows,
  stub `navigator.mediaDevices.getUserMedia` with an init script returning
  `canvas.captureStream()` drawing your test image (e.g. a JsBarcode-rendered
  CODE128 for the scanner).
