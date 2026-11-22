/* SwingLab service worker: werkt offline na het eerste bezoek.
   Verhoog CACHE bij elke nieuwe versie zodat oude bestanden opgeruimd worden. */
const CACHE = 'swinglab-v21';
const ASSETS = ['./', './index.html', './tv.html', './manifest.webmanifest', './peerjs.min.js', './three.min.js', './supabase.js', './591.supabase.js',
  './icon-192.png', './icon-512.png', './apple-touch-icon.png', './favicon-32.png'];

// Een nieuwe versie wacht tot de gebruiker in de app op "Activeren" tikt (zie index.html)
self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
});
self.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  // Pagina zelf: eerst online proberen (zodat updates meteen zichtbaar zijn), anders uit de cache
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then((res) => {
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res;
    }).catch(() => caches.match(req).then((hit) => hit || caches.match('./index.html'))));
    return;
  }
  // Supabase zelf nooit uit de cache, en config.js altijd vers ophalen (zodat aanpassingen meteen werken)
  const url = new URL(req.url);
  if (url.hostname.endsWith('.supabase.co')) return;
  if (url.pathname.endsWith('/config.js')) {
    e.respondWith(fetch(req).then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res; }).catch(() => caches.match(req)));
    return;
  }
  // Rest (iconen, lettertype): eerst uit de cache, anders online ophalen en bewaren
  e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
    if (res && (res.ok || res.type === 'opaque')) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
    return res;
  })));
});
