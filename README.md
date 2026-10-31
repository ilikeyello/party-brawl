# Party Brawl

An arcade party game for up to 5 players, built with Godot 4.7. It runs in the browser on phones, tablets and PCs, as well as on desktop.
Minigames: **Bumper Sumo**, **Bomb Tag**, **Tile Painter**.

## Ways to play
- **Quick Play Online**: matches you with other people searching right now (up to 5 per game).
  The game starts 20 s after the room opens; the host can hit **Start Now**. If nobody shows up, bots fill in.
- **Play Solo**: you plus bots, offline, starts right away.
- **Create Room / Join**: a private game with a 4-letter room code. The host picks the match rules.
- Bots fill matches up to 4 players. A 5th slot is for a 5th human.

## Controls
| | PC | Phone / tablet |
|---|---|---|
| Move | WASD / arrow keys | left joystick |
| Dash / action | Space, Shift or left click | right button |
| Sumo aim | point the mouse where you want to slide, click to lock in (or A/D to turn, W/S for power) | joystick (push further = more power) |
On-screen controls only appear on touch devices (or once you touch the screen).

## Project layout
- `scripts/game_manager.gd` (autoload) handles players, sessions, rules and the round loop
- `scripts/net/relay_peer.gd` runs Godot multiplayer over a WebSocket relay, so it works in browsers
- `scripts/net/local_relay_server.gd` is an in-game copy of the server, used for local testing
- `scripts/main.gd` builds the lobby, round intro, results and podium
- `scripts/minigames/*.gd` holds the three games plus shared base logic
- `server/` is the Node.js relay and matchmaking server, which also hosts the web build
- `fonts/` holds Lilita One and Fredoka (SIL Open Font License)

## Put it online (one-time setup)
The server does two jobs: it serves the game web page and it connects players.

1. **Export the web build** into `server/public`:
   - In Godot: *Project > Export > Web > Export Project* and save as `server/public/index.html`.
   - Or create an empty file `export_web.txt` in the project folder and run the game once. It exports and quits.
2. **Put the project on GitHub** (the whole folder, including `server/public`).
3. **Deploy on Render** (free): <https://render.com> > *New* > *Blueprint* > pick your repo.
   `render.yaml` sets everything up. You get an address like `https://party-brawl.onrender.com`.
4. Open that address on any device and play. Share it with friends.
5. Optional: for the desktop build to use your server, put your address in `server_url.txt`
   in the project folder, e.g. `wss://party-brawl.onrender.com/ws`.

Notes:
- Render's free plan sleeps after 15 minutes without visitors. The first visit after that takes about 30 s to wake up.
- Any Node host with WebSockets works (Railway, Fly.io, a VPS): run `npm install && npm start` inside `server/`.
- Test a web build against a different server by adding `?server=wss://your-server/ws` to the page address.

## Testing
- `server/`: `npm install`, then `PORT=8099 node server.js`, then `PORT=8099 node test_client.js` runs the protocol tests.
- `autotest.txt` in the project folder makes bots play a full match, with screenshots in `autotest_shots/`.
  Options: `mode=party|wins|single count=N games=bumper_sumo,bomb_tag,tile_painter net=host|web`.
  - `net=host` runs a local server, joins Quick Play, and launches a second game copy that joins the same match.
  - `net=web` serves the web build at <http://127.0.0.1:8091/?server=ws://127.0.0.1:8090/ws> and waits for a browser player.
  Delete the file to play normally.
