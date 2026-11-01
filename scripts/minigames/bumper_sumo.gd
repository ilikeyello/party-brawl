extends "res://scripts/minigames/minigame_base.gd"
## BUMPER SUMO (turn based)
## Every turn:  AIM (pick direction + power, press LOCK IN)  ->  REVEAL (all aims shown)
##           ->  MOVE (everyone launches at once, physics bumps)  ->  SHRINK (ring gets smaller)
## Aims are secret until the reveal. Aim at a rival to knock them off - but if they move away,
## you may slide right off the edge yourself. Last player standing wins.

const CENTER := Vector2(640, 360)
const START_RADIUS := 270.0
const MIN_RADIUS := 95.0
const SHRINK_PER_TURN := 22.0
const MAX_TURNS := 14
const PLATFORM_DEPTH := 30.0
const FALL_MARGIN := 12.0

const AIM_TIME_FIRST := 10.0
const AIM_TIME := 7.0
const REVEAL_TIME := 0.9
const MOVE_MAX_TIME := 5.0
const SHRINK_TIME := 1.1

const MAX_LAUNCH := 640.0      # px/s at full power
const MIN_POWER := 0.25
const DECEL := 340.0           # px/s^2 sliding friction (low = icy, long slides)
const BUMP_BONUS := 1.15       # hits transfer a little extra energy (more fun)
const PHASES := ["aim", "reveal", "move", "shrink"]
const BRACE_LEN := 0.12
const KEY_TURN_SPEED := 2.4     # rad/s for A/D aiming
const KEY_POWER_SPEED := 0.9    # power/s for W/S
const SLING_FULL := 170.0       # must match mobile_hud.gd: pull this far = full power

var arena_radius: float = START_RADIUS
var next_radius: float = START_RADIUS - SHRINK_PER_TURN
var phase: String = "aim"
var phase_left: float = AIM_TIME_FIRST
var phase_time: float = 0.0
var turn: int = 1
var aims: Dictionary = {}          # id -> {"dir": Vector2, "power": float, "locked": bool}
var bot_plans: Dictionary = {}     # id -> {"dir", "power", "lock_at"}
var _shrink_from: float = START_RADIUS
var _turns_done: bool = false

# Client-side view
var revealed: Dictionary = {}      # id -> [dir, power]   (only filled after REVEAL)
var locked_ids: Array = []
var _local_aim_dir: Vector2 = Vector2.ZERO
var _local_aim_power: float = 0.0
var _aim_touched := false
var _bg_acc := 0.0
var _plat_acc := 0.0
var _drawn_radius := -1.0
var _aim_drawn := false
var _mouse_active := false
var _last_mouse := Vector2.INF
var _seen_phase: String = ""
var _seen_turn: int = 0

var bg: Node2D
var platform: Node2D
var aim_layer: Node2D
var _t: float = 0.0


func _init() -> void:
	game_id = "bumper_sumo"
	game_title = "BUMPER SUMO"
	instruction = "AIM, LOCK IN, LAUNCH! LAST ONE ON WINS"
	duration = 999.0
	knock_strength = 550.0
	elim_style = "fall"
	camera_center = CENTER
	key_hint = "MOUSE: point the way to slide (further = harder)     CLICK / SPACE: lock in     A/D turn  W/S power"


