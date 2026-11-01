extends Node
## Root scene. Swaps between: Lobby -> Round intro -> Minigame -> Round results -> Podium.
## All UI is built in code (no external assets).

const UI := preload("res://scripts/ui_kit.gd")
const Backdrop := preload("res://scripts/backdrop.gd")
const FitBox := preload("res://scripts/fit_box.gd")
const MINIGAMES := {
	"bumper_sumo": preload("res://scenes/minigames/bumper_sumo.tscn"),
	"bomb_tag": preload("res://scenes/minigames/bomb_tag.tscn"),
	"tile_painter": preload("res://scenes/minigames/tile_painter.tscn"),
}
const PEDESTAL_HEIGHTS := [190.0, 140.0, 100.0, 64.0, 40.0]

var game_holder: Node
var ui_layer: CanvasLayer
var ui_root: Control
var lobby: Control
var overlay: Control
var current_game = null

var lobby_title: Label
var name_edit: LineEdit
var ip_edit: LineEdit
var status_label: Label
var slots_box: VBoxContainer
var bots_check: CheckButton
var quick_btn: Button
var host_btn: Button
var join_btn: Button
var start_btn: Button
var leave_btn: Button
var solo_btn: Button
var room_label: Label
var room_big: Label
var fullscreen_btn: Button
var controls_hint: Label
var mode_btns: Dictionary = {}
var game_btns: Dictionary = {}
var count_label: Label
var count_title: Label
var count_row: HBoxContainer
var minus_btn: Button
var plus_btn: Button
var mode_desc: Label
var games_title: Label
var _t: float = 0.0


func _ready() -> void:
	randomize()
	GameManager.main = self
	GameManager.players_changed.connect(_refresh_lobby)
	GameManager.status_changed.connect(_set_status)
	GameManager.session_ended.connect(_on_session_ended)
	GameManager.rules_changed.connect(_refresh_lobby)
	GameManager.session_changed.connect(_refresh_lobby)
	GameManager.touch_mode_changed.connect(_update_controls_hint)

	game_holder = Node.new()
	game_holder.name = "GameHolder"
	add_child(game_holder)

	ui_layer = CanvasLayer.new()
	ui_layer.name = "UILayer"
	ui_layer.layer = 20
	add_child(ui_layer)

	ui_root = Control.new()
	ui_root.name = "UIRoot"
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.theme = UI.make_theme()
	ui_layer.add_child(ui_root)
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_build_lobby()

	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_build_rotate_hint()
	show_lobby()
	if GameManager.is_ios_browser():
		_set_status("iPhone tip: tap Share, then \"Add to Home Screen\" to play full screen.")
	_handle_command_line()


## Test helpers (desktop only):
##  - res://autotest.txt          : bots play a full match and screenshots are saved (see _start_autotest)
##    add "net=host" to test online play: this copy runs a local relay server, joins Quick Play,
##    and launches a second copy of the game (--netclient) that joins the same quick match.
##  - res://export_web.txt        : exports the Web build into server/public, then quits.
func _handle_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--netclient"):
		GameManager.autotest = true
		_shot_prefix = "client_"
		_start_net_client()
		return
	if FileAccess.file_exists("res://export_web.txt"):
		_export_web()
		return
	if FileAccess.file_exists("res://autotest.txt"):
		GameManager.autotest = true
		_start_autotest()
		return
	if args.has("--solo"):
		GameManager.play_solo("Tester")


var _shot_n: int = 0
var _shot_prefix: String = "shot_"


func _setup_shots(interval: float) -> void:
	DirAccess.make_dir_recursive_absolute("res://autotest_shots")
	var f := FileAccess.open("res://autotest_shots/.gdignore", FileAccess.WRITE)
	if f != null:
		f.close()
	var shots := Timer.new()
	shots.wait_time = interval
	shots.ignore_time_scale = true
	shots.timeout.connect(_save_shot)
	add_child(shots)
	shots.start()


func _start_autotest() -> void:
	_setup_shots(2.5)
	await get_tree().create_timer(1.2).timeout
	_save_shot()
	# Optional settings in autotest.txt, e.g. "mode=wins count=2 games=tile_painter net=host"
	var cfg := FileAccess.get_file_as_string("res://autotest.txt")
	var r: Dictionary = GameManager.rules.duplicate(true)
	var net := ""
	for part in cfg.strip_edges().split(" ", false):
		var kv := part.split("=")
		if kv.size() == 2:
			match kv[0]:
				"mode":
					r["mode"] = kv[1]
				"count":
					r["count"] = int(kv[1])
				"games":
					r["games"] = Array(kv[1].split(","))
				"net":
					net = kv[1]
	GameManager.set_rules(r)
	if net == "web":
		# Serve the web build + run a relay, then host a quick match and wait for a browser player.
		GameManager.start_local_server()
		if GameManager.local_server != null:
			GameManager.local_server.verbose = true
		var web := preload("res://scripts/net/local_web_server.gd").new()
		add_child(web)
		web.start(8091, ProjectSettings.globalize_path("res://server/public"))
		GameManager.quick_wait = 120.0
		print("[AUTOTEST] web test: open http://127.0.0.1:8091/?server=ws://127.0.0.1:%d/ws" % GameManager.LOCAL_TEST_PORT)
		GameManager.quick_play("HostBot")
		GameManager.players_changed.connect(_on_webtest_players)
		return
	if net == "host":
		# Online test at normal speed so network timing is realistic.
		if not GameManager.start_local_server():
			print("[AUTOTEST] could not start local relay server")
			return
		GameManager.quick_wait = 10.0
		print("[AUTOTEST] online test: local relay at ", GameManager.server_url)
		GameManager.quick_play("HostBot")
		var exe := OS.get_executable_path()
		var proj := ProjectSettings.globalize_path("res://")
		var pid := OS.create_process(exe, ["--path", proj, "--", "--netclient"])
		print("[AUTOTEST] launched second game copy, pid ", pid)
		return
	Engine.time_scale = 2.0
	print("[AUTOTEST] starting full bot match: ", GameManager.rules_summary())
	GameManager.play_solo("AutoBot")


