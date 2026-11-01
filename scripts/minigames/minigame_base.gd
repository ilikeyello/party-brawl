extends Node2D
## Shared logic for every minigame: spawning players, intro/run/finish states,
## host-side simulation, player bumping, network state sync, HUD, camera shake, effects.
## Subclasses override the "hooks" section below.

const PLAYER_SCENE := preload("res://scenes/player/party_player.tscn")
const HUD_SCENE := preload("res://scenes/ui/mobile_hud.tscn")
const UI := preload("res://scripts/ui_kit.gd")
const STATES := ["intro", "running", "done"]
const INTRO_TIME := 4.0
const END_DELAY := 1.8
const SYNC_INTERVAL := 1.0 / 30.0
const PLAYER_RADIUS := 24.0

# Set these in a subclass _init()
var game_id: String = ""
var game_title: String = ""
var instruction: String = ""
var duration: float = 25.0
var knock_strength: float = 350.0
var elim_style: String = "fall"
var camera_center: Vector2 = Vector2(640, 360)
var camera_zoom: float = 1.0
var key_hint: String = "WASD / ARROWS: move     SPACE / SHIFT / CLICK: dash"
var _auto_dir: Vector2 = Vector2.RIGHT
var _auto_t: float = 0.0

var state: String = "intro"
var intro_left: float = INTRO_TIME
var time_left: float = 25.0
var elapsed: float = 0.0
var players: Dictionary = {}          # id -> party_player node
var player_order: Array = []          # ids sorted by slot
var elimination_order: Array = []
var hud = null
var floor_layer: Node2D
var world: Node2D                     # y-sorted: players + tall props
var fx_layer: Node2D
var camera: Camera2D

var _shake: float = 0.0
var _sync_acc: float = 0.0
var _ended: bool = false
var _finish_shown: bool = false
var _seen_elim: Dictionary = {}
var _hit_count: int = 0
var _seen_hits: int = 0
var _last_hit_pos: Vector2 = Vector2.ZERO
var _final_placements: Array = []
var _act_hold: float = 0.0
var _elim_frame: Dictionary = {}       # id -> physics frame they were eliminated on
var events: Array = []                 # [n, pos, text, color] floating texts (synced)
var _ev_n: int = 0
var _ev_seen: int = 0


func _ready() -> void:
	time_left = duration
	floor_layer = Node2D.new()
	floor_layer.name = "Floor"
	add_child(floor_layer)
	world = Node2D.new()
	world.name = "World"
	world.y_sort_enabled = true
	add_child(world)
	fx_layer = Node2D.new()
	fx_layer.name = "FX"
	fx_layer.z_index = 10
	add_child(fx_layer)
	camera = Camera2D.new()
	camera.position = camera_center
	_apply_camera_zoom()
	GameManager.ui_scale_changed.connect(_apply_camera_zoom)
	add_child(camera)
	camera.make_current()

	build_arena()
	_spawn_players()

	hud = HUD_SCENE.instantiate()
	add_child(hud)
	hud.setup(game_title, instruction)
	hud.key_hint = key_hint
	hud.set_time(duration)


func _spawn_players() -> void:
	var spawns: Array = get_spawn_points()
	var ids: Array = GameManager.players.keys()
	ids.sort_custom(func(a, b): return int(GameManager.players[a]["slot"]) < int(GameManager.players[b]["slot"]))
	for id in ids:
		var info: Dictionary = GameManager.players[id]
		var slot: int = int(info["slot"])
		var p = PLAYER_SCENE.instantiate()
		p.setup(int(id), info, elim_style)
		p.name = "Player%d" % (slot + 1)
		p.position = spawns[slot % spawns.size()]
		p.net_pos = p.position
		var to_center: Vector2 = camera_center - p.position
		if to_center.length() > 1.0:
			p.facing = to_center.normalized()
		world.add_child(p)
		p.dash_started.connect(_on_player_dash)
		players[int(id)] = p
		player_order.append(int(id))
		configure_player(p)


# ---------------------------------------------------------------- frame loop