func build_arena() -> void:
	bg = Node2D.new()
	bg.name = "LavaBackground"
	floor_layer.add_child(bg)
	bg.draw.connect(_draw_bg)

	var embers := CPUParticles2D.new()
	embers.name = "Embers"
	embers.position = CENTER
	embers.amount = 60
	embers.lifetime = 3.5
	embers.preprocess = 3.0
	embers.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	embers.emission_rect_extents = Vector2(820, 460)
	embers.direction = Vector2.UP
	embers.spread = 25.0
	embers.gravity = Vector2(0, -25)
	embers.initial_velocity_min = 10.0
	embers.initial_velocity_max = 40.0
	embers.scale_amount_min = 2.0
	embers.scale_amount_max = 5.0
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.75, 0.2, 0.9))
	g.set_color(1, Color(1.0, 0.25, 0.05, 0.0))
	embers.color_ramp = g
	floor_layer.add_child(embers)

	platform = Node2D.new()
	platform.name = "Platform"
	floor_layer.add_child(platform)
	platform.draw.connect(_draw_platform)

	aim_layer = Node2D.new()
	aim_layer.name = "AimArrows"
	aim_layer.z_index = 8
	add_child(aim_layer)
	aim_layer.draw.connect(_draw_aims)


func get_spawn_points() -> Array:
	# 4 players: the four diagonals. 5 players: evenly around the ring.
	var pts: Array = []
	var n: int = 5 if players_expected() >= 5 else 4
	for i in n:
		var a: float = (-PI * 0.75 + float(i) * PI * 0.5) if n == 4 else (-PI * 0.5 + float(i) * TAU / 5.0)
		pts.append(CENTER + Vector2.from_angle(a) * 150.0)
	return pts


func on_game_start() -> void:
	_begin_aim(AIM_TIME_FIRST)


# ---------------------------------------------------------------- host: turn flow

func simulate_players(delta: float) -> void:
	phase_left = maxf(phase_left - delta, 0.0)
	phase_time += delta
	match phase:
		"aim":
			_aim_step()
			if phase_left <= 0.0 or _all_locked():
				_begin_reveal()
		"reveal":
			if phase_left <= 0.0:
				_begin_move()
		"move":
			_move_step(delta)
			if (phase_time > 0.4 and _all_still()) or phase_left <= 0.0:
				_end_move()
		"shrink":
			var k: float = clampf(phase_time / SHRINK_TIME, 0.0, 1.0)
			arena_radius = lerpf(_shrink_from, next_radius, k)
			_keep_inside(delta)
			if phase_left <= 0.0:
				arena_radius = next_radius
				turn += 1
				next_radius = maxf(arena_radius - SHRINK_PER_TURN, MIN_RADIUS)
				if turn > MAX_TURNS:
					_turns_done = true
				else:
					_begin_aim(AIM_TIME)


func _set_phase(p: String, t: float) -> void:
	phase = p
	phase_left = t
	phase_time = 0.0


func _begin_aim(t: float) -> void:
	_set_phase("aim", t)
	aims.clear()
	bot_plans.clear()
	for p in alive_players():
		var id: int = int(p.peer_id)
		var to_c: Vector2 = CENTER - p.position
		var d0: Vector2 = to_c.normalized() if to_c.length() > 1.0 else Vector2.UP
		aims[id] = {"dir": d0, "power": 0.0, "locked": false}
		p.move_vel = Vector2.ZERO
		p.knockback_vel = Vector2.ZERO
		p.is_dashing = false
		if _is_bot(p):
			bot_plans[id] = _plan_bot_move(p, t)


func _aim_step() -> void:
	for p in alive_players():
		var id: int = int(p.peer_id)
		var a: Dictionary = aims.get(id, {})
		if a.is_empty() or bool(a["locked"]):
			continue
		if _is_bot(p):
			var plan: Dictionary = bot_plans.get(id, {})
			if not plan.is_empty() and phase_time >= float(plan["lock_at"]):
				a["dir"] = plan["dir"]
				a["power"] = plan["power"]
				a["locked"] = true
		else:
			var inp: Dictionary = GameManager.get_input(id)
			var mv: Vector2 = inp.get("move", Vector2.ZERO)
			# Encoding: zero = no change, very short = "brace" (stay put), else direction * power.
			if mv.length() > 0.001:
				a["dir"] = mv.normalized()
				a["power"] = 0.0 if mv.length() < BRACE_LEN else clampf(mv.length(), MIN_POWER, 1.0)
			if bool(inp.get("act", false)):
				a["locked"] = true