func _on_webtest_players() -> void:
	var names: Array = []
	for id in GameManager.players:
		names.append("%s(%d)" % [GameManager.players[id]["name"], int(id)])
	print("[AUTOTEST] players now: ", names)
	if GameManager.session_kind == "quick" and GameManager.players.size() >= 2 and GameManager.quick_countdown > 10.0:
		GameManager.quick_countdown = 10.0


## Second game copy for the online test: joins the quick match and logs what it sees.
func _start_net_client() -> void:
	_setup_shots(3.0)
	GameManager.server_url = "ws://127.0.0.1:%d/ws" % GameManager.LOCAL_TEST_PORT
	GameManager.session_changed.connect(func(): _client_log("session: %s room=%s players=%d countdown=%.0f" % [GameManager.session_kind, GameManager.room_code, GameManager.players.size(), GameManager.quick_countdown]))
	GameManager.session_ended.connect(func(reason):
		_client_log("session ended: " + str(reason))
		get_tree().create_timer(2.0).timeout.connect(get_tree().quit))
	GameManager.status_changed.connect(func(t): _client_log("status: " + str(t)))
	await get_tree().create_timer(1.5).timeout
	_client_log("joining quick play at " + GameManager.server_url)
	GameManager.quick_play("NetGuest")


func _client_log(line: String) -> void:
	var path := "res://autotest_shots/client_log.txt"
	var f: FileAccess
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_line("[%.1fs] %s" % [Time.get_ticks_msec() / 1000.0, line])
		f.close()


func _export_web() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	DirAccess.make_dir_recursive_absolute(proj.path_join("server/public"))
	var out: Array = []
	print("[EXPORT] exporting Web build...")
	var code := OS.execute(exe, ["--headless", "--path", proj, "--export-release", "Web", proj.path_join("server/public/game.html")], out, true)
	print("[EXPORT] exit code ", code)
	for line in out:
		for l in str(line).split("\n"):
			if l.contains("ERROR") or l.contains("rror") or l.contains("export") or l.contains("Export"):
				print("[EXPORT] ", l)
	get_tree().quit()


func _save_shot() -> void:
	if _shot_n >= 90:
		return
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://autotest_shots/%s%02d.png" % [_shot_prefix, _shot_n])
	_shot_n += 1


var rotate_hint: Control


## Phones held upright get a "turn sideways" message (the game is landscape).
func _build_rotate_hint() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	rotate_hint = ColorRect.new()
	(rotate_hint as ColorRect).color = Color(0.07, 0.06, 0.16, 0.96)
	rotate_hint.visible = false
	layer.add_child(rotate_hint)
	rotate_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var l := UI.make_label("TURN YOUR PHONE SIDEWAYS\nTO PLAY PARTY BRAWL", 44, Color("#FEE440"), 12, HORIZONTAL_ALIGNMENT_CENTER)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rotate_hint.add_child(l)
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_t += delta
	if rotate_hint != null:
		var vs := get_viewport().get_visible_rect().size
		rotate_hint.visible = GameManager.touch_mode and vs.y > vs.x * 1.15
	if lobby != null and lobby.visible and lobby_title != null:
		lobby_title.pivot_offset = lobby_title.size * 0.5
		lobby_title.scale = Vector2.ONE * (1.0 + 0.025 * sin(_t * 3.0))
		lobby_title.rotation = 0.015 * sin(_t * 1.7)
		lobby_title.label_settings.shadow_color = GameManager.COLORS[int(_t * 1.5) % GameManager.COLORS.size()]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.physical_keycode == KEY_ESCAPE and current_game != null:
			GameManager.return_to_lobby()


# ---------------------------------------------------------------- lobby