func _physics_process(delta: float) -> void:
	_send_local_input()
	if GameManager.is_host():
		_server_tick(delta)


func _send_local_input() -> void:
	if hud == null:
		return
	var me := GameManager.my_id()
	if not players.has(me):
		return
	var li: Dictionary = local_input(get_physics_process_delta_time())
	if GameManager.autotest and not GameManager.is_host():
		li = _autotest_input(get_physics_process_delta_time())
	var mv: Vector2 = li.get("move", Vector2.ZERO)
	# Keep a tap "held" for a few frames so it survives a dropped network packet.
	if bool(li.get("act", false)):
		_act_hold = 0.1
	_act_hold = maxf(_act_hold - get_physics_process_delta_time(), 0.0)
	GameManager.send_local_input(mv, _act_hold > 0.0)


func _server_tick(delta: float) -> void:
	if state == "intro":
		intro_left -= delta
		if intro_left <= 0.0:
			intro_left = 0.0
			state = "running"
			on_game_start()
	elif state == "running":
		time_left = maxf(time_left - delta, 0.0)
		elapsed += delta
		simulate_players(delta)
		game_step(delta)
		if not _ended and should_end():
			_finish()

	_sync_acc += delta
	if _sync_acc >= SYNC_INTERVAL:
		_sync_acc = 0.0
		GameManager.send_state(_build_state())


## Default real-time simulation: read input / bot brains, move everyone, bump.
func simulate_players(delta: float) -> void:
	for id in player_order:
		var p = players[id]
		if p.is_eliminated:
			continue
		if GameManager.players.has(id):
			p.is_bot = bool(GameManager.players[id]["is_bot"])
		if p.is_bot:
			p.bot_think(delta, self)
		else:
			var inp: Dictionary = GameManager.get_input(int(id))
			p.move_input = filter_human_input(p, inp.get("move", Vector2.ZERO))
			p.action_input = bool(inp.get("act", false))
		p.server_step(delta)
	_resolve_collisions()


func _process(delta: float) -> void:
	_update_camera(delta)
	if hud == null:
		return
	hud.set_time(display_time())
	hud.set_badges(_badge_entries())
	var me = players.get(GameManager.my_id())
	if me != null:
		hud.set_cooldown(cooldown_ratio_for(me))
	_check_events()
	client_process(delta)


func _check_events() -> void:
	for id in player_order:
		var p = players[id]
		if p.is_eliminated and not _seen_elim.has(id):
			_seen_elim[id] = true
			if elim_style == "explode":
				add_shake(14.0)
				hud.flash(Color(1.0, 0.65, 0.25, 0.5))
				spawn_ring(p.position + Vector2(0, -12), Color(1.0, 0.6, 0.2), 170.0, 0.45)
			else:
				add_shake(6.0)
			if int(id) == GameManager.my_id() and state == "running":
				hud.show_center("YOU'RE OUT!", Color("#FF4D6D"), 1.2)
	if _hit_count != _seen_hits:
		_seen_hits = _hit_count
		add_shake(7.0)
		spawn_burst(_last_hit_pos, Color("#FFF3B0"), 14, 300.0, 7.0, 0.35)
		spawn_ring(_last_hit_pos, Color(1, 1, 1), 60.0, 0.25)
	for ev in events:
		var n: int = int(ev[0])
		if n > _ev_seen:
			_ev_seen = n
			_float_text(ev[1], str(ev[2]), ev[3])
			spawn_burst(ev[1] + Vector2(0, 30), ev[3], 18, 240.0, 7.0, 0.45)
			if str(ev[2]) == "FREEZE!":
				hud.flash(Color(0.6, 0.9, 1.0, 0.35))
	if state == "done" and not _finish_shown:
		_finish_shown = true
		hud.show_center(finish_text(), Color("#FEE440"), 1.4)


# ---------------------------------------------------------------- collisions / bumping

