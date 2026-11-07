extends "res://scripts/minigames/minigame_base.gd"
## BALLOON PUMP - one balloon each, one timer. HOLD to pump your balloon bigger.
## Every so often a WARNING comes up: let go and it goes away after a moment, then keep pumping.
## Keep pumping through a warning and the balloon POPS - you start over with a new, empty one.
## Warnings come more often (and give you less time) as the balloon gets bigger.
## Biggest balloon when the timer runs out wins.

const GAME_TIME := 30.0
const PUMP_RATE := 6.5           # balloon size (points) per second while pumping
const MAX_SIZE := 120.0
const WARN_GAP_START := Vector2(9.0, 16.0)   # points of pumping between warnings (small balloon)
const WARN_GAP_END := Vector2(3.0, 7.0)      # ...and for a huge balloon
const GRACE_START := 0.6         # seconds you can keep pumping into a warning before it pops
const GRACE_END := 0.32
const REST_TIME := 0.7           # let go this long and the warning goes away
const NEW_BALLOON_TIME := 1.0    # after a pop, a new balloon arrives this much later
const SPACING := 228.0
const KNOT_Y := 500.0
const PLAYER_Y := 608.0
const MIN_R := 16.0
const MAX_R := 100.0

var size: Dictionary = {}        # id -> 0..MAX_SIZE
var warn: Dictionary = {}        # id -> warning showing
var calm: Dictionary = {}        # id -> 0..1 how far the warning has calmed down (for the look)
var pumping: Dictionary = {}     # id -> bool
var pop_t: Dictionary = {}       # id -> seconds until the new balloon (> 0 = just popped)
var pops: Dictionary = {}        # id -> how many times it popped
var _next_warn: Dictionary = {}  # host: size where the next warning comes
var _over: Dictionary = {}       # host: seconds pumped into the current warning
var _rest: Dictionary = {}       # host: seconds resting during the current warning

var stage: Node2D
var drawer: Node2D
var _t := 0.0
var _seen_pops: Dictionary = {}
var _seen_warn: Dictionary = {}
var _pump_snd := 0.0


func _init() -> void:
	game_id = "balloon_pump"
	game_title = "BALLOON PUMP"
	instruction = "STOP WHEN IT WARNS YOU! BIGGEST WINS"
	duration = GAME_TIME
	elim_style = "fall"
	key_hint = "HOLD SPACE or MOUSE: pump     LET GO when it warns you"


func _ready() -> void:
	super()
	# Playing field = the row of balloons (biggest size) + players and pumps underneath.
	var n: int = maxi(player_order.size(), 1)
	var half_w: float = float(n - 1) * SPACING * 0.5 + MAX_R + 20.0
	arena_rect = Rect2(640.0 - half_w, KNOT_Y - MAX_R * 2.0 - 50.0, half_w * 2.0, PLAYER_Y - (KNOT_Y - MAX_R * 2.0 - 50.0) + 50.0)
	_cam_key = []   # re-fit the camera with the real size
	# Line everyone up in a row (by join order, so there are never gaps).
	for i in player_order.size():
		var id: int = player_order[i]
		var p = players[id]
		p.position = Vector2(_x_for(i) + 26.0, PLAYER_Y)
		p.net_pos = p.position
		p.facing = Vector2(-0.4, -1.0).normalized()
		size[id] = 0.0
		warn[id] = false
		calm[id] = 0.0
		pumping[id] = false
		pop_t[id] = 0.0
		pops[id] = 0
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
	return lerpf(MIN_R, MAX_R, clampf(s / MAX_SIZE, 0.0, 1.0))


func _k(s: float) -> float:
	return clampf(s / MAX_SIZE, 0.0, 1.0)


# ---------------------------------------------------------------- host logic

func on_game_start() -> void:
	for id in player_order:
		_new_balloon(id)


func _new_balloon(id: int) -> void:
	size[id] = 0.0
	warn[id] = false
	calm[id] = 0.0
	_over[id] = 0.0
	_rest[id] = 0.0
	_next_warn[id] = _warn_gap(0.0)
	players[id].bot_brain = {}


## How much more pumping until the next warning (shorter as the balloon grows).
func _warn_gap(s: float) -> float:
	var k := _k(s)
	var lo: float = lerpf(WARN_GAP_START.x, WARN_GAP_END.x, k)
	var hi: float = lerpf(WARN_GAP_START.y, WARN_GAP_END.y, k)
	return s + randf_range(lo, hi)