func _build_lobby() -> void:
	lobby = Control.new()
	lobby.name = "Lobby"
	ui_root.add_child(lobby)
	lobby.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bd: Control = Backdrop.new()
	lobby.add_child(bd)
	bd.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center: Container = FitBox.new()
	lobby.add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	if (OS.has_feature("web") or GameManager.is_touch_device()) and not GameManager.is_ios_browser():
		fullscreen_btn = UI.make_button("FULLSCREEN", Color("#3a86ff"), 15)
		fullscreen_btn.pressed.connect(_toggle_fullscreen)
		lobby.add_child(fullscreen_btn)
		fullscreen_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
		fullscreen_btn.position = Vector2(-150, 10)
		fullscreen_btn.size = Vector2(140, 40)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	center.add_child(col)

	lobby_title = UI.make_label("PARTY BRAWL", 84, Color("#FEE440"), 16, HORIZONTAL_ALIGNMENT_CENTER)
	lobby_title.label_settings.shadow_size = 0
	lobby_title.label_settings.shadow_color = Color("#FF4D6D")
	lobby_title.label_settings.shadow_offset = Vector2(0, 9)
	col.add_child(lobby_title)
	col.add_child(UI.make_label("ARCADE PARTY FOR UP TO 5  -  PLAY ON PHONE, TABLET OR PC", 17, Color("#c8c3ff"), 6, HORIZONTAL_ALIGNMENT_CENTER))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)

	# ---- Left panel: name + ways to play
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(390, 0)
	row.add_child(left)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 8)
	left.add_child(lv)

	lv.add_child(UI.make_label("YOUR NAME", 15, Color("#9d97d8")))
	name_edit = LineEdit.new()
	name_edit.text = _saved_name()
	name_edit.max_length = 12
	name_edit.placeholder_text = "Enter your name"
	name_edit.focus_entered.connect(_native_text_input.bind(name_edit, "Your name (max 12 letters):"))
	lv.add_child(name_edit)

	quick_btn = UI.make_button("QUICK PLAY ONLINE", Color("#2ECC71"), 24)
	quick_btn.custom_minimum_size = Vector2(0, 62)
	quick_btn.pressed.connect(_on_quick)
	lv.add_child(quick_btn)

	solo_btn = UI.make_button("PLAY SOLO (VS BOTS)", Color("#00a8a8"), 19)
	solo_btn.pressed.connect(_on_solo)
	lv.add_child(solo_btn)

	lv.add_child(UI.make_label("PLAY WITH FRIENDS", 14, Color("#9d97d8")))
	host_btn = UI.make_button("CREATE ROOM", Color("#3a86ff"), 19)
	host_btn.pressed.connect(_on_host)
	lv.add_child(host_btn)

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 10)
	lv.add_child(join_row)
	ip_edit = LineEdit.new()
	ip_edit.placeholder_text = "ROOM CODE"
	ip_edit.max_length = 4
	ip_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_edit.text_submitted.connect(func(_text): _on_join())
	ip_edit.focus_entered.connect(_native_text_input.bind(ip_edit, "Room code (4 letters):"))
	join_row.add_child(ip_edit)
	join_btn = UI.make_button("JOIN", Color("#9B5DE5"), 19)
	join_btn.pressed.connect(_on_join)
	join_row.add_child(join_btn)

	status_label = UI.make_label("Quick Play matches you with other players online.", 15, Color("#00F5D4"), 4)
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(350, 40)
	lv.add_child(status_label)

	# ---- Middle panel: room info, slots, bots toggle, start
	var mid := PanelContainer.new()
	mid.custom_minimum_size = Vector2(340, 0)
	row.add_child(mid)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 6)
	mid.add_child(mv)
	room_label = UI.make_label("PLAYERS  -  UP TO 5", 15, Color("#9d97d8"))
	mv.add_child(room_label)
	room_big = UI.make_label("", 30, Color("#FEE440"), 8, HORIZONTAL_ALIGNMENT_CENTER)
	room_big.visible = false
	mv.add_child(room_big)
	slots_box = VBoxContainer.new()
	slots_box.add_theme_constant_override("separation", 2)
	mv.add_child(slots_box)

	bots_check = CheckButton.new()
	bots_check.text = "Bots fill up to 4 players"
	bots_check.button_pressed = true
	bots_check.focus_mode = Control.FOCUS_NONE
	bots_check.toggled.connect(_on_bots_toggled)
	mv.add_child(bots_check)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mv.add_child(spacer)

	start_btn = UI.make_button("START MATCH", Color("#FF9F1C"), 22)
	start_btn.custom_minimum_size = Vector2(0, 54)
	start_btn.pressed.connect(_on_start)
	mv.add_child(start_btn)

	leave_btn = UI.make_button("LEAVE", Color("#e63946"), 18)
	leave_btn.pressed.connect(_on_leave)
	mv.add_child(leave_btn)

	# ---- Right panel: match rules (host / solo player can edit)
	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(380, 0)
	row.add_child(right)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 8)
	right.add_child(rv)
	rv.add_child(UI.make_label("MATCH RULES", 15, Color("#9d97d8")))

	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	rv.add_child(mode_row)
	for m in [["party", "PARTY"], ["wins", "FIRST TO"], ["single", "ONE GAME"]]:
		var b := UI.make_button(str(m[1]), Color("#3a86ff"), 16)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_mode_pressed.bind(str(m[0])))
		mode_row.add_child(b)
		mode_btns[str(m[0])] = b

	mode_desc = UI.make_label("", 15, Color("#c8c3ff"), 4)
	mode_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mode_desc.custom_minimum_size = Vector2(340, 40)
	rv.add_child(mode_desc)

	count_row = HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 10)
	count_row.alignment = BoxContainer.ALIGNMENT_CENTER
	rv.add_child(count_row)
	count_title = UI.make_label("GAMES", 18, Color.WHITE, 4)
	count_title.custom_minimum_size = Vector2(150, 0)
	count_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	count_row.add_child(count_title)
	minus_btn = UI.make_button("-", Color("#9B5DE5"), 24)
	minus_btn.custom_minimum_size = Vector2(52, 46)
	minus_btn.pressed.connect(_on_count_step.bind(-1))
	count_row.add_child(minus_btn)
	count_label = UI.make_label("3", 30, Color("#FEE440"), 6, HORIZONTAL_ALIGNMENT_CENTER)
	count_label.custom_minimum_size = Vector2(50, 0)
	count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	count_row.add_child(count_label)
	plus_btn = UI.make_button("+", Color("#9B5DE5"), 24)
	plus_btn.custom_minimum_size = Vector2(52, 46)
	plus_btn.pressed.connect(_on_count_step.bind(1))
	count_row.add_child(plus_btn)

	games_title = UI.make_label("GAMES IN THE MIX", 15, Color("#9d97d8"))
	rv.add_child(games_title)
	var game_cols := {"bumper_sumo": Color("#FF4D6D"), "bomb_tag": Color("#e07a1f"), "tile_painter": Color("#00b89c")}
	for gid in GameManager.ROUNDS_PLAYLIST:
		var gb := UI.make_button(str(GameManager.GAME_INFO[gid]["title"]), game_cols.get(gid, Color("#3a86ff")), 18)
		gb.pressed.connect(_on_game_pressed.bind(str(gid)))
		rv.add_child(gb)
		game_btns[str(gid)] = gb

	var ver := UI.make_label("v" + GameManager.BUILD, 13, Color(1, 1, 1, 0.35), 0)
	lobby.add_child(ver)
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	ver.position = Vector2(10, -24)
	controls_hint = UI.make_label("", 15, Color(1, 1, 1, 0.6), 4, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(controls_hint)
	_update_controls_hint()


## On phones in the browser, use the phone's own text box instead of the game's
## (the browser keyboard resizes the page and makes the game jump around).
func _native_text_input(edit: LineEdit, question: String) -> void:
	if not OS.has_feature("web") or not GameManager.touch_mode:
		return
	edit.release_focus()
	var cur := ""
	for ch in edit.text:
		if ch.is_valid_identifier() or ch == " " or ch.is_valid_int():
			cur += ch
	var answer = JavaScriptBridge.eval("(function(){ var r = window.prompt('%s', '%s'); return r === null ? '__cancel__' : r; })()" % [question.replace("'", ""), cur], true)
	if typeof(answer) == TYPE_STRING and str(answer) != "__cancel__":
		var t := str(answer).strip_edges().substr(0, edit.max_length if edit.max_length > 0 else 12)
		if edit == ip_edit:
			t = t.to_upper()
		edit.text = t
		if edit == name_edit:
			_remember_name()
		elif t.length() == 4:
			_on_join()


func _toggle_fullscreen() -> void:
	var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)