func _resolve_collisions() -> void:
	var list: Array = []
	for id in player_order:
		var p = players[id]
		if not p.is_eliminated:
			list.append(p)
	for i in list.size():
		for j in range(i + 1, list.size()):
			var a = list[i]
			var b = list[j]
			var diff: Vector2 = b.position - a.position
			var dist: float = diff.length()
			var min_d: float = PLAYER_RADIUS * 2.0
			if dist >= min_d:
				continue
			var n: Vector2 = diff / dist if dist > 0.001 else Vector2.RIGHT
			var overlap: float = min_d - dist
			a.move_and_collide(-n * overlap * 0.5)
			b.move_and_collide(n * overlap * 0.5)
			var a_dash: Vector2 = a.dash_dir
			var b_dash: Vector2 = b.dash_dir
			var a_hit: bool = a.is_dashing and a_dash.dot(n) > 0.1
			var b_hit: bool = b.is_dashing and b_dash.dot(-n) > 0.1
			if a_hit:
				_dash_hit(a, b, n)
			if b_hit:
				_dash_hit(b, a, -n)
			if not a_hit and not b_hit:
				var va: Vector2 = a.move_vel + a.knockback_vel
				var vb: Vector2 = b.move_vel + b.knockback_vel
				var closing: float = (va - vb).dot(n)
				if closing > 40.0:
					var soft: float = clampf(closing * 0.6, 60.0, 220.0)
					a.knockback_vel -= n * soft
					b.knockback_vel += n * soft
			on_players_touch(a, b)


func _dash_hit(attacker, victim, n: Vector2) -> void:
	if float(victim.hit_immunity) > 0.0:
		return
	var a_dir: Vector2 = attacker.dash_dir
	var dir: Vector2 = (n * 0.7 + a_dir * 0.3).normalized()
	victim.knockback_vel = dir * knock_strength
	victim.move_vel = Vector2.ZERO
	victim.hit_immunity = 0.3
	attacker.is_dashing = false
	attacker.move_vel = -n * 90.0
	_hit_count += 1
	_last_hit_pos = (attacker.position + victim.position) * 0.5 + Vector2(0, -12)
	on_dash_hit(attacker, victim)


func _on_player_dash(p) -> void:
	if GameManager.is_host() and state == "running":
		on_dash_started(p)


# ---------------------------------------------------------------- finishing

func eliminate_player(p, style: String = "") -> void:
	if p.is_eliminated:
		return
	p.set_eliminated(style if style != "" else elim_style)
	elimination_order.append(int(p.peer_id))
	_elim_frame[int(p.peer_id)] = Engine.get_physics_frames()


func alive_players() -> Array:
	var out: Array = []
	for id in player_order:
		if not players[id].is_eliminated:
			out.append(players[id])
	return out


func alive_count() -> int:
	return alive_players().size()


func nearest_alive_other(p):
	var best = null
	var best_d := INF
	for other in alive_players():
		if other == p:
			continue
		var d: float = p.position.distance_to(other.position)
		if d < best_d:
			best_d = d
			best = other
	return best


func _finish() -> void:
	_ended = true
	state = "done"
	on_game_end()
	for id in player_order:
		var p = players[id]
		p.move_input = Vector2.ZERO
		p.is_dashing = false
	_final_placements = compute_rank_groups()
	GameManager.send_state(_build_state())
	get_tree().create_timer(END_DELAY).timeout.connect(_report_results)


func _report_results() -> void:
	GameManager.report_minigame_results(_final_placements)


# ---------------------------------------------------------------- networking

func _build_state() -> Dictionary:
	var ps := {}
	for id in player_order:
		var p = players[id]
		ps[id] = [p.position, p.move_vel + p.knockback_vel, p.get_net_flags(), p.dash_cooldown]
	return {
		"st": STATES.find(state),
		"t": time_left,
		"i": intro_left,
		"h": _hit_count,
		"hp": _last_hit_pos,
		"p": ps,
		"m": get_extra_state(),
		"ev": events,
	}


