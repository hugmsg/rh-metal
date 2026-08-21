// Service Worker — RH Métallurgie Dashboard
// Version du cache : incrémenter à chaque mise à jour majeure
const CACHE_NAME = 'rh-metal-v4';

// App shell (HTML/CSS/JS/manifest) : toujours vérifié en réseau d'abord pour
// ne jamais rester bloqué sur une version périmée. Cache utilisé seulement
// hors-ligne. style.css/app.js extraits de index.html le 2026-08-21 —
// changent à chaque déploiement comme index.html avant eux, donc réseau-first
// comme lui (pas cache-first comme STATIC_ASSETS ci-dessous).
const SHELL = ['./index.html', './manifest.json', './style.css', './app.js'];

// Assets vraiment statiques : cache-first (changent rarement / jamais)
const STATIC_ASSETS = [
  './icon.svg',
  'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js',
  'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll([...SHELL, ...STATIC_ASSETS]))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  const url = new URL(req.url);
  const isShell = req.mode === 'navigate' || SHELL.some(a => url.pathname === new URL(a, self.location.href).pathname);

  if (isShell) {
    // Network-first : on récupère toujours la dernière version en ligne,
    // le cache ne sert que de filet de secours hors-ligne.
    event.respondWith(
      fetch(req).then(res => {
        if (res && res.status === 200) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(req, clone));
        }
        return res;
      }).catch(() => caches.match(req))
    );
    return;
  }

  if (STATIC_ASSETS.some(a => req.url === a || url.pathname === new URL(a, self.location.href).pathname)) {
    event.respondWith(
      caches.match(req).then(cached => cached || fetch(req).then(res => {
        if (res && res.status === 200) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(req, clone));
        }
        return res;
      }))
    );
    return;
  }

  event.respondWith(fetch(req).catch(() => caches.match(req)));
});