func _update_controls_hint() -> void:
	if controls_hint == null:
		return
	if GameManager.touch_mode:
		controls_hint.text = "MOVE: joystick (left)      ACTION: button (right)"
	else:
		controls_hint.text = "MOVE: WASD / Arrows      DASH: Space / Shift / Click      SUMO: aim with the mouse      ESC: quit match"


func _can_edit_rules() -> bool:
	if not GameManager.is_online:
		return true
	return GameManager.is_host() and GameManager.session_kind == "room"


func _on_mode_pressed(mode: String) -> void:
	if not _can_edit_rules():
		return
	var r: Dictionary = GameManager.rules.duplicate(true)
	if r["mode"] == mode:
		return
	r["mode"] = mode
	if mode == "single":
		var g: Array = r["games"]
		r["games"] = [g[0]]
	elif (r["games"] as Array).size() == 1 and GameManager.rules["mode"] == "single":
		r["games"] = GameManager.ROUNDS_PLAYLIST.duplicate()
	r["count"] = clampi(int(r["count"]), 1, 5) if mode == "wins" else int(r["count"])
	GameManager.set_rules(r)
	_refresh_lobby()


func _on_count_step(step: int) -> void:
	if not _can_edit_rules():
		return
	var r: Dictionary = GameManager.rules.duplicate(true)
	var hi: int = 5 if r["mode"] == "wins" else 10
	r["count"] = clampi(int(r["count"]) + step, 1, hi)
	GameManager.set_rules(r)
	_refresh_lobby()


func _on_game_pressed(gid: String) -> void:
	if not _can_edit_rules():
		return
	var r: Dictionary = GameManager.rules.duplicate(true)
	var games: Array = r["games"]
	if r["mode"] == "single":
		games = [gid]
	elif games.has(gid):
		if games.size() > 1:
			games.erase(gid)
	else:
		games.append(gid)
		# keep the classic order
		var ordered: Array = []
		for g in GameManager.ROUNDS_PLAYLIST:
			if games.has(g):
				ordered.append(g)
		games = ordered
	r["games"] = games
	GameManager.set_rules(r)
	_refresh_lobby()


func _refresh_rules_ui() -> void:
	if mode_desc == null:
		return
	var r: Dictionary = GameManager.rules
	var mode: String = str(r["mode"])
	var editable := _can_edit_rules()
	for m in mode_btns:
		var b: Button = mode_btns[m]
		b.modulate = Color(1, 1, 1, 1.0) if m == mode else Color(1, 1, 1, 0.4)
		b.disabled = not editable
	var n: int = int(r["count"])
	match mode:
		"party":
			mode_desc.text = "Play %d game%s. Most points wins (better places earn more)." % [n, "" if n == 1 else "s"]
			count_title.text = "GAMES"
			games_title.text = "GAMES IN THE MIX (tap to toggle)"
		"wins":
			mode_desc.text = "Keep playing until someone wins %d game%s. Ties for 1st all count as wins." % [n, "" if n == 1 else "s"]
			count_title.text = "WINS NEEDED"
			games_title.text = "GAMES IN THE MIX (tap to toggle)"
		"single":
			mode_desc.text = "Play just one game. Pick it below."
			games_title.text = "PICK A GAME"
	count_row.visible = mode != "single"
	count_label.text = str(n)
	minus_btn.disabled = not editable
	plus_btn.disabled = not editable
	var games: Array = r["games"]
	for gid in game_btns:
		var gb: Button = game_btns[gid]
		gb.modulate = Color(1, 1, 1, 1.0) if games.has(gid) else Color(1, 1, 1, 0.3)
		gb.disabled = not editable
	if not editable:
		if GameManager.session_kind == "quick":
			mode_desc.text += "  (Quick Play uses standard rules.)"
		else:
			mode_desc.text += "  (Host picks the rules.)"


