extends Node
## Autoload "GameManager": players, online sessions and the party loop.
## The host (multiplayer.is_server()) runs all game logic and all bots.
## Clients only send their input and draw what the host sends back.
## Online play goes through a WebSocket relay server (server/server.js), so it works in browsers.

signal players_changed
signal status_changed(text: String)
signal session_ended(reason: String)
signal rules_changed
signal session_changed          # entered/left a room, quick-match countdown, room code...
signal touch_mode_changed

const RelayPeer := preload("res://scripts/net/relay_peer.gd")
const LocalRelayServer := preload("res://scripts/net/local_relay_server.gd")

const MAX_PLAYERS := 5
const BOT_FILL_TO := 4           # bots fill empty slots up to this many players
const ROUNDS_PLAYLIST := ["bumper_sumo", "bomb_tag", "tile_painter"]
const RESULTS_TIME := 3.5
const CONNECT_TIMEOUT := 6.0
const QUICK_WAIT := 20.0         # seconds a quick match waits for more players
const QUICK_FULL_WAIT := 3.0     # once 5 humans are in
const DEFAULT_SERVER_URL := "wss://party-brawl.onrender.com/ws"
const LOCAL_TEST_PORT := 8090
const COLORS := [Color("#FF4D6D"), Color("#00F5D4"), Color("#FEE440"), Color("#9B5DE5"), Color("#FB8500")]
const GAME_INFO := {
	"bumper_sumo": {
		"title": "BUMPER SUMO",
		"rules": "AIM. LOCK IN. LAUNCH!",
		"help": "Each turn, aim where you want to slide and LOCK IN. Everyone launches at once on slippery ice - bump rivals off, but if they dodge you might slide off yourself! The ring shrinks every turn.",
		"pc": "MOUSE: point where to slide (further = more power)   CLICK / SPACE: lock in   A/D + W/S: aim with keys",
		"touch": "JOYSTICK: aim (push further = more power)   LOCK IN button",
	},
	"bomb_tag": {
		"title": "BOMB TAG",
		"rules": "PASS THE BOMB BEFORE IT BLOWS!",
		"help": "Touch a rival to pass the bomb - no tag-backs! Holder runs faster. Grab power-ups: FREEZE, TIME (+3s for holder, -2s for others), SPEED, SHIELD.",
		"pc": "WASD / ARROWS: move   SPACE / SHIFT / CLICK: dash",
		"touch": "JOYSTICK: move   DASH button",
	},
	"tile_painter": {
		"title": "TILE PAINTER",
		"rules": "PAINT THE MOST TILES!",
		"help": "Run over tiles to paint them. Dash to splash paint and stun rivals. Power-ups: PAINT BOMB, ROLLER, FREEZE, SWAP (trade colors with the leader!). Watch out for the ERASER bot - and the last 10 seconds are a FRENZY!",
		"pc": "WASD / ARROWS: move   SPACE / SHIFT / CLICK: dash + paint splash",
		"touch": "JOYSTICK: move   DASH button",
	},
}

## { peer_id: { "id", "name", "color", "score", "wins", "is_bot", "slot" } }
var players: Dictionary = {}
var local_name: String = "Player"
var fill_with_bots: bool = true
var match_active: bool = false
var round_index: int = 0
var is_online: bool = false
var autotest: bool = false

## "" (menu) | "solo" | "quick" | "room"
var session_kind: String = ""
var room_code: String = ""
var quick_countdown: float = -1.0
var server_url: String = ""
var relay = null                 # RelayPeer while online
var local_server = null          # LocalRelayServer when testing locally
var _connect_timer: float = -1.0
var _fallback_solo := false
var _last_quick_sync: int = -1
var quick_wait: float = QUICK_WAIT

## Host only: latest input per player id -> {"move": Vector2, "act": bool}
var inputs: Dictionary = {}

## Set by main.gd / main.gd sets current_minigame (kept untyped: they are script instances).
var main = null
var current_minigame = null

var _match_token: int = 0