func simulate_players(delta: float) -> void:
	for id in player_order:
		var p = players[id]
		if GameManager.players.has(id):
			p.is_bot = bool(GameManager.players[id]["is_bot"])
		var hold := false
		if p.is_bot:
			hold = bool(get_bot_command(p, delta).get("act", false))
		else:
			hold = bool(GameManager.get_input(int(id)).get("act", false))
		# Just popped: wait for the new balloon
		if float(pop_t[id]) > 0.0:
			pop_t[id] = maxf(float(pop_t[id]) - delta, 0.0)
			pumping[id] = false
			if float(pop_t[id]) <= 0.0:
				_new_balloon(id)
			continue
		pumping[id] = hold
		var s: float = float(size[id])
		if bool(warn[id]):
			if hold:
				# Pumping through the warning: pops after a short moment
				_rest[id] = 0.0
				_over[id] = float(_over[id]) + delta
				s = minf(s + PUMP_RATE * delta, MAX_SIZE)
				var grace: float = lerpf(GRACE_START, GRACE_END, _k(s))
				if float(_over[id]) >= grace:
					_pop(id)
					continue
			else:
				_rest[id] = float(_rest[id]) + delta
				if float(_rest[id]) >= REST_TIME:
					warn[id] = false
					_over[id] = 0.0
					_next_warn[id] = _warn_gap(s)
			calm[id] = clampf(float(_rest[id]) / REST_TIME, 0.0, 1.0)
		elif hold:
			s = minf(s + PUMP_RATE * delta, MAX_SIZE)
			if s >= float(_next_warn[id]):
				warn[id] = true
				_over[id] = 0.0
				_rest[id] = 0.0
				calm[id] = 0.0
		size[id] = s


func _pop(id: int) -> void:
	size[id] = 0.0
	warn[id] = false
	pumping[id] = false
	pops[id] = int(pops[id]) + 1
	pop_t[id] = NEW_BALLOON_TIME


func should_end() -> bool:
	return time_left <= 0.0


func on_game_end() -> void:
	for id in player_order:
		pumping[id] = false


func compute_rank_groups() -> Array:
	var ids: Array = player_order.duplicate()
	ids.sort_custom(func(a, b): return _score(a) > _score(b))
	var groups: Array = []
	var last := -1
	for id in ids:
		var n: int = _score(id)
		if groups.is_empty() or n != last:
			groups.append([id])
		else:
			groups[groups.size() - 1].append(id)
		last = n
	return groups


func _score(id) -> int:
	return roundi(float(size.get(id, 0.0)))


func stat_text(id: int) -> String:
	return "size %d" % _score(id)


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if w.size() == 1:
		return "%s WINS!" % str(w[0])
	return "TIE! " + " & ".join(PackedStringArray(w))


func cooldown_ratio_for(p) -> float:
	var id: int = int(p.peer_id)
	if state == "running" and float(pop_t.get(id, 0.0)) <= 0.0:
		return 0.0
	return 1.0


func local_input(_delta: float) -> Dictionary:
	var act: bool = hud.consume_action()
	if not GameManager.touch_mode and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		act = true
	return {"move": Vector2.ZERO, "act": act}


func get_extra_state() -> Dictionary:
	return {"sz": size, "wn": warn, "cm": calm, "pu": pumping, "pt": pop_t, "po": pops}


func apply_extra_state(m: Dictionary) -> void:
	size = m.get("sz", size)
	warn = m.get("wn", warn)
	calm = m.get("cm", calm)
	pumping = m.get("pu", pumping)
	pop_t = m.get("pt", pop_t)
	pops = m.get("po", pops)


# ---------------------------------------------------------------- bot AI

## Bots pump, then let go when the warning shows - after a human-ish reaction time
## (sometimes too slow!). Near the end, bots that are behind get greedy.
func get_bot_command(p, delta: float) -> Dictionary:
	var id: int = int(p.peer_id)
	var b: Dictionary = p.bot_brain
	if bool(warn.get(id, false)):
		if not b.has("react"):
			b["react"] = randf_range(0.12, 0.62)
		b["react"] = float(b["react"]) - delta
		var greedy := false
		if time_left < 3.0:
			var best := 0
			for oid in player_order:
				if oid != id:
					best = maxi(best, _score(oid))
			greedy = _score(id) < best
		return {"act": float(b["react"]) > 0.0 or greedy}
	b.erase("react")
	if not b.has("wait"):
		b["wait"] = randf_range(0.0, 0.5)   # a small pause before pumping again
	b["wait"] = float(b["wait"]) - delta
	if float(b["wait"]) > 0.0:
		return {"act": false}
	return {"act": true}


# ---------------------------------------------------------------- client side