func _refresh_lobby() -> void:
	if slots_box == null:
		return
	for c in slots_box.get_children():
		c.queue_free()
	var by_slot := {}
	for id in GameManager.players:
		var info: Dictionary = GameManager.players[id]
		by_slot[int(info["slot"])] = info
	var kind: String = GameManager.session_kind
	var in_room := kind == "room" or kind == "quick"
	var humans := 0
	for id in GameManager.players:
		if not bool(GameManager.players[id]["is_bot"]):
			humans += 1
	var bots_left: int = maxi(GameManager.BOT_FILL_TO - maxi(humans, 1), 0) if bots_check.button_pressed and kind != "quick" else 0
	if kind == "quick":
		bots_left = maxi(GameManager.BOT_FILL_TO - maxi(humans, 1), 0)
	for s in GameManager.MAX_PLAYERS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.custom_minimum_size = Vector2(0, 34)
		row.add_child(_ball_icon(GameManager.COLORS[s], 30.0))
		var txt := ""
		var col := Color.WHITE
		if by_slot.has(s):
			var info: Dictionary = by_slot[s]
			var id: int = int(info["id"])
			txt = "P%d  %s" % [s + 1, str(info["name"])]
			if id == 1 and GameManager.is_online:
				txt += " (HOST)"
			if id == GameManager.my_id():
				txt += " - YOU"
		else:
			var bot_here := bots_left > 0
			if bot_here:
				bots_left -= 1
			txt = "P%d  %s" % [s + 1, "Bot (auto-fill)" if bot_here else ("Waiting for player..." if in_room else "Open slot")]
			col = Color(1, 1, 1, 0.45)
		var lbl := UI.make_label(txt, 17, col, 4)
		lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lbl)
		slots_box.add_child(row)

	var online := GameManager.is_online
	var host := online and GameManager.is_host()
	match kind:
		"room":
			room_label.text = "PRIVATE ROOM - SHARE THIS CODE"
			room_big.text = GameManager.room_code
			room_big.visible = true
		"quick":
			room_label.text = "QUICK MATCH - FINDING PLAYERS"
			var cd: float = GameManager.quick_countdown
			room_big.text = ("STARTING IN %d" % ceili(cd)) if cd >= 0.0 else "STARTING..."
			room_big.visible = true
		"connecting":
			room_label.text = "CONNECTING..."
			room_big.visible = false
		_:
			room_label.text = "PLAYERS  -  UP TO 5"
			room_big.visible = false
	start_btn.visible = host and (kind == "room" or kind == "quick")
	start_btn.text = "START NOW" if kind == "quick" else "START MATCH"
	bots_check.visible = kind != "quick"
	bots_check.disabled = online and not host
	host_btn.disabled = online
	join_btn.disabled = online
	quick_btn.disabled = online
	solo_btn.disabled = online
	ip_edit.editable = not online
	name_edit.editable = not online
	leave_btn.visible = online
	_refresh_rules_ui()


func _saved_name() -> String:
	var path := "user://player_name.txt"
	if FileAccess.file_exists(path):
		var n := FileAccess.get_file_as_string(path).strip_edges()
		if n != "":
			return n.substr(0, 12)
	return "Player"