func _all_locked() -> bool:
	for id in aims:
		if not bool(aims[id]["locked"]):
			return false
	return aims.size() > 0


func _begin_reveal() -> void:
	_set_phase("reveal", REVEAL_TIME)
	for id in aims:
		var p = players.get(id)
		if p != null:
			var d: Vector2 = aims[id]["dir"]
			p.facing = d


func _begin_move() -> void:
	_set_phase("move", MOVE_MAX_TIME)
	for id in aims:
		var p = players.get(id)
		if p == null or p.is_eliminated:
			continue
		var d: Vector2 = aims[id]["dir"]
		var pw: float = float(aims[id]["power"])
		p.move_vel = d * pw * MAX_LAUNCH
		p.is_dashing = pw > 0.0


func _move_step(delta: float) -> void:
	var steps := 3
	var dt: float = delta / float(steps)
	for _s in steps:
		var alive := alive_players()
		for p in alive:
			p.position += p.move_vel * dt
			p.move_vel = p.move_vel.move_toward(Vector2.ZERO, DECEL * dt)
		for i in alive.size():
			for j in range(i + 1, alive.size()):
				_collide(alive[i], alive[j])
	for p in alive_players():
		var spd: float = p.move_vel.length()
		p.is_dashing = spd > 230.0
		if spd > 20.0:
			p.facing = p.move_vel.normalized()
		if p.position.distance_to(CENTER) > arena_radius + FALL_MARGIN:
			eliminate_player(p, "fall")


func _collide(a, b) -> void:
	var diff: Vector2 = b.position - a.position
	var dist: float = diff.length()
	var min_d: float = PLAYER_RADIUS * 2.0
	if dist >= min_d:
		return
	var n: Vector2 = diff / dist if dist > 0.001 else Vector2.RIGHT
	var overlap: float = min_d - dist
	a.position -= n * overlap * 0.5
	b.position += n * overlap * 0.5
	var rel: float = (a.move_vel - b.move_vel).dot(n)
	if rel <= 0.0:
		return
	# Equal masses, elastic: the hitter hands its speed to the one it hits (+ a little bonus).
	var j: float = rel * BUMP_BONUS
	a.move_vel -= n * j
	b.move_vel += n * j
	if rel > 150.0:
		_hit_count += 1
		_last_hit_pos = (a.position + b.position) * 0.5 + Vector2(0, -12)


func _all_still() -> bool:
	for p in alive_players():
		if p.move_vel.length() > 8.0:
			return false
	return true


func _end_move() -> void:
	for p in alive_players():
		p.move_vel = Vector2.ZERO
		p.is_dashing = false
	if alive_count() <= 1:
		return
	_shrink_from = arena_radius
	_set_phase("shrink", SHRINK_TIME)


## While the ring shrinks, anyone caught on the edge gets slid inward (no unfair falls).
func _keep_inside(delta: float) -> void:
	var limit: float = arena_radius - PLAYER_RADIUS * 0.6
	for p in alive_players():
		var off: Vector2 = p.position - CENTER
		if off.length() > limit:
			p.position = p.position.lerp(CENTER + off.normalized() * limit, clampf(delta * 10.0, 0.0, 1.0))
	var alive := alive_players()
	for i in alive.size():
		for j in range(i + 1, alive.size()):
			var a = alive[i]
			var b = alive[j]
			var diff: Vector2 = b.position - a.position
			var dist: float = diff.length()
			if dist < PLAYER_RADIUS * 2.0:
				var n: Vector2 = diff / dist if dist > 0.001 else Vector2.RIGHT
				var o: float = PLAYER_RADIUS * 2.0 - dist
				a.position -= n * o * 0.5
				b.position += n * o * 0.5


func should_end() -> bool:
	return alive_count() <= 1 or _turns_done


