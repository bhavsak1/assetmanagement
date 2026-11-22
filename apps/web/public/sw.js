/* global self, fetch */
// 11.5: only here so Android Chrome offers "Install". It caches nothing.
// Page loads go straight to the network (Chrome ignores an empty fetch handler); every other request is not touched.
// Never add caching here: responses can carry tenant or user data.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))
self.addEventListener('fetch', (event) => {
  if (event.request.mode === 'navigate') event.respondWith(fetch(event.request))
})