func client_process(delta: float) -> void:
	_t += delta
	var me_id := GameManager.my_id()
	if state == "running" and float(pop_t.get(me_id, 0.0)) <= 0.0:
		if bool(warn.get(me_id, false)):
			hud.set_action("LET GO!", Color("#FF4D6D"))
		else:
			hud.set_action("PUMP!", Color("#2ECC71"))
	else:
		hud.set_action("WAIT", Color("#7a7a90"))
	for i in player_order.size():
		var id: int = player_order[i]
		# Pops
		var n: int = int(pops.get(id, 0))
		if n > int(_seen_pops.get(id, 0)):
			_seen_pops[id] = n
			var c := Vector2(_x_for(i), KNOT_Y - 60.0)
			Sfx.play("pop", 0.0 if id == me_id else -4.0, 0.1, 30)
			add_shake(6.0)
			spawn_burst(c, players[id].player_color, 26, 380.0, 10.0, 0.5)
			spawn_ring(c, Color.WHITE, 120.0, 0.3)
			if id == me_id:
				hud.show_center("POP! START OVER", Color("#FF4D6D"), 1.0)
		# Warning beep (only for my own balloon)
		var w := bool(warn.get(id, false))
		if w and not bool(_seen_warn.get(id, false)) and id == me_id:
			Sfx.play("tick_hi", 0.0)
		_seen_warn[id] = w
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
	# Who's biggest right now gets a crown
	var best := 1
	for id in player_order:
		best = maxi(best, _score(id))
	for i in player_order.size():
		var id: int = player_order[i]
		var p = players[id]
		var col: Color = p.player_color
		var x: float = _x_for(i)
		var sz: float = float(size.get(id, 0.0))
		var is_pumping := bool(pumping.get(id, false))
		var waiting: bool = float(pop_t.get(id, 0.0)) > 0.0
		var wob := bool(warn.get(id, false)) and not waiting
		var cm: float = float(calm.get(id, 0.0))
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
		if waiting:
			# Popped: rubber shreds, new balloon on the way
			for k in 5:
				var a2: float = float(k) * 1.3 + float(i)
				var piece := knot + Vector2(cos(a2) * 18.0, -10.0 - absf(sin(a2)) * 14.0)
				d.draw_colored_polygon(PackedVector2Array([piece, piece + Vector2(10, 4), piece + Vector2(4, 12)]), col.darkened(0.15))
			d.draw_colored_polygon(PackedVector2Array([knot + Vector2(-7, 12), knot + Vector2(7, 12), knot]), col.darkened(0.3))
			_text(d, font, knot + Vector2(0, -40), "POP!", 30, Color("#FF4D6D"))
			continue
		var r := _radius(sz)
		var c := Vector2(x, KNOT_Y - r)
		var sq := Vector2(0.92, 1.0)
		var body_col := col
		if wob:
			# Warning: shakes and flashes red (calms down while you rest)
			var shake: float = 3.5 * (1.0 - cm)
			c += Vector2(sin(_t * 41.0) * shake, cos(_t * 37.0) * shake * 0.6)
			sq = Vector2(0.92 + sin(_t * 30.0) * 0.05 * (1.0 - cm), 1.0 - sin(_t * 30.0) * 0.04 * (1.0 - cm))
			var flash: float = (0.35 + 0.35 * absf(sin(_t * 12.0))) * (1.0 - cm)
			body_col = col.lerp(Color("#ff2d2d"), flash)
		elif is_pumping:
			sq = Vector2(0.92 + sin(_t * 22.0) * 0.015, 1.0)
		d.draw_colored_polygon(UI.ellipse_points(c, r * sq.x, r * sq.y, 40), body_col.darkened(0.25))
		d.draw_colored_polygon(UI.ellipse_points(c + Vector2(-r * 0.05, -r * 0.05), r * sq.x * 0.9, r * sq.y * 0.9, 40), body_col)
		d.draw_colored_polygon(UI.ellipse_points(c + Vector2(-r * 0.35, -r * 0.4), r * 0.16, r * 0.26, 16), Color(1, 1, 1, 0.55))
		d.draw_colored_polygon(PackedVector2Array([knot + Vector2(-7, 10), knot + Vector2(7, 10), knot + Vector2(0, -2)]), col.darkened(0.3))
		_text(d, font, c + Vector2(0, 10), str(_score(id)), clampi(int(14.0 + r * 0.3), 14, 40), Color.WHITE)
		if wob:
			# Big "!" sign above the balloon + a ring that fills while you rest
			var sign_c := Vector2(x, c.y - r - 34.0)
			d.draw_circle(sign_c + Vector2(0, 3), 22.0, Color(0, 0, 0, 0.35))
			d.draw_circle(sign_c, 22.0, Color("#FF4D6D"))
			if cm > 0.01:
				d.draw_arc(sign_c, 27.0, -PI * 0.5, -PI * 0.5 + TAU * cm, 32, Color("#2ECC71"), 5.0, true)
			_text(d, font, sign_c + Vector2(0, 12), "!", 34, Color.WHITE)
			if int(id) == GameManager.my_id():
				_text(d, font, sign_c + Vector2(0, -32), "LET GO!", 22, Color("#FF4D6D"))
		elif _score(id) >= best and _score(id) > 0 and state == "running":
			UI.draw_crown(d, Vector2(x, c.y - r - 22.0), 34.0)
		# Pops so far
		var n: int = int(pops.get(id, 0))
		if n > 0:
			_text(d, font, Vector2(x + 52.0, PLAYER_Y + 48.0), "POPS: %d" % n, 14, Color("#ffb3c1"))


func _text(ci: CanvasItem, font: Font, center: Vector2, txt: String, fs: int, col: Color) -> void:
	var w := 220.0
	ci.draw_string_outline(font, center - Vector2(w * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_CENTER, w, fs, 7, Color(0, 0, 0, 0.8))
	ci.draw_string(font, center - Vector2(w * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_CENTER, w, fs, col)
