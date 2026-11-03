extends "res://scripts/minigames/minigame_base.gd"
## BALLOON PUMP - three balloons each. HOLD to pump your balloon up, let go to stop.
## Bigger balloon = more points, but every balloon has a secret pop size: pump past it and
## it bursts for 0. A balloon wobbles when it's getting close (sometimes only just in time!).
## The biggest balloon each round gets a bonus. Most points after 3 balloons wins.

const BALLOONS := 3
const PUMP_TIME := 7.0
const SHOW_TIME := 2.6
const PUMP_RATE := 0.21          # size per second while holding (empty -> full in ~4.8 s)
const POP_MIN := 0.38
const POP_MAX := 1.02            # > 1.0 = this balloon can't pop (lucky!)
const WARN_MIN := 0.04           # wobble starts this much (random) before the pop size
const WARN_MAX := 0.2
const BONUS := 20
const SPACING := 228.0
const KNOT_Y := 500.0
const PLAYER_Y := 608.0
const MIN_R := 16.0
const MAX_R := 100.0

var phase := "pump"              # "pump" | "show"
var phase_left := PUMP_TIME
var balloon := 0
var size: Dictionary = {}        # id -> 0..1
var popped: Dictionary = {}      # id -> bool
var pumping: Dictionary = {}     # id -> bool
var danger: Dictionary = {}      # id -> bool (wobbling)
var totals: Dictionary = {}      # id -> points so far
var last_pts: Dictionary = {}    # id -> points from the balloon just scored (bonus included)
var bonus_ids: Array = []
var reveal: Dictionary = {}      # id -> pop size, only during "show"
var _pop_at: Dictionary = {}     # host only: the secret
var _warn_at: Dictionary = {}
var _done := false

var stage: Node2D
var drawer: Node2D
var _t := 0.0
var _seen_pop: Dictionary = {}
var _pump_snd := 0.0
var _last_key := ""


func _init() -> void:
	game_id = "balloon_pump"
	game_title = "BALLOON PUMP"
	instruction = "BIGGEST BALLOON WITHOUT POPPING!"
	duration = float(BALLOONS) * (PUMP_TIME + SHOW_TIME)
	elim_style = "fall"
	key_hint = "HOLD SPACE or MOUSE: pump     LET GO: stop"


func _ready() -> void:
	super()
	# Line everyone up in a row (by join order, so there are never gaps).
	for i in player_order.size():
		var id: int = player_order[i]
		var p = players[id]
		p.position = Vector2(_x_for(i) + 26.0, PLAYER_Y)
		p.net_pos = p.position
		p.facing = Vector2(-0.4, -1.0).normalized()
		size[id] = 0.0
		popped[id] = false
		pumping[id] = false
		danger[id] = false
		totals[id] = 0
		last_pts[id] = 0
	hud.hold_mode = true
	hud.hold_hint = "HOLD ANYWHERE TO PUMP"


func build_arena() -> void:
	stage = Node2D.new()
	stage.name = "Stage"
	floor_layer.add_child(stage)
	stage.draw.connect(_draw_stage)
	drawer = Node2D.new()
	drawer.name = "Balloons"
	fx_layer.add_child(drawer)
	drawer.z_index = -5
	drawer.draw.connect(_draw_balloons)


func _x_for(i: int) -> float:
	var n: int = maxi(player_order.size(), 1)
	return 640.0 + (float(i) - float(n - 1) * 0.5) * SPACING


func _radius(s: float) -> float:
	return lerpf(MIN_R, MAX_R, clampf(s, 0.0, 1.0))


# ---------------------------------------------------------------- host logic

func on_game_start() -> void:
	_new_balloon()


func _new_balloon() -> void:
	reveal = {}
	bonus_ids = []
	for id in player_order:
		size[id] = 0.0
		popped[id] = false
		pumping[id] = false
		danger[id] = false
		var pop: float = randf_range(POP_MIN, POP_MAX)
		_pop_at[id] = pop
		_warn_at[id] = maxf(pop - randf_range(WARN_MIN, WARN_MAX), 0.2)
		var p = players[id]
		p.bot_brain = {}


