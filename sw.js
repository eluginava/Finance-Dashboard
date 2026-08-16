// MUGI POS service worker — keeps the till working when the wifi drops.
const CACHE = 'mugi-pos-v2';

// Same-origin files that make up the app shell. The POS lives at pos.html on
// GitHub Pages and at index.html on custom hosting, so both are attempted and
// whichever is missing is simply skipped.
const SHELL = ['./', 'index.html', 'pos.html', 'pos.webmanifest', 'manifest.json',
               'icon-192.png', 'icon-512.png', 'icon-maskable.png'];

const CHART_CDN = 'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js';

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await Promise.all(SHELL.map(url => cache.add(url).catch(() => {})));
    await cache.add(CHART_CDN).catch(() => {});   // charts still work offline
    self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;                       // never cache Supabase writes

  const url = new URL(req.url);
  if (url.hostname.endsWith('.supabase.co')) return;      // always hit the network for data

  event.respondWith((async () => {
    // Page loads go to the network first, so a freshly uploaded version shows
    // up straight away instead of one reload later. The cache is the fallback
    // when the shop's internet is down.
    if (req.mode === 'navigate') {
      try {
        const fresh = await fetch(req);
        if (fresh && fresh.ok) {
          const clone = fresh.clone();
          caches.open(CACHE).then(c => c.put(req, clone));
          return fresh;
        }
      } catch (e) { /* offline — fall through to the cache below */ }
      return (await caches.match(req, { ignoreSearch: true })) ||
             (await caches.match('pos.html')) || (await caches.match('index.html')) ||
             (await caches.match('./')) || Response.error();
    }

    const cached = await caches.match(req, { ignoreSearch: true });
    if (cached) {
      // refresh in the background so the next open has the newest build
      fetch(req).then(res => {
        if (res && res.ok) caches.open(CACHE).then(c => c.put(req, res.clone()));
      }).catch(() => {});
      return cached;
    }
    try {
      const res = await fetch(req);
      if (res && res.ok && (url.origin === self.location.origin || req.url === CHART_CDN)) {
        const clone = res.clone();
        caches.open(CACHE).then(c => c.put(req, clone));
      }
      return res;
    } catch (e) {
      // offline and not cached: fall back to the app shell for page loads
      if (req.mode === 'navigate') {
        return (await caches.match('pos.html')) || (await caches.match('index.html')) ||
               (await caches.match('./')) || Response.error();
      }
      return Response.error();
    }
  })());
});