func _remember_name() -> void:
	var f := FileAccess.open("user://player_name.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(name_edit.text.strip_edges())
		f.close()


func _ball_icon(col: Color, sz: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(sz, sz)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	c.draw.connect(_draw_ball_icon.bind(c, col))
	return c


func _draw_ball_icon(c: Control, col: Color) -> void:
	var s := c.size
	var r: float = minf(s.x, s.y) * 0.42
	c.draw_colored_polygon(UI.ellipse_points(Vector2(s.x * 0.5, s.y * 0.5 + r * 0.95), r * 0.85, r * 0.28, 20), Color(0, 0, 0, 0.3))
	UI.draw_ball(c, s * 0.5, r, col, Vector2(0.3, 1.0), true)


func _set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text


func _on_quick() -> void:
	_remember_name()
	GameManager.quick_play(name_edit.text)


func _on_solo() -> void:
	_remember_name()
	GameManager.play_solo(name_edit.text)


func _on_host() -> void:
	_remember_name()
	GameManager.create_room(name_edit.text)


func _on_join() -> void:
	_remember_name()
	GameManager.join_room(ip_edit.text, name_edit.text)


func _on_start() -> void:
	if GameManager.session_kind == "quick":
		GameManager.quick_start_now()
		return
	GameManager.fill_with_bots = bots_check.button_pressed
	GameManager.start_party_match(bots_check.button_pressed)


func _on_leave() -> void:
	GameManager.leave_session(false)
	_set_status("You left the session.")
	show_lobby()


func _on_bots_toggled(on: bool) -> void:
	GameManager.fill_with_bots = on
	_refresh_lobby()


func _on_session_ended(reason: String) -> void:
	show_lobby()
	if reason != "":
		_set_status(reason)


func show_lobby() -> void:
	_clear_game()
	_clear_overlay()
	lobby.visible = true
	_refresh_lobby()


# ---------------------------------------------------------------- rounds

func begin_round(index: int, game_id: String) -> void:
	lobby.visible = false
	_clear_overlay()
	_clear_game()
	var scene: PackedScene = MINIGAMES.get(game_id)
	if scene == null:
		push_error("Unknown minigame: %s" % game_id)
		return
	var game := scene.instantiate()
	game.name = "Minigame"
	game_holder.add_child(game)
	current_game = game
	GameManager.current_minigame = game
	_show_intro(index, game_id)


func _clear_game() -> void:
	if current_game != null and is_instance_valid(current_game):
		game_holder.remove_child(current_game)
		current_game.queue_free()
	current_game = null
	GameManager.current_minigame = null


func _clear_overlay() -> void:
	if overlay == null:
		return
	for c in overlay.get_children():
		c.queue_free()


func _full_rect(c: Control) -> void:
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _show_intro(index: int, game_id: String) -> void:
	var info: Dictionary = GameManager.GAME_INFO.get(game_id, {})
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(root)
	_full_rect(root)

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.1, 0.84)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	_full_rect(dim)

	var center: Container = FitBox.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	_full_rect(center)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	center.add_child(v)
	v.add_child(UI.make_label(_round_header(index), 30, Color("#00F5D4"), 8, HORIZONTAL_ALIGNMENT_CENTER))
	var title := UI.make_label(str(info.get("title", game_id)), 86, Color("#FEE440"), 18, HORIZONTAL_ALIGNMENT_CENTER)
	title.label_settings.shadow_color = Color("#FF4D6D")
	title.label_settings.shadow_offset = Vector2(0, 9)
	v.add_child(title)
	v.add_child(UI.make_label(str(info.get("rules", "")), 32, Color.WHITE, 8, HORIZONTAL_ALIGNMENT_CENTER))
	var help := UI.make_label(str(info.get("help", "")), 20, Color("#c8c3ff"), 5, HORIZONTAL_ALIGNMENT_CENTER)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.custom_minimum_size = Vector2(760, 0)
	v.add_child(help)
	var ctl := UI.make_label(str(info.get("touch" if GameManager.touch_mode else "pc", "")), 17, Color("#FEE440"), 4, HORIZONTAL_ALIGNMENT_CENTER)
	ctl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ctl.custom_minimum_size = Vector2(900, 0)
	v.add_child(ctl)
	var count := UI.make_label("GET READY", 100, Color("#FF4D6D"), 18, HORIZONTAL_ALIGNMENT_CENTER)
	count.custom_minimum_size = Vector2(0, 140)
	count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	v.add_child(count)

	var tw := root.create_tween()
	tw.tween_interval(1.0)
	for txt in ["3", "2", "1"]:
		tw.tween_callback(_pop_count.bind(count, str(txt), Color("#FF4D6D")))
		tw.tween_interval(1.0)
	tw.tween_callback(_pop_count.bind(count, "GO!", Color("#2ECC71")))
	tw.tween_property(dim, "color:a", 0.0, 0.2)
	tw.tween_property(root, "modulate:a", 0.0, 0.45)
	tw.tween_callback(root.queue_free)


func _pop_count(label: Label, txt: String, col: Color) -> void:
	label.text = txt
	label.label_settings.font_color = col
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2(1.7, 1.7)
	var tw := label.create_tween()
	tw.tween_property(label, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _round_header(index: int) -> String:
	match str(GameManager.rules["mode"]):
		"single":
			return "ONE GAME"
		"wins":
			return "ROUND %d  -  FIRST TO %d WINS" % [index + 1, int(GameManager.rules["count"])]
	return "ROUND %d OF %d" % [index + 1, GameManager.total_rounds()]


func _ordinal(n: int) -> String:
	match n:
		1:
			return "1ST"
		2:
			return "2ND"
		3:
			return "3RD"
	return "%dTH" % n


func show_round_results(gains: Dictionary, info: Dictionary) -> void:
	_clear_overlay()
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(root)
	_full_rect(root)

	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.1, 0.6)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)
	_full_rect(dim)

	var center: Container = FitBox.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	_full_rect(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(860, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)

	var game_id: String = str(info.get("game", ""))
	var ginfo: Dictionary = GameManager.GAME_INFO.get(game_id, {})
	var ridx: int = int(info.get("round", 0))
	v.add_child(UI.make_label("ROUND %d RESULTS  -  %s" % [ridx + 1, str(ginfo.get("title", ""))], 30, Color("#FEE440"), 8, HORIZONTAL_ALIGNMENT_CENTER))
	v.add_child(UI.make_label(GameManager.rules_summary(), 16, Color("#9d97d8"), 4, HORIZONTAL_ALIGNMENT_CENTER))

	var wins_mode := GameManager.uses_wins()
	var round_wins: Dictionary = info.get("wins", {})
	var ids: Array = GameManager.standings()
	var max_val: float = 1.0
	if wins_mode:
		max_val = float(GameManager.rules["count"])
	else:
		var total := GameManager.total_rounds()
		max_val = float(maxi(GameManager.players.size() - 1, 1)) * float(maxi(total, 1))
	var bar_w := 300.0
	var i := 0
	for id in ids:
		var pinfo: Dictionary = GameManager.players[id]
		var gain: int = int(gains.get(id, 0))
		var won_now: bool = round_wins.has(id)
		var val: int = GameManager.standing_value(id)
		var prev_val: int = val - (1 if won_now else 0) if wins_mode else val - gain
		var pcol: Color = pinfo["color"]
		var rank: int = GameManager.rank_of(id, ids)
		var tied := false
		for other in ids:
			if other != id and GameManager.standing_value(other) == val:
				tied = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var rk := UI.make_label(("=" if tied else "") + _ordinal(rank + 1), 20, Color("#FEE440") if rank == 0 else Color(1, 1, 1, 0.7), 5, HORIZONTAL_ALIGNMENT_CENTER)
		rk.custom_minimum_size = Vector2(60, 0)
		rk.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(rk)
		row.add_child(_ball_icon(pcol, 44.0))
		var nm := UI.make_label(str(pinfo["name"]), 22, Color.WHITE, 5)
		nm.custom_minimum_size = Vector2(150, 0)
		nm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(nm)
		var gtxt := "+%d" % gain
		var gcol := Color(1, 1, 1, 0.4)
		if wins_mode:
			gtxt = "WIN!" if won_now else "-"
			gcol = Color("#FEE440") if won_now else Color(1, 1, 1, 0.35)
		elif gain == 3:
			gcol = Color("#FEE440")
		elif gain > 0:
			gcol = Color("#00F5D4")
		var g := UI.make_label(gtxt, 28, gcol, 8, HORIZONTAL_ALIGNMENT_CENTER)
		g.custom_minimum_size = Vector2(80, 0)
		g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(g)

		var bar := Control.new()
		bar.custom_minimum_size = Vector2(bar_w, 30)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar)
		var bg := Panel.new()
		bg.add_theme_stylebox_override("panel", UI.box(Color(1, 1, 1, 0.08), 8))
		bg.size = Vector2(bar_w, 30)
		bar.add_child(bg)
		var fill := Panel.new()
		var fill_box := UI.box(pcol, 8)
		fill_box.border_color = pcol.darkened(0.4)
		fill_box.border_width_bottom = 5
		fill.add_theme_stylebox_override("panel", fill_box)
		fill.size = Vector2(maxf(bar_w * minf(float(prev_val) / max_val, 1.0), 16.0), 30)
		bar.add_child(fill)

		var tot_txt := ("%d WIN%s" % [val, "" if val == 1 else "S"]) if wins_mode else ("%d PTS" % val)
		var tot := UI.make_label(tot_txt, 22, Color.WHITE, 5)
		tot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(tot)
		v.add_child(row)

		var tw := fill.create_tween()
		tw.tween_interval(0.35 + float(i) * 0.15)
		tw.tween_property(fill, "size:x", maxf(bar_w * minf(float(val) / max_val, 1.0), 16.0), 0.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		i += 1

	var next_id: String = str(info.get("next", ""))
	var next_txt := "FINAL RESULTS NEXT!"
	if next_id != "":
		var next_info: Dictionary = GameManager.GAME_INFO.get(next_id, {})
		next_txt = "NEXT UP: %s" % str(next_info.get("title", ""))
	v.add_child(UI.make_label(next_txt, 20, Color("#c8c3ff"), 5, HORIZONTAL_ALIGNMENT_CENTER))

	root.modulate.a = 0.0
	var fade := root.create_tween()
	fade.tween_property(root, "modulate:a", 1.0, 0.25)


# ---------------------------------------------------------------- podium

func show_podium() -> void:
	_clear_game()
	_clear_overlay()
	lobby.visible = false
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(root)
	_full_rect(root)

	var bd: Control = Backdrop.new()
	bd.self_modulate = Color(1, 1, 1, 0.45)
	root.add_child(bd)
	_full_rect(bd)

	var ids: Array = GameManager.standings()
	var wins_mode := GameManager.uses_wins()
	var champs: Array = []
	for id in ids:
		if GameManager.rank_of(id, ids) == 0:
			champs.append(str(GameManager.players[id]["name"]))

	var center: Container = FitBox.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	_full_rect(center)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	center.add_child(v)

	var tie := champs.size() > 1
	var head := UI.make_label("IT'S A TIE!" if tie else "CHAMPION!", 72, Color("#FEE440"), 16, HORIZONTAL_ALIGNMENT_CENTER)
	head.label_settings.shadow_color = Color("#FF4D6D")
	head.label_settings.shadow_offset = Vector2(0, 8)
	v.add_child(head)
	var sub := ""
	if tie:
		sub = "%s SHARE THE CROWN!" % " & ".join(PackedStringArray(champs))
	elif champs.size() == 1:
		sub = "%s WINS THE PARTY!" % champs[0]
	v.add_child(UI.make_label(sub, 28, Color.WHITE, 8, HORIZONTAL_ALIGNMENT_CENTER))

	var stage := HBoxContainer.new()
	stage.alignment = BoxContainer.ALIGNMENT_CENTER
	stage.add_theme_constant_override("separation", 12)
	v.add_child(stage)
	for pos in [3, 1, 0, 2, 4]:
		if pos >= ids.size():
			continue
		var id = ids[pos]
		var info: Dictionary = GameManager.players[id]
		var rank: int = GameManager.rank_of(id, ids)
		var pcol: Color = info["color"]
		var colv := VBoxContainer.new()
		colv.alignment = BoxContainer.ALIGNMENT_END
		colv.custom_minimum_size = Vector2(170, 370)
		colv.add_theme_constant_override("separation", 2)
		stage.add_child(colv)
		if rank == 0:
			var crown := Control.new()
			crown.custom_minimum_size = Vector2(70, 46)
			crown.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			crown.draw.connect(_draw_crown_icon.bind(crown))
			colv.add_child(crown)
		colv.add_child(_ball_icon(pcol, 84.0 if rank == 0 else 64.0))
		colv.add_child(UI.make_label(str(info["name"]), 22, Color.WHITE, 6, HORIZONTAL_ALIGNMENT_CENTER))
		var val: int = GameManager.standing_value(id)
		var vtxt := ("%d WIN%s" % [val, "" if val == 1 else "S"]) if wins_mode else ("%d PTS" % val)
		colv.add_child(UI.make_label(vtxt, 18, pcol, 5, HORIZONTAL_ALIGNMENT_CENTER))
		var ped := Control.new()
		var h: float = PEDESTAL_HEIGHTS[clampi(rank, 0, 4)]
		ped.custom_minimum_size = Vector2(160, h + 24.0)
		ped.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		ped.set_meta("grow", 0.0)
		ped.draw.connect(_draw_pedestal.bind(ped, h, pcol, rank))
		colv.add_child(ped)
		var tw := ped.create_tween()
		tw.tween_interval(0.2 + float(4 - rank) * 0.22)
		tw.tween_method(_set_grow.bind(ped), 0.0, 1.0, 0.7).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 20)
	v.add_child(btns)
	var can_control: bool = (not GameManager.is_online) or GameManager.is_host()
	if can_control:
		var again := UI.make_button("PLAY AGAIN", Color("#2ECC71"), 24)
		again.custom_minimum_size = Vector2(240, 60)
		again.pressed.connect(_on_play_again)
		btns.add_child(again)
		var back := UI.make_button("BACK TO LOBBY", Color("#3a86ff"), 24)
		back.custom_minimum_size = Vector2(240, 60)
		back.pressed.connect(_on_back_to_lobby)
		btns.add_child(back)
	else:
		btns.add_child(UI.make_label("Waiting for the host...", 20, Color("#c8c3ff"), 5))
		var leave := UI.make_button("LEAVE", Color("#e63946"), 22)
		leave.pressed.connect(_on_back_to_lobby)
		btns.add_child(leave)

	_spawn_confetti(root)


