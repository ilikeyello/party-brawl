// Party Brawl service worker.
// server.js sends THIS file for /game.service.worker.js instead of the one Godot exports.
//
// Why: Godot's worker serves its saved copy of the game FIRST and only switches to a new build
// after every tab of the game has been closed (which on an iPhone home-screen app is almost never),
// so players kept getting the old version until they cleared their website data.
//
// This one is "network first": every load asks the server for the newest files. Files that didn't
// change come back as a tiny "304 not modified" (the server uses ETags), so nothing big is
// re-downloaded. The saved copy is only used when there's no connection.

const CACHE = 'party-brawl-v1';
const OLD_GODOT_PREFIX = 'Party Brawl-sw-cache-';
const OFFLINE_URL = 'game.offline.html';

self.addEventListener('install', (event) => {
	// Take over right away instead of waiting for every tab to close.
	self.skipWaiting();
	event.waitUntil(caches.open(CACHE).then((c) => c.add(OFFLINE_URL)).catch(() => {}));
});

self.addEventListener('activate', (event) => {
	event.waitUntil((async () => {
		let hadOldGodotCache = false;
		for (const key of await caches.keys()) {
			if (key === CACHE) {
				continue;
			}
			if (key.startsWith(OLD_GODOT_PREFIX)) {
				hadOldGodotCache = true;
			}
			await caches.delete(key);
		}
		if (self.registration.navigationPreload) {
			try {
				await self.registration.navigationPreload.disable();
			} catch (e) { /* not supported */ }
		}
		await self.clients.claim();
		if (hadOldGodotCache) {
			// This device was stuck on an old saved copy: reload open game pages once (one time only)
			// so they pick up the current build.
			for (const client of await self.clients.matchAll({ type: 'window' })) {
				try {
					client.navigate(client.url);
				} catch (e) { /* ignore */ }
			}
		}
	})());
});

self.addEventListener('fetch', (event) => {
	const req = event.request;
	if (req.method !== 'GET') {
		return;
	}
	const url = new URL(req.url);
	if (url.origin !== self.location.origin || url.pathname === '/health') {
		return;
	}
	event.respondWith((async () => {
		try {
			// The server sends "Cache-Control: no-cache" + ETag, so this always checks for a newer file.
			const fresh = await fetch(req);
			if (fresh.status === 200) {
				saveCopy(req, fresh.clone());
			}
			return fresh;
		} catch (err) {
			// Offline: use the saved copy if there is one.
			const cache = await caches.open(CACHE);
			const hit = await cache.match(req, { ignoreSearch: true });
			if (hit) {
				return hit;
			}
			if (req.mode === 'navigate') {
				const offline = await cache.match(OFFLINE_URL);
				if (offline) {
					return offline;
				}
			}
			throw err;
		}
	})());
});

/** Keeps a copy for offline use, but only re-saves a file when it actually changed (the game
 *  file is ~40 MB, so writing it on every load would waste battery). */
async function saveCopy(req, response) {
	try {
		const cache = await caches.open(CACHE);
		const old = await cache.match(req, { ignoreSearch: true });
		const tag = response.headers.get('ETag');
		if (old && tag && old.headers.get('ETag') === tag) {
			return;
		}
		await cache.put(req, response);
	} catch (e) { /* storage full or not allowed: fine, we just won't have an offline copy */ }
}

self.addEventListener('message', (event) => {
	// Godot's page code can ask the worker to update; we're always up to date, so just make sure
	// we're in control.
	if (event.data === 'claim' || event.data === 'update') {
		self.skipWaiting().then(() => self.clients.claim());
	}
});
