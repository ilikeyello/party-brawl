extends Node
## Minimal static file server (desktop only) so the exported web build in server/public
## can be opened in a browser for local testing: http://127.0.0.1:8091/

const MIME := {
	"html": "text/html; charset=utf-8", "js": "application/javascript", "wasm": "application/wasm",
	"pck": "application/octet-stream", "png": "image/png", "svg": "image/svg+xml", "ico": "image/x-icon",
	"json": "application/json",
}

var tcp := TCPServer.new()
var root_dir: String = ""
var clients: Array = []   # {conn: StreamPeerTCP, buf: String}


func start(port: int, dir: String) -> Error:
	root_dir = dir
	return tcp.listen(port, "127.0.0.1")


func _process(_delta: float) -> void:
	while tcp.is_connection_available():
		clients.append({"conn": tcp.take_connection(), "buf": ""})
	for c in clients.duplicate():
		var conn: StreamPeerTCP = c["conn"]
		conn.poll()
		if conn.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.erase(c)
			continue
		var n := conn.get_available_bytes()
		if n > 0:
			var data := conn.get_data(n)
			if data[0] == OK:
				c["buf"] += (data[1] as PackedByteArray).get_string_from_utf8()
		if str(c["buf"]).contains("\r\n\r\n"):
			_respond(conn, str(c["buf"]))
			conn.disconnect_from_host()
			clients.erase(c)


func _respond(conn: StreamPeerTCP, req: String) -> void:
	var first := req.split("\r\n")[0]
	var parts := first.split(" ")
	var path := "/" if parts.size() < 2 else parts[1].split("?")[0].uri_decode()
	if path == "/":
		path = "/index.html"
	if path.contains(".."):
		path = "/index.html"
	var file := root_dir.path_join(path.substr(1))
	if path == "/game.service.worker.js" and FileAccess.file_exists(root_dir.path_join("../sw.js")):
		file = root_dir.path_join("../sw.js")   # same "network first" worker the real server sends
	if not FileAccess.file_exists(file):
		_send(conn, 404, "text/plain", "Not found".to_utf8_buffer())
		return
	var body := FileAccess.get_file_as_bytes(file)
	_send(conn, 200, MIME.get(file.get_extension().to_lower(), "application/octet-stream"), body)


func _send(conn: StreamPeerTCP, code: int, ctype: String, body: PackedByteArray) -> void:
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n" % [code, "OK" if code == 200 else "Not Found", ctype, body.size()]
	conn.set_no_delay(true)
	conn.put_data(head.to_utf8_buffer())
	# Send in chunks so big files (the .wasm) go out reliably.
	var off := 0
	while off < body.size():
		var end := mini(off + 65536, body.size())
		conn.put_data(body.slice(off, end))
		off = end