func _set_grow(v: float, ped: Control) -> void:
	ped.set_meta("grow", v)
	ped.queue_redraw()


func _draw_pedestal(c: Control, h: float, col: Color, rank: int) -> void:
	var g: float = float(c.get_meta("grow", 0.0))
	var hh: float = maxf(h * g, 0.0)
	var w: float = c.size.x
	var bottom: float = c.size.y
	var top_y: float = bottom - hh
	var depth := 18.0
	c.draw_rect(Rect2(10, bottom - 8, w - 4, 12), Color(0, 0, 0, 0.3))
	c.draw_rect(Rect2(0, top_y, w, hh), col.darkened(0.35))
	c.draw_rect(Rect2(0, top_y, w, 4), col.darkened(0.15))
	var top := PackedVector2Array([Vector2(0, top_y), Vector2(w, top_y), Vector2(w - 14.0, top_y - depth), Vector2(14.0, top_y - depth)])
	c.draw_colored_polygon(top, col.lightened(0.15))
	if hh > 30.0:
		var font: Font = UI.title_font()
		var label_y: float = top_y + minf(hh, 90.0) * 0.5 + 18.0
		c.draw_string_outline(font, Vector2(0, label_y), str(rank + 1), HORIZONTAL_ALIGNMENT_CENTER, w, 48, 8, Color(0, 0, 0, 0.5))
		c.draw_string(font, Vector2(0, label_y), str(rank + 1), HORIZONTAL_ALIGNMENT_CENTER, w, 48, Color.WHITE)