## True when the player is using a touchscreen (shows the on-screen joystick + button).
var touch_mode: bool = false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	server_url = _default_server_url()
	touch_mode = is_touch_device()


## Switch between touch controls and keyboard/mouse based on what the player actually uses.
func _input(event: InputEvent) -> void:
	var want := touch_mode
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		if event.device != InputEvent.DEVICE_ID_EMULATION:
			want = true
	elif event is InputEventKey and event.pressed:
		want = false
	elif event is InputEventMouseMotion and event.device != InputEvent.DEVICE_ID_EMULATION and not is_touch_device():
		if (event as InputEventMouseMotion).relative.length() > 2.0:
			want = false
	if want != touch_mode:
		touch_mode = want
		touch_mode_changed.emit()


func _default_server_url() -> String:
	if OS.has_feature("web"):
		# ?server=wss://example.com/ws overrides the server (handy for testing).
		var override = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('server') || ''", true)
		if typeof(override) == TYPE_STRING and str(override) != "":
			return str(override)
		var host = JavaScriptBridge.eval("window.location.host", true)
		var proto = JavaScriptBridge.eval("window.location.protocol", true)
		if typeof(host) == TYPE_STRING and str(host) != "":
			return ("wss://" if str(proto) == "https:" else "ws://") + str(host) + "/ws"
	for path in ["user://server_url.txt", "res://server_url.txt"]:
		if FileAccess.file_exists(path):
			var u := FileAccess.get_file_as_string(path).strip_edges()
			if u != "":
				return u
	return DEFAULT_SERVER_URL


## Desktop-only: run a relay inside this game (used by tests / LAN without internet).
func start_local_server(port: int = LOCAL_TEST_PORT) -> bool:
	if OS.has_feature("web"):
		return false
	if local_server == null:
		local_server = LocalRelayServer.new()
		local_server.name = "LocalRelayServer"
		add_child(local_server)
		if local_server.start(port) != OK:
			local_server.queue_free()
			local_server = null
			return false
	server_url = "ws://127.0.0.1:%d/ws" % port
	return true


func _process(delta: float) -> void:
	if _connect_timer >= 0.0:
		_connect_timer -= delta
		if _connect_timer < 0.0 and relay != null and relay.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			_connect_failed("Couldn't reach the game server.")
	# Quick match lobby countdown (host side)
	if session_kind == "quick" and is_host() and not match_active and quick_countdown >= 0.0:
		var humans := _human_count()
		if humans >= MAX_PLAYERS:
			quick_countdown = minf(quick_countdown, QUICK_FULL_WAIT)
		quick_countdown -= delta
		var secs: int = ceili(maxf(quick_countdown, 0.0))
		if secs != _last_quick_sync:
			_last_quick_sync = secs
			if has_remote_peers():
				sync_session.rpc(session_kind, room_code, quick_countdown)
			session_changed.emit()
		if quick_countdown <= 0.0:
			quick_countdown = -1.0
			start_party_match(true)


# ---------------------------------------------------------------- helpers

func my_id() -> int:
	return multiplayer.get_unique_id()


func is_host() -> bool:
	return multiplayer.is_server()


func has_remote_peers() -> bool:
	return is_online and multiplayer.get_peers().size() > 0


func is_touch_device() -> bool:
	return OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios")


func _clean_name(n: String) -> String:
	var s := n.strip_edges()
	if s == "":
		s = "Player"
	return s.substr(0, 12)


func _human_count() -> int:
	var n := 0
	for id in players:
		if not bool(players[id]["is_bot"]):
			n += 1
	return n


## Points for finishing at `pos` (0 = first). 4 players: 3/2/1/0, 5 players: 4/3/2/1/0.
func points_for(pos: int) -> int:
	return maxi(players.size() - 1 - pos, 0)


func _free_slot() -> int:
	for s in MAX_PLAYERS:
		var used := false
		for id in players:
			if int(players[id]["slot"]) == s:
				used = true
				break
		if not used:
			return s
	return -1


