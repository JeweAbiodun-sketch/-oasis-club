// Bump this to match APP_VERSION in index.html every time you publish an update.
// Changing this string is what makes the browser treat this as a "new" service worker.
const APP_VERSION = '2026-06-25-1';
const CACHE_NAME = 'oasis-club-cache-' + APP_VERSION;

const PRECACHE_URLS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-192.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE_URLS))
  );
  // Don't auto-activate yet — wait for the page to confirm via the Update button,
  // unless the page sends SKIP_WAITING (see message listener below).
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((key) => key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      )
    ).then(() => self.clients.claim())
  );
});

// Network-first for the HTML shell so updates are detected quickly;
// cache-first fallback so the app still opens offline.
// Only same-origin app files are cached here -- Supabase API calls and the
// Supabase JS library load (both cross-origin) are intentionally left
// untouched so a network hiccup surfaces as "offline" in the app rather
// than silently serving stale data from cache.
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return; // let cross-origin requests pass through untouched

  event.respondWith(
    fetch(event.request)
      .then((networkResponse) => {
        const copy = networkResponse.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy)).catch(() => {});
        return networkResponse;
      })
      .catch(() => caches.match(event.request))
  );
});

// Lets index.html tell this worker "the user confirmed the update, take over now."
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});