func simulate_players(delta: float) -> void:
	phase_left -= delta
	if phase == "pump":
		for id in player_order:
			var p = players[id]
			if GameManager.players.has(id):
				p.is_bot = bool(GameManager.players[id]["is_bot"])
			var hold := false
			if p.is_bot:
				hold = bool(get_bot_command(p, delta).get("act", false))
			else:
				hold = bool(GameManager.get_input(int(id)).get("act", false))
			if bool(popped[id]):
				hold = false
			pumping[id] = hold
			if hold:
				size[id] = minf(float(size[id]) + PUMP_RATE * delta, 1.0)
				if float(size[id]) >= float(_pop_at[id]):
					popped[id] = true
					pumping[id] = false
			danger[id] = not bool(popped[id]) and float(size[id]) >= float(_warn_at[id])
		if phase_left <= 0.0:
			_score_balloon()
			phase = "show"
			phase_left = SHOW_TIME
	else:
		if phase_left <= 0.0:
			if balloon + 1 >= BALLOONS:
				_done = true
				phase_left = 0.0
			else:
				balloon += 1
				_new_balloon()
				phase = "pump"
				phase_left = PUMP_TIME


func _score_balloon() -> void:
	var best := 0
	for id in player_order:
		var pts: int = 0 if bool(popped[id]) else roundi(float(size[id]) * 100.0)
		last_pts[id] = pts
		best = maxi(best, pts)
		pumping[id] = false
	bonus_ids = []
	if best > 0:
		for id in player_order:
			if int(last_pts[id]) == best:
				bonus_ids.append(id)
				last_pts[id] = int(last_pts[id]) + BONUS
	for id in player_order:
		totals[id] = int(totals[id]) + int(last_pts[id])
	reveal = _pop_at.duplicate()


func should_end() -> bool:
	return _done


func compute_rank_groups() -> Array:
	var ids: Array = player_order.duplicate()
	ids.sort_custom(func(a, b): return int(totals.get(a, 0)) > int(totals.get(b, 0)))
	var groups: Array = []
	var last := -1
	for id in ids:
		var n: int = int(totals.get(id, 0))
		if groups.is_empty() or n != last:
			groups.append([id])
		else:
			groups[groups.size() - 1].append(id)
		last = n
	return groups


func stat_text(id: int) -> String:
	return "%d pts" % int(totals.get(id, 0))


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if w.size() == 1:
		return "%s WINS!" % str(w[0])
	return "TIE! " + " & ".join(PackedStringArray(w))


func display_time() -> float:
	if state == "intro":
		return PUMP_TIME
	return phase_left if phase == "pump" else 0.0


func cooldown_ratio_for(p) -> float:
	if phase == "pump" and state == "running" and not bool(popped.get(int(p.peer_id), false)):
		return 0.0
	return 1.0


func local_input(_delta: float) -> Dictionary:
	var act: bool = hud.consume_action()
	if not GameManager.touch_mode and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		act = true
	return {"move": Vector2.ZERO, "act": act}


func get_extra_state() -> Dictionary:
	return {
		"ph": phase, "pl": phase_left, "b": balloon, "sz": size, "pp": popped, "pu": pumping,
		"dg": danger, "tot": totals, "lp": last_pts, "bo": bonus_ids, "rv": reveal,
	}


func apply_extra_state(m: Dictionary) -> void:
	phase = str(m.get("ph", phase))
	phase_left = float(m.get("pl", phase_left))
	balloon = int(m.get("b", balloon))
	size = m.get("sz", size)
	popped = m.get("pp", popped)
	pumping = m.get("pu", pumping)
	danger = m.get("dg", danger)
	totals = m.get("tot", totals)
	last_pts = m.get("lp", last_pts)
	bonus_ids = m.get("bo", bonus_ids)
	reveal = m.get("rv", reveal)


# ---------------------------------------------------------------- bot AI

func get_bot_command(p, delta: float) -> Dictionary:
	var id: int = int(p.peer_id)
	var b: Dictionary = p.bot_brain
	if not b.has("target"):
		var target: float = randf_range(0.32, 0.72)
		# Behind on points in the last round? Take a bigger risk.
		if balloon == BALLOONS - 1:
			var lead := 0
			for oid in player_order:
				lead = maxi(lead, int(totals.get(oid, 0)))
			if lead - int(totals.get(id, 0)) > 40:
				target += 0.18
		b["target"] = target
		b["delay"] = randf_range(0.2, 1.6)
		b["saw"] = false
	b["delay"] = float(b["delay"]) - delta
	if float(b["delay"]) > 0.0:
		return {"act": false}
	if bool(danger.get(id, false)) and not bool(b["saw"]):
		b["saw"] = true
		if randf() < 0.6:
			b["target"] = 0.0     # "it's wobbling - stop!"
	var hold: bool = float(size.get(id, 0.0)) < float(b["target"])
	return {"act": hold}


# ---------------------------------------------------------------- client side