func _add_player(id: int, pname: String, bot: bool, slot: int) -> void:
	players[id] = {
		"id": id,
		"name": pname,
		"color": COLORS[slot],
		"score": 0,
		"wins": 0,
		"is_bot": bot,
		"slot": slot,
	}


func _remove_bots() -> void:
	for id in players.keys():
		if bool(players[id]["is_bot"]):
			players.erase(id)


func _broadcast_players() -> void:
	if has_remote_peers():
		sync_players.rpc(players)
	else:
		players_changed.emit()


# ---------------------------------------------------------------- sessions

## Offline: you + bots, starts right away.
func play_solo(player_name: String) -> void:
	leave_session(false)
	local_name = _clean_name(player_name)
	session_kind = "solo"
	_add_player(1, local_name, autotest, 0)
	start_party_match(true)


## Online matchmaking: joins an open public game or starts one and waits for others.
func quick_play(player_name: String) -> void:
	_go_online(player_name, {"t": "quick"}, "Searching for players...")


## Online private room with a 4-letter code.
func create_room(player_name: String) -> void:
	_go_online(player_name, {"t": "host"}, "Creating room...")


func join_room(code: String, player_name: String) -> void:
	var c := code.strip_edges().to_upper()
	if c.length() != 4:
		status_changed.emit("Room codes have 4 letters.")
		return
	_go_online(player_name, {"t": "join", "code": c}, "Joining room %s..." % c)


func _go_online(player_name: String, hello: Dictionary, status: String) -> void:
	leave_session(false)
	local_name = _clean_name(player_name)
	hello["name"] = local_name
	relay = RelayPeer.new()
	relay.relay_event.connect(_on_relay_event)
	var err: int = relay.start(server_url, hello)
	if err != OK:
		relay = null
		_connect_failed("Couldn't start a connection (error %d)." % err)
		return
	_fallback_solo = str(hello["t"]) == "quick"
	if multiplayer is SceneMultiplayer:
		(multiplayer as SceneMultiplayer).server_relay = false
	multiplayer.multiplayer_peer = relay
	is_online = true
	session_kind = "connecting"
	_connect_timer = CONNECT_TIMEOUT
	status_changed.emit(status)
	session_changed.emit()


func _connect_failed(reason: String) -> void:
	var fallback := _fallback_solo
	leave_session(false)
	if fallback:
		status_changed.emit(reason + " Playing with bots instead.")
		play_solo(local_name)
	else:
		session_ended.emit(reason)