func apply_state(s: Dictionary) -> void:
	if GameManager.is_host():
		return
	var st: int = int(s.get("st", 0))
	state = STATES[clampi(st, 0, STATES.size() - 1)]
	time_left = float(s.get("t", time_left))
	intro_left = float(s.get("i", intro_left))
	var ps: Dictionary = s.get("p", {})
	for id in ps:
		if players.has(id):
			var d: Array = ps[id]
			players[id].apply_net(d[0], d[1], int(d[2]), float(d[3]))
	var hits: int = int(s.get("h", _hit_count))
	if hits != _hit_count:
		_last_hit_pos = s.get("hp", _last_hit_pos)
		_hit_count = hits
	events = s.get("ev", events)
	apply_extra_state(s.get("m", {}))


# ---------------------------------------------------------------- HUD + FX

func _badge_entries() -> Array:
	var out: Array = []
	for id in player_order:
		if not GameManager.players.has(id):
			continue
		var info: Dictionary = GameManager.players[id]
		var p = players[id]
		var nm: String = str(info["name"])
		if nm.length() > 10:
			nm = nm.substr(0, 10)
		var tally := "%dW" % int(info.get("wins", 0)) if GameManager.uses_wins() else "%dpt" % int(info.get("score", 0))
		var txt := "%s  %s  %s" % [nm, tally, stat_text(int(id))]
		out.append({"id": id, "color": info["color"], "text": txt, "out": bool(p.is_eliminated)})
	return out


func _apply_camera_zoom() -> void:
	if camera != null:
		var z: float = camera_zoom / maxf(GameManager.ui_scale, 0.01)
		camera.zoom = Vector2(z, z)


func add_shake(amount: float) -> void:
	_shake = maxf(_shake, amount)


func _update_camera(delta: float) -> void:
	if camera == null:
		return
	if _shake > 0.0:
		_shake = maxf(_shake - delta * 40.0, 0.0)
		camera.offset = Vector2(randf_range(-_shake, _shake), randf_range(-_shake, _shake))
	else:
		camera.offset = Vector2.ZERO


func spawn_burst(pos: Vector2, col: Color, amount: int = 24, speed: float = 260.0, size: float = 8.0, life: float = 0.6) -> void:
	var p := CPUParticles2D.new()
	p.position = pos
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = maxi(amount, 1)
	p.lifetime = life
	p.spread = 180.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = speed * 0.35
	p.initial_velocity_max = speed
	p.damping_min = speed * 0.5
	p.damping_max = speed * 1.0
	p.scale_amount_min = size * 0.5
	p.scale_amount_max = size
	var g := Gradient.new()
	g.set_color(0, col)
	g.set_color(1, Color(col, 0.0))
	p.color_ramp = g
	fx_layer.add_child(p)
	p.emitting = true
	get_tree().create_timer(life + 0.6).timeout.connect(p.queue_free)


func spawn_ring(pos: Vector2, col: Color, max_r: float, dur: float) -> void:
	var n := Node2D.new()
	n.position = pos
	n.set_meta("v", 0.0)
	n.draw.connect(_draw_ring.bind(n, col, max_r))
	fx_layer.add_child(n)
	var tw := n.create_tween()
	tw.tween_method(_ring_step.bind(n), 0.0, 1.0, dur)
	tw.tween_callback(n.queue_free)


func _ring_step(v: float, n: Node2D) -> void:
	n.set_meta("v", v)
	n.queue_redraw()


func _draw_ring(n: Node2D, col: Color, max_r: float) -> void:
	var v: float = float(n.get_meta("v", 0.0))
	var r: float = maxf(max_r * v, 1.0)
	n.draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, Color(col, 1.0 - v), 8.0 * (1.0 - v) + 1.0, true)


func add_wall(rect: Rect2) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = rect.size
	cs.shape = shape
	body.position = rect.get_center()
	body.add_child(cs)
	add_child(body)
	return body


# ---------------------------------------------------------------- hooks (override in minigames)

func build_arena() -> void:
	pass


func configure_player(_p) -> void:
	pass


## How many players are in this match (spawn layouts can adapt).
func players_expected() -> int:
	return GameManager.players.size()


func get_spawn_points() -> Array:
	return [Vector2(500, 260), Vector2(780, 260), Vector2(780, 460), Vector2(500, 460)]


func on_game_start() -> void:
	pass


func game_step(_delta: float) -> void:
	pass