func _is_bot(p) -> bool:
	if GameManager.players.has(p.peer_id):
		return bool(GameManager.players[p.peer_id]["is_bot"])
	return bool(p.is_bot)


static func power_for_travel(travel: float) -> float:
	return clampf(sqrt(2.0 * DECEL * maxf(travel, 0.0)) / MAX_LAUNCH, MIN_POWER, 1.0)


static func travel_for_power(power: float) -> float:
	var v: float = power * MAX_LAUNCH
	return v * v / (2.0 * DECEL)


# ---------------------------------------------------------------- bot AI

func _plan_bot_move(p, aim_time: float) -> Dictionary:
	var pos: Vector2 = p.position
	var r: float = arena_radius
	var dist_c: float = pos.distance_to(CENTER)
	var to_center: Vector2 = (CENTER - pos).normalized() if dist_c > 1.0 else Vector2.UP
	var others: Array = []
	for o in alive_players():
		if o != p:
			others.append(o)
	var target = nearest_alive_other(p)
	if randf() < 0.3 and others.size() > 1:
		target = others[randi() % others.size()]

	var roll := randf()
	var dir := to_center
	var travel := 0.0
	var near_edge: bool = dist_c > r * 0.6
	if target != null and ((not near_edge and roll < 0.6) or (near_edge and roll < 0.3)):
		# ATTACK: aim at the rival, push a bit past them.
		var tp: Vector2 = target.position
		dir = (tp - pos).normalized()
		travel = pos.distance_to(tp) - PLAYER_RADIUS + randf_range(60.0, 150.0)
		var end: Vector2 = pos + dir * travel
		if end.distance_to(CENTER) > r - 10.0 and randf() < 0.65:
			# Play it a bit safer: shorten so a miss doesn't end off the edge.
			for _k in 6:
				travel *= 0.8
				if (pos + dir * travel).distance_to(CENTER) < r - 30.0:
					break
	elif near_edge and roll < 0.85:
		# RETREAT toward the middle.
		dir = to_center.rotated(randf_range(-0.35, 0.35))
		travel = dist_c * randf_range(0.45, 0.95)
	elif roll < 0.9:
		# DODGE sideways from the closest threat.
		var threat_dir: Vector2 = to_center
		if target != null:
			threat_dir = (pos - target.position).normalized()
		var side := Vector2(-threat_dir.y, threat_dir.x) * (1.0 if randf() < 0.5 else -1.0)
		dir = (side + to_center * 0.6).normalized()
		travel = randf_range(60.0, 140.0)
		if (pos + dir * travel).distance_to(CENTER) > r - 30.0:
			dir = to_center
	else:
		# BRACE: stay put this turn.
		travel = 0.0
	dir = dir.rotated(randf_range(-0.1, 0.1))
	var power: float = 0.0 if travel <= 1.0 else power_for_travel(travel)
	return {"dir": dir, "power": power, "lock_at": randf_range(1.0, maxf(aim_time * 0.65, 1.5))}


# ---------------------------------------------------------------- network + HUD

func get_extra_state() -> Dictionary:
	var lk: Array = []
	for id in aims:
		if bool(aims[id]["locked"]):
			lk.append(id)
	var m := {
		"ph": PHASES.find(phase), "pl": phase_left, "tu": turn,
		"r": arena_radius, "nr": next_radius, "lk": lk,
	}
	if phase != "aim":
		var shown := {}
		for id in aims:
			shown[id] = [aims[id]["dir"], aims[id]["power"]]
		m["aims"] = shown
	return m


func apply_extra_state(m: Dictionary) -> void:
	phase = PHASES[clampi(int(m.get("ph", 0)), 0, PHASES.size() - 1)]
	phase_left = float(m.get("pl", phase_left))
	turn = int(m.get("tu", turn))
	arena_radius = float(m.get("r", arena_radius))
	next_radius = float(m.get("nr", next_radius))
	locked_ids = m.get("lk", [])
	if m.has("aims"):
		revealed = m["aims"]
	elif phase == "aim":
		revealed = {}