func client_process(delta: float) -> void:
	_t += delta
	var key := "%s%d" % [phase, balloon]
	if state == "running" and key != _last_key:
		_last_key = key
		if phase == "pump":
			hud.show_center("BALLOON %d - PUMP!" % (balloon + 1), Color("#00F5D4"), 0.8)
			hud.setup(game_title, "BALLOON %d OF %d" % [balloon + 1, BALLOONS])
			_seen_pop.clear()
		else:
			hud.show_center("TIME!", Color("#FEE440"), 0.7)
			Sfx.play("ding")
			if not bonus_ids.is_empty():
				get_tree().create_timer(0.5).timeout.connect(func(): Sfx.play("powerup", -2.0))
	var me_id := GameManager.my_id()
	var mine_popped := bool(popped.get(me_id, false))
	if phase == "pump" and state == "running" and not mine_popped:
		hud.set_action("PUMP!", Color("#FF4D6D"))
	else:
		hud.set_action("WAIT", Color("#7a7a90"))
	# Pops
	for i in player_order.size():
		var id: int = player_order[i]
		if bool(popped.get(id, false)) and not _seen_pop.has(id):
			_seen_pop[id] = true
			var r := _radius(float(size.get(id, 0.0)))
			var c := Vector2(_x_for(i), KNOT_Y - r)
			Sfx.play("pop", 0.0 if id == me_id else -4.0, 0.1, 30)
			add_shake(5.0 + r * 0.05)
			spawn_burst(c, players[id].player_color, 26, 380.0, 10.0, 0.5)
			spawn_ring(c, Color.WHITE, r * 1.6, 0.3)
			if id == me_id:
				hud.show_center("POP!", Color("#FF4D6D"), 0.8)
	# Pumping sound (my own pump)
	_pump_snd -= delta
	if bool(pumping.get(me_id, false)) and _pump_snd <= 0.0:
		_pump_snd = 0.28
		Sfx.play("pump", -5.0, 0.06, 60)
	drawer.queue_redraw()


# ---------------------------------------------------------------- drawing

func _draw_stage() -> void:
	var s := stage
	s.draw_rect(Rect2(-1400, -1000, 4080, 2720), Color("#1b1036"))
	# Back wall with soft lights
	s.draw_rect(Rect2(-200, 60, 1680, 520), Color("#2a1650"))
	for k in 9:
		var cx: float = 80.0 + float(k) * 140.0
		s.draw_circle(Vector2(cx, 150), 60.0, Color(1, 0.8, 0.4, 0.05))
		s.draw_circle(Vector2(cx, 150), 8.0, Color("#FEE440"))
	# Striped tent top
	for k in 20:
		var x0: float = -200.0 + float(k) * 90.0
		var col := Color("#FF4D6D") if k % 2 == 0 else Color("#fdf0d5")
		s.draw_colored_polygon(PackedVector2Array([Vector2(x0, -200), Vector2(x0 + 90, -200), Vector2(x0 + 90, 70), Vector2(x0 + 45, 96), Vector2(x0, 70)]), col)
	# Stage floor
	s.draw_rect(Rect2(-200, 560, 1680, 400), Color("#7a4a26"))
	for k in 12:
		s.draw_line(Vector2(-200, 572 + float(k) * 30.0), Vector2(1480, 572 + float(k) * 30.0), Color(0, 0, 0, 0.18), 3.0)
	s.draw_rect(Rect2(-200, 556, 1680, 10), Color("#c98a4b"))