func should_end() -> bool:
	return time_left <= 0.0 or alive_count() <= 1


func on_game_end() -> void:
	pass


func finish_text() -> String:
	return "FINISH!"


func get_extra_state() -> Dictionary:
	return {}


func apply_extra_state(_m: Dictionary) -> void:
	pass


func get_bot_command(_p, _delta: float) -> Dictionary:
	return {"move": Vector2.ZERO, "act": false}


func on_dash_hit(_attacker, _victim) -> void:
	pass


func on_dash_started(_p) -> void:
	pass


func on_players_touch(_a, _b) -> void:
	pass


func stat_text(_id: int) -> String:
	return ""


func client_process(_delta: float) -> void:
	pass


## What this player is pressing right now. Override for custom controls (e.g. mouse aiming).
func local_input(_delta: float) -> Dictionary:
	return {"move": hud.get_move_vector(), "act": hud.consume_action()}


## Host side: tweak a human player's movement (e.g. maze cornering help). Default: unchanged.
func filter_human_input(_p, mv: Vector2) -> Vector2:
	return mv


## Online test client: wander around and press the button now and then.
func _autotest_input(delta: float) -> Dictionary:
	_auto_t -= delta
	if _auto_t <= 0.0:
		_auto_t = randf_range(0.6, 1.4)
		_auto_dir = Vector2.from_angle(randf() * TAU)
	return {"move": _auto_dir, "act": randf() < 0.02}


func display_time() -> float:
	return duration if state == "intro" else time_left


func cooldown_ratio_for(p) -> float:
	return float(p.dash_cooldown) / maxf(float(p.dash_cooldown_time), 0.01)


## Higher = better among players still alive at the end.
func survivor_score(_id: int) -> float:
	return 0.0


## Floating text event (host). Shows on every screen.
func push_event(pos: Vector2, text: String, col: Color) -> void:
	_ev_n += 1
	events.append([_ev_n, pos, text, col])
	while events.size() > 6:
		events.pop_front()


func _float_text(pos: Vector2, text: String, col: Color) -> void:
	var l := UI.make_label(text, 26, col, 7, HORIZONTAL_ALIGNMENT_CENTER)
	l.size = Vector2(260, 36)
	l.position = pos - Vector2(130, 18)
	l.z_index = 30
	fx_layer.add_child(l)
	var tw := l.create_tween().set_parallel(true)
	tw.tween_property(l, "position:y", l.position.y - 50.0, 0.9).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "modulate:a", 0.0, 0.9).set_delay(0.4)
	tw.chain().tween_callback(l.queue_free)


## Placement GROUPS, best first. Players in the same group are tied.
## Default: survivors (grouped by equal survivor_score), then eliminated players,
## latest first; players knocked out on the same frame tie.
func compute_rank_groups() -> Array:
	var groups: Array = []
	var alive: Array = []
	for id in player_order:
		if not players[id].is_eliminated:
			alive.append(id)
	alive.sort_custom(func(a, b): return survivor_score(int(a)) > survivor_score(int(b)))
	var last_score := INF
	for id in alive:
		var sc: float = snappedf(survivor_score(int(id)), 0.01)
		if groups.is_empty() or sc != last_score:
			groups.append([id])
		else:
			groups[groups.size() - 1].append(id)
		last_score = sc
	var elim: Array = elimination_order.duplicate()
	elim.reverse()
	var last_frame := -1
	var first_elim := true
	for id in elim:
		var fr: int = int(_elim_frame.get(id, -2))
		if first_elim or fr != last_frame:
			groups.append([id])
		else:
			groups[groups.size() - 1].append(id)
		first_elim = false
		last_frame = fr
	var placed: Array = []
	for g in groups:
		placed.append_array(g)
	for id in player_order:
		if not placed.has(id):
			groups.append([id])
	return groups


## Display names of everyone in first place (more than one = tie).
func winner_names(groups: Array) -> Array:
	var out: Array = []
	if groups.is_empty():
		return out
	for id in groups[0]:
		if players.has(id):
			out.append(str(players[id].display_name))
	return out