func _shown_power() -> float:
	return 0.0 if _local_aim_power < BRACE_LEN else maxf(_local_aim_power, MIN_POWER)


## Aiming controls. Touch: joystick. PC: mouse points at the landing spot, or A/D + W/S keys.
func local_input(delta: float) -> Dictionary:
	var act: bool = hud.consume_action()
	var me = players.get(GameManager.my_id())
	if me == null or me.is_eliminated or state != "running" or phase != "aim" or _my_locked():
		return {"move": Vector2.ZERO, "act": act}
	if _local_aim_dir == Vector2.ZERO:
		var to_c: Vector2 = CENTER - me.position
		_local_aim_dir = to_c.normalized() if to_c.length() > 1.0 else Vector2.UP
	if GameManager.touch_mode:
		hud.free_aim = true
		if hud.free_active:
			# Drag anywhere like a joystick: the arrow points the way you drag and grows
			# with the drag. Hold it and tap LOCK IN with your other thumb.
			var drag: Vector2 = hud.free_pos - hud.free_start
			var dlen: float = drag.length()
			if dlen > 14.0:
				_local_aim_dir = drag / dlen
				# Drag length maps straight to slide distance (so the arrow grows evenly).
				var k: float = clampf((dlen - 24.0) / (SLING_FULL - 24.0), 0.0, 1.0)
				_local_aim_power = 0.0 if dlen < 24.0 else power_for_travel(maxf(k, 0.04) * travel_for_power(1.0))
				_aim_touched = true
		elif _local_aim_power > 0.0:
			# Let go = the arrow resets (you'll stay put unless you aim again).
			_local_aim_power = 0.0
			_aim_touched = true
	else:
		var mpos: Vector2 = get_global_mouse_position()
		if _last_mouse != Vector2.INF and mpos.distance_to(_last_mouse) > 1.0:
			_mouse_active = true
		_last_mouse = mpos
		var turn_in := 0.0
		var pow_in := 0.0
		if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
			turn_in -= 1.0
		if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
			turn_in += 1.0
		if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
			pow_in += 1.0
		if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
			pow_in -= 1.0
		if turn_in != 0.0 or pow_in != 0.0:
			_mouse_active = false
			_local_aim_dir = _local_aim_dir.rotated(turn_in * KEY_TURN_SPEED * delta)
			_local_aim_power = clampf(_local_aim_power + pow_in * KEY_POWER_SPEED * delta, 0.0, 1.0)
			_aim_touched = true
		elif _mouse_active:
			var off: Vector2 = mpos - me.position
			var dist: float = off.length()
			if dist > 6.0:
				_local_aim_dir = off.normalized()
			# Point at where you want to stop: distance -> power.
			_local_aim_power = 0.0 if dist < 34.0 else power_for_travel(dist)
			_aim_touched = true
	if not _aim_touched:
		return {"move": Vector2.ZERO, "act": act}
	var p := _shown_power()
	var enc: Vector2 = _local_aim_dir * (p if p > 0.0 else BRACE_LEN * 0.5)
	return {"move": enc, "act": act}


func display_time() -> float:
	if state == "intro":
		return AIM_TIME_FIRST
	return phase_left if phase == "aim" else 0.0


func _my_locked() -> bool:
	var me := GameManager.my_id()
	if GameManager.is_host():
		return aims.has(me) and bool(aims[me]["locked"])
	return locked_ids.has(me)


func cooldown_ratio_for(p) -> float:
	if state != "running" or phase != "aim" or p.is_eliminated or _my_locked():
		return 1.0
	return 0.0


func stat_text(id: int) -> String:
	if players[id].is_eliminated:
		return "OUT"
	if state == "running" and phase == "aim":
		var lk: bool = (aims.has(id) and bool(aims[id]["locked"])) if GameManager.is_host() else locked_ids.has(id)
		return "LOCKED" if lk else "aiming"
	return "IN"


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if w.size() == 1:
		return "%s WINS!" % str(w[0])
	if w.size() > 1:
		return "TIE! " + " & ".join(PackedStringArray(w))
	return "TIME!"


