const CACHE = "plc-remote-shell-v1";
const SHELL = ["/assets/app.css", "/assets/app.js", "/manifest.webmanifest"];

self.addEventListener("install", event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
  );
  self.clients.claim();
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  const cacheable = url.pathname.startsWith("/assets/") || url.pathname === "/manifest.webmanifest";
  if (!cacheable) return;
  event.respondWith(caches.match(event.request).then(cached => cached || fetch(event.request)));
});