func _draw_crown_icon(c: Control) -> void:
	UI.draw_crown(c, c.size * 0.5, minf(c.size.x, c.size.y * 1.5) * 0.9)


func _spawn_confetti(parent: Control) -> void:
	var p := CPUParticles2D.new()
	var vp := get_viewport().get_visible_rect().size
	p.position = Vector2(vp.x * 0.5, -20)
	p.amount = 140
	p.lifetime = 4.5
	p.preprocess = 1.0
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(vp.x * 0.55, 10)
	p.direction = Vector2.DOWN
	p.spread = 30.0
	p.gravity = Vector2(0, 120)
	p.initial_velocity_min = 40.0
	p.initial_velocity_max = 120.0
	p.angular_velocity_min = -300.0
	p.angular_velocity_max = 300.0
	p.scale_amount_min = 6.0
	p.scale_amount_max = 11.0
	var g := Gradient.new()
	g.set_color(0, GameManager.COLORS[0])
	g.set_color(1, GameManager.COLORS[3])
	g.add_point(0.33, GameManager.COLORS[1])
	g.add_point(0.66, GameManager.COLORS[2])
	p.color_initial_ramp = g
	parent.add_child(p)


func _on_play_again() -> void:
	GameManager.start_party_match(GameManager.fill_with_bots if GameManager.is_online else true)


func _on_back_to_lobby() -> void:
	GameManager.return_to_lobby()
