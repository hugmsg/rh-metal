// Service Worker — RH Métallurgie Dashboard
// Version du cache : incrémenter à chaque mise à jour majeure
const CACHE_NAME = 'rh-metal-v1';

const ASSETS = [
  './index.html',
  './manifest.json',
  './icon.svg',
  'https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.0/chart.umd.min.js'
];

// Installation : mise en cache des assets
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return cache.addAll(ASSETS);
    }).then(() => self.skipWaiting())
  );
});

// Activation : suppression des anciens caches
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

// Fetch : cache-first pour les assets locaux, network-first pour le reste
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // Assets locaux ou Chart.js CDN → cache-first
  if (ASSETS.some(a => event.request.url === a || url.pathname === new URL(a, self.location.href).pathname)) {
    event.respondWith(
      caches.match(event.request).then(cached => {
        if (cached) return cached;
        return fetch(event.request).then(response => {
          if (response && response.status === 200) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then(cache => cache.put(event.request, clone));
          }
          return response;
        });
      })
    );
    return;
  }

  // Tout le reste : réseau, avec fallback cache
  event.respondWith(
    fetch(event.request).catch(() => caches.match(event.request))
  );
});