func survivor_score(id: int) -> float:
	return -float(players[id].position.distance_to(CENTER))


func client_process(delta: float) -> void:
	_t += delta
	hud.pc_key = "CLICK"
	if GameManager.is_host():
		locked_ids = []
		for id in aims:
			if bool(aims[id]["locked"]):
				locked_ids.append(id)
		if phase != "aim":
			revealed = {}
			for id in aims:
				revealed[id] = [aims[id]["dir"], aims[id]["power"]]
		else:
			revealed = {}
	# Local aim preview (what I'm pointing at right now)
	var me = players.get(GameManager.my_id())
	if me != null and not me.is_eliminated and phase == "aim" and state == "running":
		if not _my_locked():
			if _local_aim_dir == Vector2.ZERO:
				var to_c: Vector2 = CENTER - me.position
				_local_aim_dir = to_c.normalized() if to_c.length() > 1.0 else Vector2.UP
			me.facing = _local_aim_dir
	# Phase banners
	if state == "running" and (phase != _seen_phase or turn != _seen_turn):
		if phase == "aim":
			_local_aim_dir = Vector2.ZERO
			_local_aim_power = 0.0
			_aim_touched = false
			hud.show_center("TURN %d - AIM!" % turn, Color("#00F5D4"), 0.6)
			hud.setup(game_title, "TURN %d: AIM + PUSH FOR POWER, THEN LOCK IN" % turn)
		elif phase == "reveal":
			hud.show_center("LAUNCH!", Color("#FEE440"), 0.4)
			hud.setup(game_title, "TURN %d: WATCH OUT!" % turn)
		elif phase == "shrink":
			hud.setup(game_title, "THE ARENA SHRINKS...")
			add_shake(3.0)
		_seen_phase = phase
		_seen_turn = turn
	var can_lock: bool = state == "running" and phase == "aim" and me != null and not me.is_eliminated and not _my_locked()
	if can_lock:
		hud.set_action("LOCK IN", Color("#2ECC71"))
	elif _my_locked() and phase == "aim":
		hud.set_action("LOCKED", Color("#2ECC71"))
	else:
		hud.set_action("WAIT...", Color("#7a7a90"))
	if state == "running" and phase != "aim":
		hud.timer_label.text = "GO" if phase != "shrink" else "--"
	# The lava drifts slowly: redraw it ~10x/s. The platform ~30x/s (faster while shrinking).
	_bg_acc += delta
	if _bg_acc >= 0.1:
		_bg_acc = 0.0
		bg.queue_redraw()
	_plat_acc += delta
	if _plat_acc >= 1.0 / 30.0 or absf(arena_radius - _drawn_radius) > 0.5:
		_plat_acc = 0.0
		_drawn_radius = arena_radius
		platform.queue_redraw()
	if state == "running" and (phase == "aim" or phase == "reveal"):
		aim_layer.queue_redraw()
	elif _aim_drawn:
		aim_layer.queue_redraw()
	_aim_drawn = state == "running" and (phase == "aim" or phase == "reveal")


# ---------------------------------------------------------------- drawing (pseudo-3D)