func _draw_balloons() -> void:
	var d := drawer
	var font: Font = UI.title_font()
	for i in player_order.size():
		var id: int = player_order[i]
		var p = players[id]
		var col: Color = p.player_color
		var x: float = _x_for(i)
		var sz: float = float(size.get(id, 0.0))
		var is_popped := bool(popped.get(id, false))
		var is_pumping := bool(pumping.get(id, false))
		var wob := bool(danger.get(id, false)) and phase == "pump"
		# Pump: box + plunger that goes down while pumping
		var pump_base := Vector2(x - 56.0, 600.0)
		var push: float = (0.5 + 0.5 * sin(_t * 22.0)) * 16.0 if is_pumping else 0.0
		d.draw_colored_polygon(UI.ellipse_points(pump_base + Vector2(0, 10), 30, 9, 16), Color(0, 0, 0, 0.35))
		d.draw_rect(Rect2(pump_base + Vector2(-20, -34), Vector2(40, 44)), Color("#3a86ff").darkened(0.2))
		d.draw_rect(Rect2(pump_base + Vector2(-20, -34), Vector2(40, 6)), Color("#8ecae6"))
		d.draw_line(pump_base + Vector2(0, -34), pump_base + Vector2(0, -60 + push), Color("#d9d9d9"), 5.0)
		d.draw_rect(Rect2(pump_base + Vector2(-18, -66 + push), Vector2(36, 8)), Color("#2b2d42"))
		# Hose up to the knot
		var knot := Vector2(x, KNOT_Y)
		var hose := PackedVector2Array()
		for k in 9:
			var f: float = float(k) / 8.0
			var a := pump_base + Vector2(18, -10)
			hose.append(a.lerp(knot + Vector2(0, 12), f) + Vector2(sin(f * PI) * 26.0, 0))
		d.draw_polyline(hose, Color("#2b2d42"), 5.0, true)
		# Where it would have popped (shown after each balloon)
		if phase == "show" and reveal.has(id) and float(reveal[id]) <= 1.0:
			var rr := _radius(float(reveal[id]))
			var rc := Vector2(x, KNOT_Y - rr)
			for k in 16:
				var a0: float = float(k) * TAU / 16.0
				d.draw_arc(rc, rr, a0, a0 + TAU / 32.0, 4, Color(1, 1, 1, 0.55), 3.0, true)
		if is_popped:
			# Rubber shreds
			for k in 5:
				var a: float = float(k) * 1.3 + float(i)
				var piece := knot + Vector2(cos(a) * 18.0, -10.0 - absf(sin(a)) * 14.0)
				d.draw_colored_polygon(PackedVector2Array([piece, piece + Vector2(10, 4), piece + Vector2(4, 12)]), col.darkened(0.15))
			d.draw_colored_polygon(PackedVector2Array([knot + Vector2(-7, 12), knot + Vector2(7, 12), knot]), col.darkened(0.3))
			_text(d, font, knot + Vector2(0, -40), "POP!", 30, Color("#FF4D6D"))
		else:
			var r := _radius(sz)
			var c := Vector2(x, KNOT_Y - r)
			var sq := Vector2(0.92, 1.0)
			if wob:
				c += Vector2(sin(_t * 41.0) * 3.0, cos(_t * 37.0) * 2.0)
				sq = Vector2(0.92 + sin(_t * 30.0) * 0.05, 1.0 - sin(_t * 30.0) * 0.04)
			elif is_pumping:
				sq = Vector2(0.92 + sin(_t * 22.0) * 0.015, 1.0)
			d.draw_colored_polygon(UI.ellipse_points(c, r * sq.x, r * sq.y, 40), col.darkened(0.25))
			d.draw_colored_polygon(UI.ellipse_points(c + Vector2(-r * 0.05, -r * 0.05), r * sq.x * 0.9, r * sq.y * 0.9, 40), col)
			d.draw_colored_polygon(UI.ellipse_points(c + Vector2(-r * 0.35, -r * 0.4), r * 0.16, r * 0.26, 16), Color(1, 1, 1, 0.55))
			d.draw_colored_polygon(PackedVector2Array([knot + Vector2(-7, 10), knot + Vector2(7, 10), knot + Vector2(0, -2)]), col.darkened(0.3))
			if wob:
				# Little stress marks
				for k in 3:
					var a: float = -PI * 0.8 + float(k) * 0.5
					var s0 := c + Vector2.from_angle(a) * (r + 6.0)
					d.draw_line(s0, s0 + Vector2.from_angle(a) * 10.0, Color.WHITE, 3.0)
			_text(d, font, c + Vector2(0, 10), str(roundi(sz * 100.0)), clampi(int(14.0 + r * 0.3), 14, 40), Color.WHITE)
		# Points for this balloon
		if phase == "show" and state != "intro":
			var pts: int = int(last_pts.get(id, 0))
			var top_y: float = KNOT_Y - _radius(1.0) * 2.0 - 30.0
			_text(d, font, Vector2(x, top_y), "+%d" % pts, 34, Color("#FEE440") if pts > 0 else Color("#9d97d8"))
			if bonus_ids.has(id):
				_text(d, font, Vector2(x, top_y + 30.0), "BIGGEST! +%d" % BONUS, 18, Color("#00F5D4"))


func _text(ci: CanvasItem, font: Font, center: Vector2, txt: String, fs: int, col: Color) -> void:
	var w := 220.0
	ci.draw_string_outline(font, center - Vector2(w * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_CENTER, w, fs, 7, Color(0, 0, 0, 0.8))
	ci.draw_string(font, center - Vector2(w * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_CENTER, w, fs, col)
