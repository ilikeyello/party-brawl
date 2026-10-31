extends MultiplayerPeerExtension
## A MultiplayerPeer that tunnels Godot's high-level multiplayer (RPCs) through a WebSocket
## relay server. Works in web browsers (ENet does not). The relay server is in /server.
##
## Protocol (see server/server.js):
##   text frames  = JSON control messages
##     client -> server: {"t":"quick"|"host"|"join", "name":..., "code":...}, {"t":"lock"}, {"t":"unlock"}
##     server -> client: {"t":"welcome","id":int,"code":str,"host":bool,"quick":bool}
##                       {"t":"peer_joined","id":int}  {"t":"peer_left","id":int}
##                       {"t":"room_closed","reason":str} {"t":"error","msg":str}
##   binary frames = game packets
##     up:   int32 target (0 = everyone, >0 = that peer, <0 = everyone except -target) + payload
##     down: int32 sender id + payload
## The room host is always peer id 1 (the Godot "server").

signal relay_event(msg: Dictionary)

var ws := WebSocketPeer.new()
var url: String = ""
var hello: Dictionary = {}
var _hello_sent := false
var _status: int = MultiplayerPeer.CONNECTION_DISCONNECTED
var _unique_id: int = 0
var _is_host := false
var _target: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE
var _transfer_channel: int = 0
var _refuse := false
var _queue: Array = []         # [[from_id, PackedByteArray], ...]
var _peers: Dictionary = {}    # ids we have announced
var room_code: String = ""
var is_quick := false


func start(server_url: String, hello_msg: Dictionary) -> Error:
	url = server_url
	hello = hello_msg
	ws.inbound_buffer_size = 1 << 20
	ws.outbound_buffer_size = 1 << 20
	ws.max_queued_packets = 4096
	var err := ws.connect_to_url(url)
	if err != OK:
		return err
	_status = MultiplayerPeer.CONNECTION_CONNECTING
	return OK


func send_control(msg: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))


# ---------------------------------------------------------------- MultiplayerPeerExtension

func _poll() -> void:
	ws.poll()
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _hello_sent:
			_hello_sent = true
			send_control(hello)
		while ws.get_available_packet_count() > 0:
			var pkt := ws.get_packet()
			if ws.was_string_packet():
				_handle_control(pkt.get_string_from_utf8())
			elif pkt.size() >= 4:
				var from := pkt.decode_s32(0)
				_queue.append([from, pkt.slice(4)])
	elif st == WebSocketPeer.STATE_CLOSED:
		if _status != MultiplayerPeer.CONNECTION_DISCONNECTED:
			var was_connected := _status == MultiplayerPeer.CONNECTION_CONNECTED
			_status = MultiplayerPeer.CONNECTION_DISCONNECTED
			for id in _peers.keys():
				peer_disconnected.emit(id)
			_peers.clear()
			relay_event.emit({"t": "socket_closed", "was_connected": was_connected, "code": ws.get_close_code()})


func _handle_control(text: String) -> void:
	var msg = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	match str(msg.get("t", "")):
		"welcome":
			_unique_id = int(msg.get("id", 0))
			_is_host = bool(msg.get("host", false))
			room_code = str(msg.get("code", ""))
			is_quick = bool(msg.get("quick", false))
			_status = MultiplayerPeer.CONNECTION_CONNECTED
			if not _is_host:
				_peers[1] = true
				peer_connected.emit(1)
		"peer_joined":
			var id := int(msg.get("id", 0))
			if _is_host and id > 1 and not _peers.has(id):
				_peers[id] = true
				peer_connected.emit(id)
		"peer_left":
			var lid := int(msg.get("id", 0))
			if _peers.has(lid):
				_peers.erase(lid)
				peer_disconnected.emit(lid)
		"room_closed":
			ws.close(1000, "room closed")
	relay_event.emit(msg)


func _get_available_packet_count() -> int:
	return _queue.size()


func _get_packet_script() -> PackedByteArray:
	if _queue.is_empty():
		return PackedByteArray()
	var p: Array = _queue.pop_front()
	return p[1]


func _get_packet_peer() -> int:
	if _queue.is_empty():
		return 0
	return int(_queue[0][0])


func _get_packet_mode() -> MultiplayerPeer.TransferMode:
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _get_packet_channel() -> int:
	return 0


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN or _status != MultiplayerPeer.CONNECTION_CONNECTED:
		return ERR_UNCONFIGURED
	var out := PackedByteArray()
	out.resize(4)
	out.encode_s32(0, _target)
	out.append_array(buffer)
	return ws.send(out, WebSocketPeer.WRITE_MODE_BINARY)


func _get_max_packet_size() -> int:
	return 1 << 20


func _set_target_peer(peer: int) -> void:
	_target = peer


func _get_transfer_mode() -> MultiplayerPeer.TransferMode:
	return _transfer_mode as MultiplayerPeer.TransferMode


func _set_transfer_mode(mode: MultiplayerPeer.TransferMode) -> void:
	_transfer_mode = mode


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_unique_id() -> int:
	return _unique_id


func _is_server() -> bool:
	return _is_host


func _is_server_relay_supported() -> bool:
	return false


func _get_connection_status() -> MultiplayerPeer.ConnectionStatus:
	return _status as MultiplayerPeer.ConnectionStatus


func _set_refuse_new_connections(enable: bool) -> void:
	_refuse = enable


func _is_refusing_new_connections() -> bool:
	return _refuse


func _disconnect_peer(peer: int, _force: bool) -> void:
	if _is_host:
		send_control({"t": "kick", "id": peer})


func _close() -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN or ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		ws.close(1000, "bye")
	_status = MultiplayerPeer.CONNECTION_DISCONNECTED
	_peers.clear()
	_queue.clear()