func _draw_aims() -> void:
	if state != "running":
		return
	var me_id := GameManager.my_id()
	var font: Font = UI.title_font()
	if phase == "aim":
		for id in player_order:
			var p = players[id]
			if p.is_eliminated:
				continue
			var head: Vector2 = p.position + Vector2(0, -78)
			var lk: bool = locked_ids.has(id)
			if int(id) == me_id:
				var d: Vector2 = _local_aim_dir
				var pw: float = _shown_power()
				if _my_locked() and GameManager.is_host() and aims.has(id):
					d = aims[id]["dir"]
					pw = float(aims[id]["power"])
				_draw_arrow(p.position + Vector2(0, -12), d, pw, p.player_color, true)
			# Status bubble: check when locked, dots while thinking
			aim_layer.draw_circle(head + Vector2(0, 3), 15.0, Color(0, 0, 0, 0.35))
			aim_layer.draw_circle(head, 15.0, Color("#2ECC71") if lk else Color(1, 1, 1, 0.85))
			if lk:
				aim_layer.draw_polyline(PackedVector2Array([head + Vector2(-7, 0), head + Vector2(-2, 6), head + Vector2(8, -6)]), Color.WHITE, 4.0, true)
			else:
				for k in 3:
					var a: float = 0.4 + 0.6 * absf(sin(_t * 4.0 + float(k) * 0.8))
					aim_layer.draw_circle(head + Vector2(float(k - 1) * 8.0, 0), 3.0, Color(0.2, 0.2, 0.3, a))
	elif phase == "reveal":
		for id in revealed:
			var p = players.get(id)
			if p == null or p.is_eliminated:
				continue
			var d2: Array = revealed[id]
			_draw_arrow(p.position + Vector2(0, -12), d2[0], float(d2[1]), p.player_color, true)
	# Countdown number for the player's own aim
	if phase == "aim" and players.has(me_id) and not players[me_id].is_eliminated and not _my_locked():
		var mp: Vector2 = players[me_id].position + Vector2(0, 48)
		aim_layer.draw_string_outline(font, mp - Vector2(80, 0), "PRESS LOCK IN", HORIZONTAL_ALIGNMENT_CENTER, 160, 14, 5, Color(0, 0, 0, 0.7))
		aim_layer.draw_string(font, mp - Vector2(80, 0), "PRESS LOCK IN", HORIZONTAL_ALIGNMENT_CENTER, 160, 14, Color("#2ECC71"))


func _draw_arrow(from: Vector2, dir: Vector2, power: float, col: Color, _show_landing: bool) -> void:
	if power <= 0.01:
		# Bracing: a small shield ring
		aim_layer.draw_arc(from, 34.0, 0.0, TAU, 32, Color(1, 1, 1, 0.75), 3.0, true)
		return
	var d := dir.normalized()
	# No landing marker on purpose: you only see direction + how big the arrow is.
	var frac: float = clampf(travel_for_power(power) / travel_for_power(1.0), 0.0, 1.0)
	var alen: float = 44.0 + frac * 150.0
	var tip: Vector2 = from + d * alen
	var side := Vector2(-d.y, d.x)
	var w: float = 6.0 + frac * 6.0
	aim_layer.draw_line(from + d * 26.0, tip - d * 10.0, Color(0, 0, 0, 0.4), w + 4.0)
	aim_layer.draw_line(from + d * 26.0, tip - d * 10.0, col, w)
	var head := PackedVector2Array([tip + d * 6.0, tip - d * 14.0 + side * 13.0, tip - d * 14.0 - side * 13.0])
	aim_layer.draw_colored_polygon(head, col)
	aim_layer.draw_polyline(PackedVector2Array([head[0], head[1], head[2], head[0]]), Color.WHITE, 2.0, true)


func _draw_bg() -> void:
	bg.draw_rect(Rect2(-1400, -1000, 4080, 2720), Color("#14050a"))
	var pulse: float = 0.5 + 0.5 * sin(_t * 1.6)
	for i in 6:
		var rr: float = START_RADIUS + 330.0 - float(i) * 55.0
		var a: float = 0.06 + float(i) * 0.03 + pulse * 0.02
		bg.draw_colored_polygon(UI.ellipse_points(CENTER + Vector2(0, 24), rr, rr * 0.82, 56), Color(1.0, 0.28 + float(i) * 0.04, 0.04, a))
	for i in 16:
		var ang: float = float(i) * 0.83 + _t * 0.12 * (1.0 + float(i % 3))
		var dist: float = 360.0 + 60.0 * sin(_t * 0.7 + float(i))
		var bp: Vector2 = CENTER + Vector2(cos(ang) * dist * 1.25, sin(ang) * dist * 0.7)
		var br: float = 26.0 + 12.0 * sin(_t * 1.3 + float(i) * 2.0)
		bg.draw_colored_polygon(UI.ellipse_points(bp, br * 1.4, br * 0.8, 20), Color(1.0, 0.45, 0.08, 0.22))
		bg.draw_colored_polygon(UI.ellipse_points(bp, br * 0.6, br * 0.3, 14), Color(1.0, 0.8, 0.3, 0.25))