func _on_relay_event(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"welcome":
			_connect_timer = -1.0
			room_code = str(msg.get("code", ""))
			var quick := bool(msg.get("quick", false))
			session_kind = "quick" if quick else "room"
			if bool(msg.get("host", false)):
				players.clear()
				_add_player(1, local_name, autotest, 0)
				if quick:
					rules = {"mode": "party", "count": 3, "games": ROUNDS_PLAYLIST.duplicate()}
					quick_countdown = quick_wait
					status_changed.emit("Waiting for players to join...")
				else:
					status_changed.emit("Room created! Share the code %s with friends." % room_code)
				players_changed.emit()
			else:
				status_changed.emit("Joined! Waiting for the host to start...")
			session_changed.emit()
		"error":
			_connect_failed(str(msg.get("msg", "Server error.")))
		"room_closed":
			var reason := str(msg.get("reason", "The host left the game."))
			leave_session(false)
			session_ended.emit(reason)
		"socket_closed":
			if session_kind == "connecting":
				_connect_failed("Couldn't reach the game server.")
			elif is_online:
				leave_session(false)
				session_ended.emit("Lost connection to the server.")


func leave_session(emit_end: bool = true) -> void:
	_match_token += 1
	match_active = false
	_connect_timer = -1.0
	_fallback_solo = false
	quick_countdown = -1.0
	_last_quick_sync = -1
	session_kind = ""
	room_code = ""
	is_online = false
	if relay != null:
		if relay.relay_event.is_connected(_on_relay_event):
			relay.relay_event.disconnect(_on_relay_event)
		relay.close()
		relay = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	inputs.clear()
	if emit_end:
		session_ended.emit("")
	players_changed.emit()
	session_changed.emit()


func _on_peer_connected(_id: int) -> void:
	pass  # The new peer registers itself with register_player().


func _on_peer_disconnected(id: int) -> void:
	if not is_host() or not players.has(id):
		return
	var nm := str(players[id]["name"])
	if match_active:
		# Keep their character in the game, driven by the AI from now on.
		players[id]["is_bot"] = true
		players[id]["name"] = nm + " (BOT)"
		inputs.erase(id)
	else:
		players.erase(id)
	status_changed.emit("%s left." % nm)
	_broadcast_players()


func _on_connected_to_server() -> void:
	register_player.rpc_id(1, local_name)


func _on_connection_failed() -> void:
	_connect_failed("Couldn't connect to the game server.")


func _on_server_disconnected() -> void:
	if not is_online:
		return
	leave_session(false)
	session_ended.emit("The host left the game.")


@rpc("any_peer", "call_remote", "reliable")
func register_player(player_name: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	var slot := _free_slot()
	if match_active or slot < 0:
		join_rejected.rpc_id(id, "That game is full or already started.")
		return
	_add_player(id, _clean_name(player_name), false, slot)
	status_changed.emit("%s joined!" % _clean_name(player_name))
	_broadcast_players()
	sync_rules.rpc_id(id, rules)
	sync_session.rpc_id(id, session_kind, room_code, quick_countdown)
	if session_kind == "quick" and quick_countdown >= 0.0:
		# Someone new arrived: give everyone a few more seconds to gather.
		quick_countdown = maxf(quick_countdown, 6.0)


@rpc("authority", "call_remote", "reliable")
func join_rejected(reason: String) -> void:
	leave_session(false)
	session_ended.emit(reason)


@rpc("authority", "call_local", "reliable")
func sync_players(data: Dictionary) -> void:
	players = data
	players_changed.emit()


@rpc("authority", "call_remote", "reliable")
func sync_session(kind: String, code: String, countdown: float) -> void:
	session_kind = kind
	room_code = code
	quick_countdown = countdown
	session_changed.emit()


## Host: start the quick match now instead of waiting.
func quick_start_now() -> void:
	if session_kind == "quick" and is_host() and not match_active:
		quick_countdown = 0.01


# ---------------------------------------------------------------- match rules

## mode: "party" = play `count` games (most points wins)
##       "wins"  = first player to win `count` games (a win = 1st place, ties count for everyone tied)
##       "single"= one game only (games[0])
var rules: Dictionary = {"mode": "party", "count": 3, "games": ["bumper_sumo", "bomb_tag", "tile_painter"]}
var current_game_id: String = ""
var _queue: Array = []
const MAX_ROUNDS_SAFETY := 30


func set_rules(new_rules: Dictionary) -> void:
	rules = new_rules.duplicate(true)
	_sanitize_rules()
	if has_remote_peers():
		sync_rules.rpc(rules)
	else:
		rules_changed.emit()


@rpc("authority", "call_local", "reliable")
func sync_rules(r: Dictionary) -> void:
	rules = r
	rules_changed.emit()


func _sanitize_rules() -> void:
	var games: Array = []
	for g in rules.get("games", []):
		if GAME_INFO.has(str(g)) and not games.has(str(g)):
			games.append(str(g))
	if games.is_empty():
		games = ROUNDS_PLAYLIST.duplicate()
	var mode: String = str(rules.get("mode", "party"))
	if not ["party", "wins", "single"].has(mode):
		mode = "party"
	if mode == "single":
		games = [games[0]]
	rules = {"mode": mode, "count": clampi(int(rules.get("count", 3)), 1, 15), "games": games}


func rules_summary() -> String:
	var mode: String = str(rules["mode"])
	if mode == "single":
		return "ONE GAME: %s" % str(GAME_INFO[rules["games"][0]]["title"])
	if mode == "wins":
		return "FIRST TO %d WIN%s" % [int(rules["count"]), "" if int(rules["count"]) == 1 else "S"]
	return "%d GAME%s - MOST POINTS WINS" % [int(rules["count"]), "" if int(rules["count"]) == 1 else "S"]


func total_rounds() -> int:
	match str(rules["mode"]):
		"single":
			return 1
		"party":
			return int(rules["count"])
	return -1   # "wins": unknown until someone gets there


func uses_wins() -> bool:
	return str(rules["mode"]) == "wins"


## Value used to rank players in the standings (ties are real ties).
func standing_value(id) -> int:
	var info: Dictionary = players[id]
	return int(info.get("wins", 0)) if uses_wins() else int(info.get("score", 0))


## Player ids best-first, plus competition ranks (1,1,3,4 style) for ties.
func standings() -> Array:
	var ids: Array = players.keys()
	ids.sort_custom(_standing_before)
	return ids


func _standing_before(a, b) -> bool:
	var va := standing_value(a)
	var vb := standing_value(b)
	if va != vb:
		return va > vb
	return int(players[a]["slot"]) < int(players[b]["slot"])


func rank_of(id, ids: Array) -> int:
	var v := standing_value(id)
	var r := 0
	for other in ids:
		if standing_value(other) > v:
			r += 1
	return r


func _next_game() -> String:
	var pool: Array = rules["games"]
	if pool.size() == 1:
		return str(pool[0])
	if _queue.is_empty():
		var batch: Array = pool.duplicate()
		batch.shuffle()
		# Avoid playing the same game twice in a row across batches.
		if batch[0] == current_game_id and batch.size() > 1:
			var tmp = batch[0]
			batch[0] = batch[1]
			batch[1] = tmp
		_queue = batch
	return str(_queue.pop_front())


func _match_over() -> bool:
	match str(rules["mode"]):
		"single":
			return true
		"party":
			return round_index + 1 >= int(rules["count"])
		"wins":
			for id in players:
				if int(players[id].get("wins", 0)) >= int(rules["count"]):
					return true
			return round_index + 1 >= MAX_ROUNDS_SAFETY
	return true


# ---------------------------------------------------------------- party loop

func start_party_match(with_bots: bool) -> void:
	if not is_host():
		return
	_match_token += 1
	_sanitize_rules()
	_remove_bots()
	if with_bots or players.size() < 2:
		while players.size() < BOT_FILL_TO and _free_slot() >= 0:
			var slot := _free_slot()
			_add_player(-(slot + 1), "BOT %d" % (slot + 1), true, slot)
	quick_countdown = -1.0
	if relay != null:
		relay.send_control({"t": "lock"})
	for id in players:
		players[id]["score"] = 0
		players[id]["wins"] = 0
	inputs.clear()
	round_index = 0
	current_game_id = ""
	_queue.clear()
	if has_remote_peers():
		sync_rules.rpc(rules)
	match_active = true
	current_game_id = _next_game()
	load_next_minigame()


func load_next_minigame() -> void:
	if not is_host():
		return
	if has_remote_peers():
		rpc_begin_round.rpc(round_index, current_game_id, players)
	else:
		rpc_begin_round(round_index, current_game_id, players)


@rpc("authority", "call_local", "reliable")
func rpc_begin_round(index: int, game_id: String, data: Dictionary) -> void:
	players = data
	round_index = index
	current_game_id = game_id
	match_active = true
	if main != null:
		main.begin_round(index, game_id)


## Called by the active minigame on the host.
## groups = Array of Arrays of player ids, best group first. Players in the same group TIED.
func report_minigame_results(groups: Array) -> void:
	if not is_host() or not match_active:
		return
	var gains := {}
	var win_gains := {}
	var pos := 0
	for g in groups:
		var group: Array = g if g is Array else [g]
		var pts: int = points_for(pos)
		for id in group:
			if players.has(id):
				players[id]["score"] = int(players[id].get("score", 0)) + pts
				gains[id] = pts
				if pos == 0:
					players[id]["wins"] = int(players[id].get("wins", 0)) + 1
					win_gains[id] = 1
		pos += group.size()
	for id in players:
		if not gains.has(id):
			gains[id] = 0
	var over := _match_over()
	var next_game := ""
	if not over:
		next_game = _next_game()
	if autotest:
		var parts: Array = []
		for g in groups:
			var names: Array = []
			for id in g:
				names.append("%s(+%d=%dpt/%dW)" % [players[id]["name"], int(gains[id]), int(players[id]["score"]), int(players[id].get("wins", 0))])
			parts.append(" = ".join(PackedStringArray(names)))
		print("[AUTOTEST] round %d %s done: %s" % [round_index + 1, current_game_id, " > ".join(PackedStringArray(parts))])
	inputs.clear()
	var info := {"game": current_game_id, "next": next_game, "wins": win_gains, "round": round_index}
	if has_remote_peers():
		rpc_show_results.rpc(gains, info, players)
	else:
		rpc_show_results(gains, info, players)
	var token := _match_token
	get_tree().create_timer(RESULTS_TIME).timeout.connect(_after_results.bind(token, next_game))


func _after_results(token: int, next_game: String) -> void:
	if token != _match_token or not match_active or not is_host():
		return
	if next_game == "":
		match_active = false
		if autotest:
			print("[AUTOTEST] match complete -> podium")
		if has_remote_peers():
			rpc_show_podium.rpc(players)
		else:
			rpc_show_podium(players)
		return
	round_index += 1
	current_game_id = next_game
	load_next_minigame()


@rpc("authority", "call_local", "reliable")
func rpc_show_results(gains: Dictionary, info: Dictionary, data: Dictionary) -> void:
	players = data
	if main != null:
		main.show_round_results(gains, info)


@rpc("authority", "call_local", "reliable")
func rpc_show_podium(data: Dictionary) -> void:
	players = data
	match_active = false
	if main != null:
		main.show_podium()


func return_to_lobby() -> void:
	if is_online and is_host() and session_kind == "room":
		_match_token += 1
		match_active = false
		if relay != null:
			relay.send_control({"t": "unlock"})
		_remove_bots()
		# Bots that replaced players who left are gone; clean "(BOT)" humans too.
		for id in players.keys():
			if int(id) > 0 and bool(players[id]["is_bot"]):
				players.erase(id)
		for id in players:
			players[id]["score"] = 0
			players[id]["wins"] = 0
		_broadcast_players()
		if has_remote_peers():
			rpc_return_lobby.rpc()
		else:
			rpc_return_lobby()
	else:
		leave_session(false)
		if main != null:
			main.show_lobby()


@rpc("authority", "call_local", "reliable")
func rpc_return_lobby() -> void:
	match_active = false
	if main != null:
		main.show_lobby()


# ---------------------------------------------------------------- input + state sync

func send_local_input(move: Vector2, act: bool) -> void:
	if is_host():
		inputs[my_id()] = {"move": move.limit_length(1.0), "act": act}
	elif is_online and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
		submit_input.rpc_id(1, move, act)


@rpc("any_peer", "call_local", "unreliable_ordered")
func submit_input(move: Vector2, act: bool) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if id == 0:
		id = my_id()
	if players.has(id) and not bool(players[id]["is_bot"]):
		inputs[id] = {"move": move.limit_length(1.0), "act": act}


func get_input(id: int) -> Dictionary:
	if inputs.has(id):
		return inputs[id]
	return {"move": Vector2.ZERO, "act": false}


## Host -> clients, ~30 times a second.
func send_state(payload: Dictionary) -> void:
	if has_remote_peers():
		receive_state.rpc(payload)


@rpc("authority", "call_remote", "unreliable_ordered")
func receive_state(payload: Dictionary) -> void:
	if current_minigame != null and is_instance_valid(current_minigame):
		current_minigame.apply_state(payload)
