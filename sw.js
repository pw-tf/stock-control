/**
 * Service worker — deliberately minimal.
 *
 * It exists for one reason: Android Chrome will not offer a real install
 * (a WebAPK with its own launcher icon and app-switcher entry) for a site that
 * has no service worker returning something useful when the network is down.
 * Without it, "Add to Home screen" only ever makes a bookmark that opens in a
 * browser tab.
 *
 * THE ONE RULE: it must never serve stale app code.
 *
 * This app has no build step and no asset versioning — styles.css is just
 * styles.css forever — so a conventional precache would pin technicians to
 * whatever JS was current when they first loaded the app, and a bad deploy
 * would be unfixable from the server. That is a far worse bug than opening in
 * a tab, so the worker caches exactly one file: offline.html.
 *
 * Consequently:
 *   - Every request for HTML, JS, CSS, an image or Supabase data goes to the
 *     network, every time. None of it is ever cached or served from cache.
 *   - The only response this worker can ever produce from cache is the offline
 *     page, and only when a *navigation* has already failed.
 *
 * So the app cannot go stale: there is nothing stale to serve. The cost is that
 * it is not usable offline — which is accurate, because every screen reads from
 * Supabase and would be empty anyway.
 *
 * Bump VERSION when offline.html changes; activate then drops every other cache.
 */

const VERSION = 'v1';
const CACHE = `stock-offline-${VERSION}`;
const OFFLINE_URL = '/offline.html';

self.addEventListener('install', event => {
    event.waitUntil((async () => {
        const cache = await caches.open(CACHE);
        // cache: 'reload' so installing always fetches a fresh copy rather than
        // taking whatever the HTTP cache happens to be holding.
        await cache.add(new Request(OFFLINE_URL, { cache: 'reload' }));
        // Take over straight away instead of waiting for every tab to close.
        // Safe here precisely because no app code is cached — there is no
        // old/new asset mismatch to be careful about.
        await self.skipWaiting();
    })());
});

self.addEventListener('activate', event => {
    event.waitUntil((async () => {
        // Drop caches from any earlier version of this worker, including any
        // left by a future change of heart about what to cache.
        const keys = await caches.keys();
        await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
        await self.clients.claim();
    })());
});

self.addEventListener('fetch', event => {
    const request = event.request;

    // Writes are never touched: a POST to Supabase must fail loudly rather than
    // be intercepted by anything here.
    if (request.method !== 'GET') return;

    // Only page navigations get a fallback. Not calling respondWith() leaves
    // every script, stylesheet, image and API call to the browser's normal
    // handling — which is what keeps them impossible to serve stale.
    if (request.mode !== 'navigate') return;

    event.respondWith((async () => {
        try {
            return await fetch(request);
        } catch (err) {
            // Only a genuine network failure lands here. A 404 or a 500 is a
            // successful fetch and is passed through untouched, so a real
            // server error still shows as a server error.
            const cache = await caches.open(CACHE);
            const offline = await cache.match(OFFLINE_URL);
            return offline || Response.error();
        }
    })());
});