func _draw_platform() -> void:
	var r: float = arena_radius
	var fast_pulse: float = 0.5 + 0.5 * sin(_t * 8.0)
	platform.draw_colored_polygon(UI.ellipse_points(CENTER + Vector2(14, PLATFORM_DEPTH + 26), r + 8.0, (r + 8.0) * 0.9, 56), Color(0, 0, 0, 0.5))
	var steps := 6
	for k in steps:
		var f: float = 1.0 - float(k) / float(steps)
		platform.draw_circle(CENTER + Vector2(0, PLATFORM_DEPTH * f), r, Color("#1b1d33").lerp(Color("#2c3050"), 1.0 - f))
	platform.draw_arc(CENTER + Vector2(0, PLATFORM_DEPTH), r, 0.15, PI - 0.15, 48, Color(1.0, 0.45, 0.1, 0.55), 4.0, true)
	platform.draw_circle(CENTER, r, Color("#3b5378"))
	platform.draw_circle(CENTER + Vector2(-r * 0.04, -r * 0.05), r * 0.93, Color("#4a6690"))
	platform.draw_circle(CENTER + Vector2(-r * 0.12, -r * 0.14), r * 0.55, Color(1, 1, 1, 0.03))
	# Icy sheen: diagonal glints sliding across the surface
	for k in 3:
		var off: float = fmod(_t * 60.0 + float(k) * 140.0, r * 2.4) - r * 1.2
		var a := CENTER + Vector2(off - r * 0.3, -r * 0.6)
		var b := CENTER + Vector2(off + r * 0.3, r * 0.6)
		var mid := (a + b) * 0.5
		if mid.distance_to(CENTER) < r * 0.8:
			platform.draw_line(a.lerp(mid, 0.4), b.lerp(mid, 0.4), Color(0.85, 0.95, 1.0, 0.07), 26.0)
	platform.draw_arc(CENTER, r * 0.66, 0.0, TAU, 56, Color(1, 1, 1, 0.12), 3.0, true)
	platform.draw_arc(CENTER, r * 0.33, 0.0, TAU, 40, Color(1, 1, 1, 0.12), 3.0, true)
	platform.draw_circle(CENTER, 14.0, Color(1, 1, 1, 0.1))
	# Preview of where the ring will shrink to after this turn (dashed red)
	if phase == "aim" or phase == "reveal" or phase == "move":
		var nr: float = next_radius
		if nr < r - 2.0:
			var segs := 36
			for i in segs:
				if i % 2 == 0:
					var a0: float = float(i) * TAU / float(segs) + _t * 0.3
					platform.draw_arc(CENTER, nr, a0, a0 + TAU / float(segs), 4, Color(1.0, 0.3, 0.25, 0.55), 3.0, true)
	platform.draw_arc(CENTER, maxf(r - 9.0, 4.0), 0.0, TAU, 64, Color(1.0, 0.3, 0.25, 0.3 + 0.4 * fast_pulse), 6.0, true)
	platform.draw_arc(CENTER, r, PI, TAU, 48, Color(1, 1, 1, 0.45), 3.0, true)
	platform.draw_arc(CENTER, r, 0.0, PI, 48, Color(0, 0, 0, 0.35), 3.0, true)
