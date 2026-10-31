extends Node
## A tiny in-game copy of server/server.js (same protocol), for desktop builds.
## Used for local testing without deploying the Node server. Not available on web.

const MAX_PLAYERS := 5
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var tcp := TCPServer.new()
var conns: Array = []          # {ws, room, id}
var rooms: Dictionary = {}     # code -> {code, quick, locked, members: {id: conn}, created}
var verbose := false


func start(port: int) -> Error:
	return tcp.listen(port, "127.0.0.1")


func _process(_delta: float) -> void:
	while tcp.is_connection_available():
		var stream := tcp.take_connection()
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 1 << 20
		ws.outbound_buffer_size = 1 << 20
		ws.max_queued_packets = 4096
		var err := ws.accept_stream(stream)
		if verbose:
			print("[relay] tcp connection from %s:%d (accept=%d)" % [stream.get_connected_host(), stream.get_connected_port(), err])
		conns.append({"ws": ws, "room": null, "id": 0, "opened": false})
	for c in conns.duplicate():
		var ws: WebSocketPeer = c["ws"]
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			if verbose and not c["opened"]:
				print("[relay] websocket open")
			c["opened"] = true
			while ws.get_available_packet_count() > 0:
				var pkt := ws.get_packet()
				if ws.was_string_packet():
					var msg = JSON.parse_string(pkt.get_string_from_utf8())
					if typeof(msg) == TYPE_DICTIONARY:
						_control(c, msg)
				else:
					_relay(c, pkt)
		elif st == WebSocketPeer.STATE_CLOSED:
			if verbose:
				print("[relay] closed (opened=%s code=%d reason=%s)" % [c["opened"], ws.get_close_code(), ws.get_close_reason()])
			_leave(c)
			conns.erase(c)


func _send(c: Dictionary, msg: Dictionary) -> void:
	var ws: WebSocketPeer = c["ws"]
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))


func _new_code() -> String:
	while true:
		var s := ""
		for i in 4:
			s += CODE_CHARS[randi() % CODE_CHARS.length()]
		if not rooms.has(s):
			return s
	return "XXXX"


func _add(c: Dictionary, room: Dictionary, id: int) -> void:
	c["room"] = room
	c["id"] = id
	room["members"][id] = c
	_send(c, {"t": "welcome", "id": id, "code": room["code"], "host": id == 1, "quick": room["quick"]})
	if id != 1 and room["members"].has(1):
		_send(room["members"][1], {"t": "peer_joined", "id": id})


func _create(c: Dictionary, quick: bool) -> void:
	var room := {"code": _new_code(), "quick": quick, "locked": false, "members": {}, "created": Time.get_ticks_msec()}
	rooms[room["code"]] = room
	_add(c, room, 1)


func _new_id(room: Dictionary) -> int:
	var id := 2 + randi() % 2000000000
	while room["members"].has(id):
		id = 2 + randi() % 2000000000
	return id


func _control(c: Dictionary, msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"quick":
			if c["room"] != null:
				return
			var best = null
			for r in rooms.values():
				if r["quick"] and not r["locked"] and r["members"].size() < MAX_PLAYERS and r["members"].has(1):
					if best == null or int(r["created"]) < int(best["created"]):
						best = r
			if best != null:
				_add(c, best, _new_id(best))
			else:
				_create(c, true)
		"host":
			if c["room"] == null:
				_create(c, false)
		"join":
			if c["room"] != null:
				return
			var code := str(msg.get("code", "")).strip_edges().to_upper()
			var room = rooms.get(code)
			if room == null:
				_send(c, {"t": "error", "msg": "Room %s not found." % code})
			elif room["locked"]:
				_send(c, {"t": "error", "msg": "That game already started."})
			elif room["members"].size() >= MAX_PLAYERS:
				_send(c, {"t": "error", "msg": "That room is full (5 players)."})
			else:
				_add(c, room, _new_id(room))
		"lock":
			if c["room"] != null and int(c["id"]) == 1:
				c["room"]["locked"] = true
		"unlock":
			if c["room"] != null and int(c["id"]) == 1:
				c["room"]["locked"] = false


func _relay(c: Dictionary, pkt: PackedByteArray) -> void:
	var room = c["room"]
	if room == null or pkt.size() < 4:
		return
	var target := pkt.decode_s32(0)
	var out := pkt.duplicate()
	out.encode_s32(0, int(c["id"]))
	if target > 0:
		var dest = room["members"].get(target)
		if dest != null:
			(dest["ws"] as WebSocketPeer).send(out, WebSocketPeer.WRITE_MODE_BINARY)
	else:
		var except := -target if target < 0 else -1
		for id in room["members"]:
			if id == int(c["id"]) or id == except:
				continue
			(room["members"][id]["ws"] as WebSocketPeer).send(out, WebSocketPeer.WRITE_MODE_BINARY)


func _leave(c: Dictionary) -> void:
	var room = c["room"]
	if room == null:
		return
	room["members"].erase(int(c["id"]))
	if int(c["id"]) == 1:
		for other in room["members"].values():
			_send(other, {"t": "room_closed", "reason": "The host left the game."})
			other["room"] = null
			(other["ws"] as WebSocketPeer).close(1000, "room closed")
		rooms.erase(room["code"])
	else:
		if room["members"].has(1):
			_send(room["members"][1], {"t": "peer_left", "id": int(c["id"])})
		if room["members"].is_empty():
			rooms.erase(room["code"])
	c["room"] = null
