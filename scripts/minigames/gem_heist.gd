extends "res://scripts/minigames/minigame_base.gd"
## GEM HEIST - gems keep appearing in the middle of the vault. Grab them (up to 3) and carry
## them back to YOUR base to bank them. You're slower while carrying.
## Dash into a carrier to knock their gems loose - then grab them yourself!
## You're safe inside your own base. BIG GEMS are worth 3. Last 15 s = GEM RUSH.
## Most gems banked wins.
## 2-4 players: a rectangle with bases in the corners. 5 players: a pentagon, one base per corner.

const ARENA := Rect2(160, 104, 960, 512)
const CENTER := Vector2(640, 360)
const WALL_T := 40.0
const WALL_H := 22.0
const BASE_R := 58.0
const GEM_R := 13.0
const PICK_DIST := 36.0
const MAX_CARRY := 3
const CARRY_SLOW := 0.13
const SPAWN_EVERY := 1.1
const SPAWN_EVERY_RUSH := 0.45
const BIG_EVERY := 11.0
const RUSH_AT := 15.0
const SPAWN_ZONE := 125.0
const DROP_SPEED := 320.0
const GEM_FRICTION := 520.0
const PENT_R := 345.0            # pentagon: centre to corner
const PENT_MID := Vector2(640, 392)
const PENT_BASE_IN := 100.0      # how far in from each corner the base sits

var pentagon := false
var mid := CENTER                 # middle of the field (where gems appear)
var arena_poly := PackedVector2Array()
var _edges: Array = []            # [point on edge, outward normal]

var bases: Dictionary = {}        # id -> Vector2
var gems: Array = []              # host: [{id, pos, vel, v, lock, from, from_t}]
var gem_view: Array = []          # synced: [uid, pos, value]
var carry: Dictionary = {}        # id -> Array of gem values
var banked: Dictionary = {}       # id -> int
var rush := false
var _uid := 0
var _spawn_t := 0.6
var _big_t := BIG_EVERY

var vault: Node2D
var gem_node: Node2D
var carry_node: Node2D
var _t := 0.0
var _rush_shown := false
var _last_carry: Dictionary = {}


func _init() -> void:
	game_id = "gem_heist"
	game_title = "GEM HEIST"
	instruction = "BANK THE MOST GEMS!"
	duration = 50.0
	knock_strength = 380.0
	elim_style = "fall"
	camera_center = Vector2(640, 372)
	camera_zoom = 0.9


func _ready() -> void:
	super()
	if pentagon:
		camera.position = Vector2(640, 382)
		camera_zoom = 0.86
		_apply_camera_zoom()
	var n: int = player_order.size()
	for i in n:
		var id: int = player_order[i]
		var pos := _base_pos(i, n)
		bases[id] = pos
		var p = players[id]
		p.position = pos
		p.net_pos = pos
		var to_c: Vector2 = mid - pos
		p.facing = to_c.normalized()
		carry[id] = []
		banked[id] = 0
	vault.queue_redraw()


## Bases sit the same distance from the gem pile: corners for up to 4 players,
## a circle for 5.
func _base_pos(i: int, n: int) -> Vector2:
	if pentagon:
		var pa: float = -PI * 0.5 + float(i) * TAU / 5.0
		return PENT_MID + Vector2.from_angle(pa) * (PENT_R - PENT_BASE_IN)
	if n <= 4:
		var corners := [
			Vector2(ARENA.position.x + 90, ARENA.position.y + 82),
			Vector2(ARENA.end.x - 90, ARENA.end.y - 82),
			Vector2(ARENA.end.x - 90, ARENA.position.y + 82),
			Vector2(ARENA.position.x + 90, ARENA.end.y - 82),
		]
		return corners[i % 4]
	var a: float = -PI * 0.5 + float(i) * TAU / float(n)
	return CENTER + Vector2(cos(a), sin(a)) * 215.0


func build_arena() -> void:
	vault = Node2D.new()
	vault.name = "Vault"
	floor_layer.add_child(vault)
	vault.draw.connect(_draw_vault)
	gem_node = Node2D.new()
	gem_node.name = "Gems"
	floor_layer.add_child(gem_node)
	gem_node.draw.connect(_draw_gems)
	carry_node = Node2D.new()
	carry_node.name = "Carried"
	fx_layer.add_child(carry_node)
	carry_node.draw.connect(_draw_carried)
	pentagon = players_expected() >= 5
	if pentagon:
		mid = PENT_MID
		for k in 5:
			arena_poly.append(PENT_MID + Vector2.from_angle(-PI * 0.5 + float(k) * TAU / 5.0) * PENT_R)
	else:
		mid = CENTER
		arena_poly = PackedVector2Array([ARENA.position, Vector2(ARENA.end.x, ARENA.position.y), ARENA.end, Vector2(ARENA.position.x, ARENA.end.y)])
	var bounds := Rect2(arena_poly[0], Vector2.ZERO)
	for pt in arena_poly:
		bounds = bounds.expand(pt)
	arena_rect = bounds.grow(14.0)   # walls are drawn just outside the field
	for k in arena_poly.size():
		var a: Vector2 = arena_poly[k]
		var b: Vector2 = arena_poly[(k + 1) % arena_poly.size()]
		var em: Vector2 = (a + b) * 0.5
		var n: Vector2 = (em - mid).normalized()
		_edges.append([a, n])
		_add_edge_wall(a, b, n)


## A thick wall along one edge of the field, on the outside.
func _add_edge_wall(a: Vector2, b: Vector2, n: Vector2) -> void:
	var body := StaticBody2D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(a.distance_to(b) + WALL_T * 2.0, WALL_T)
	cs.shape = shape
	body.position = (a + b) * 0.5 + n * WALL_T * 0.5
	body.rotation = (b - a).angle()
	body.add_child(cs)
	add_child(body)


# ---------------------------------------------------------------- host logic

func game_step(delta: float) -> void:
	if not rush and time_left <= RUSH_AT:
		rush = true
		_spawn_t = 0.1
	# Spawning
	var cap: int = player_order.size() + (6 if rush else 2)
	_spawn_t -= delta
	if _spawn_t <= 0.0:
		_spawn_t = SPAWN_EVERY_RUSH if rush else SPAWN_EVERY
		if gems.size() < cap:
			_spawn_gem(1)
	_big_t -= delta
	if _big_t <= 0.0:
		_big_t = BIG_EVERY
		var g := _spawn_gem(3)
		if not g.is_empty():
			push_event(g["pos"] + Vector2(0, -36), "BIG GEM!", Color("#FFD60A"))
	# Gems sliding after being knocked loose
	for g in gems:
		g["lock"] = maxf(float(g["lock"]) - delta, 0.0)
		g["from_t"] = maxf(float(g["from_t"]) - delta, 0.0)
		var v: Vector2 = g["vel"]
		if v.length() > 1.0:
			var pos: Vector2 = g["pos"] + v * delta
			# Bounce off the walls (works for both the rectangle and the pentagon)
			for e in _edges:
				var en: Vector2 = e[1]
				var over: float = (pos - e[0]).dot(en) + GEM_R
				if over > 0.0:
					pos -= en * over
					var vn: float = v.dot(en)
					if vn > 0.0:
						v -= en * vn * 1.6
			g["pos"] = pos
			g["vel"] = v.move_toward(Vector2.ZERO, GEM_FRICTION * delta)
	# Picking up + banking
	for p in alive_players():
		var id: int = int(p.peer_id)
		var held: Array = carry[id]
		if held.size() < MAX_CARRY:
			for i in range(gems.size() - 1, -1, -1):
				var g: Dictionary = gems[i]
				if float(g["lock"]) > 0.0 or (int(g["from"]) == id and float(g["from_t"]) > 0.0):
					continue
				if p.position.distance_to(g["pos"]) <= PICK_DIST:
					held.append(int(g["v"]))
					gems.remove_at(i)
					if held.size() >= MAX_CARRY:
						break
		if not held.is_empty() and p.position.distance_to(bases[id]) <= BASE_R:
			var total := 0
			for v in held:
				total += int(v)
			banked[id] = int(banked[id]) + total
			held.clear()
			push_event(bases[id] + Vector2(0, -50), "+%d" % total, p.player_color.lightened(0.3))
		p.speed_mult = 1.0 - CARRY_SLOW * float(held.size())
	_sync_view()


func _spawn_gem(value: int) -> Dictionary:
	for _try in 12:
		var a := randf() * TAU
		var r := sqrt(randf()) * SPAWN_ZONE
		var pos := mid + Vector2(cos(a) * r, sin(a) * r * 0.75)
		var ok := true
		for g in gems:
			if pos.distance_to(g["pos"]) < GEM_R * 3.0:
				ok = false
				break
		if not ok:
			continue
		_uid += 1
		var g := {"id": _uid, "pos": pos, "vel": Vector2.ZERO, "v": value, "lock": 0.0, "from": 0, "from_t": 0.0}
		gems.append(g)
		return g
	return {}


func _in_own_base(p) -> bool:
	return p.position.distance_to(bases.get(int(p.peer_id), Vector2.INF)) <= BASE_R


func on_dash_hit(attacker, victim) -> void:
	var id: int = int(victim.peer_id)
	if _in_own_base(victim):
		return
	victim.stun_timer = 0.45
	var held: Array = carry.get(id, [])
	if held.is_empty():
		return
	var away: Vector2 = (victim.position - attacker.position).normalized()
	for v in held:
		_uid += 1
		var dir := away.rotated(randf_range(-1.3, 1.3))
		gems.append({"id": _uid, "pos": victim.position, "vel": dir * DROP_SPEED * randf_range(0.6, 1.0),
			"v": int(v), "lock": 0.3, "from": id, "from_t": 1.0})
	held.clear()
	victim.speed_mult = 1.0
	push_event(victim.position + Vector2(0, -60), "DROP!", Color("#FEE440"))


func _sync_view() -> void:
	gem_view = []
	for g in gems:
		gem_view.append([int(g["id"]), g["pos"], int(g["v"])])


func should_end() -> bool:
	return time_left <= 0.0


func compute_rank_groups() -> Array:
	var ids: Array = player_order.duplicate()
	ids.sort_custom(func(a, b): return int(banked.get(a, 0)) > int(banked.get(b, 0)))
	var groups: Array = []
	var last := -1
	for id in ids:
		var n: int = int(banked.get(id, 0))
		if groups.is_empty() or n != last:
			groups.append([id])
		else:
			groups[groups.size() - 1].append(id)
		last = n
	return groups


func _carry_value(id: int) -> int:
	var t := 0
	for v in carry.get(id, []):
		t += int(v)
	return t


func stat_text(id: int) -> String:
	var c := _carry_value(id)
	var s := "%d gem%s" % [int(banked.get(id, 0)), "" if int(banked.get(id, 0)) == 1 else "s"]
	if c > 0:
		s += " (+%d)" % c
	return s


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if w.size() == 1:
		return "%s WINS!" % str(w[0])
	return "TIE! " + " & ".join(PackedStringArray(w))


func event_sound(text: String) -> String:
	if text.begins_with("+"):
		return "bank"
	if text == "DROP!":
		return "gem"
	return "powerup"


func get_extra_state() -> Dictionary:
	return {"gm": gem_view, "ca": carry, "bk": banked, "ru": rush}


func apply_extra_state(m: Dictionary) -> void:
	gem_view = m.get("gm", gem_view)
	carry = m.get("ca", carry)
	banked = m.get("bk", banked)
	rush = bool(m.get("ru", rush))


# ---------------------------------------------------------------- bot AI

func get_bot_command(p, delta: float) -> Dictionary:
	var id: int = int(p.peer_id)
	var brain: Dictionary = p.bot_brain
	var held: Array = carry.get(id, [])
	var cval := _carry_value(id)
	var home: Vector2 = bases[id]
	var think: float = float(brain.get("think", 0.0)) - delta
	if think <= 0.0:
		think = randf_range(0.2, 0.4)
		# Nearest worthwhile gem
		var best = null
		var best_s := INF
		for g in gems:
			if float(g["lock"]) > 0.0 or (int(g["from"]) == id and float(g["from_t"]) > 0.0):
				continue
			var gp: Vector2 = g["pos"]
			var s: float = p.position.distance_to(gp) - (140.0 if int(g["v"]) > 1 else 0.0) + randf() * 40.0
			# Someone else is clearly closer? Less interesting.
			for o in alive_players():
				if o != p and o.position.distance_to(gp) < p.position.distance_to(gp) * 0.6:
					s += 80.0
			if s < best_s:
				best_s = s
				best = gp
		var go_home: bool = held.size() >= MAX_CARRY or (not held.is_empty() and (cval >= 3 or best == null or best_s > 240.0 or (rush and held.size() >= 2)))
		brain["target"] = home if go_home or best == null else best
		brain["home"] = go_home
	brain["think"] = think
	var target: Vector2 = brain.get("target", mid)
	var to_t: Vector2 = target - p.position
	var mv: Vector2 = to_t.normalized() if to_t.length() > 8.0 else Vector2.ZERO
	var act := false
	if float(p.dash_cooldown) <= 0.0:
		# Mug a nearby carrier
		var victim = null
		var vd := 120.0
		for o in alive_players():
			if o == p or _carry_value(int(o.peer_id)) == 0 or _in_own_base(o):
				continue
			var d: float = p.position.distance_to(o.position)
			if d < vd:
				vd = d
				victim = o
		if victim != null and held.size() <= 1:
			mv = (victim.position - p.position).normalized()
			act = vd < 95.0 and randf() < 0.5
		elif to_t.length() > 220.0 and randf() < 0.012:
			act = true
	return {"move": mv, "act": act}


# ---------------------------------------------------------------- client side

func client_process(delta: float) -> void:
	_t += delta
	if rush and not _rush_shown and state == "running":
		_rush_shown = true
		hud.show_center("GEM RUSH!", Color("#00F5D4"), 1.0)
		Sfx.play("frenzy")
		hud.flash(Color(0.3, 1.0, 0.9, 0.25))
	# Pick-up sound
	var me := GameManager.my_id()
	for id in player_order:
		var n: int = (carry.get(id, []) as Array).size()
		var before: int = int(_last_carry.get(id, 0))
		if n > before:
			Sfx.play("gem", -1.0 if id == me else -9.0, 0.08, 40)
		_last_carry[id] = n
	gem_node.queue_redraw()
	carry_node.queue_redraw()


# ---------------------------------------------------------------- drawing

func _draw_vault() -> void:
	var v := vault
	v.draw_rect(Rect2(-1400, -1000, 4080, 2720), Color("#0d0b1e"))
	var tile := 64.0
	if pentagon:
		# Raised rim: dark "side" first, then the top of the wall, then the floor
		var outer: Array = Geometry2D.offset_polygon(arena_poly, WALL_T, Geometry2D.JOIN_MITER)
		if not outer.is_empty():
			var side := PackedVector2Array()
			for p in outer[0]:
				side.append(p + Vector2(0, WALL_H))
			v.draw_colored_polygon(side, Color("#2e2660"))
			v.draw_colored_polygon(outer[0], Color("#4a3f86"))
		v.draw_colored_polygon(arena_poly, Color("#1f1a3d"))
		var box := Rect2(arena_poly[0], Vector2.ZERO)
		for p in arena_poly:
			box = box.expand(p)
		for y in int(ceil(box.size.y / tile)):
			for x in int(ceil(box.size.x / tile)):
				if (x + y) % 2 != 0:
					continue
				var r := Rect2(box.position + Vector2(x, y) * tile, Vector2(tile, tile))
				var sq := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
				for piece in Geometry2D.intersect_polygons(sq, arena_poly):
					if piece.size() >= 3:
						v.draw_colored_polygon(piece, Color("#241e46"))
	else:
		v.draw_rect(ARENA.grow(WALL_T), Color("#2b2350"))
		v.draw_rect(ARENA, Color("#1f1a3d"))
		for y in int(ARENA.size.y / tile):
			for x in int(ARENA.size.x / tile):
				if (x + y) % 2 == 0:
					v.draw_rect(Rect2(ARENA.position + Vector2(x, y) * tile, Vector2(tile, tile)), Color("#241e46"))
	# Gem pile in the middle
	var pit := UI.ellipse_points(mid, SPAWN_ZONE + 26.0, (SPAWN_ZONE + 26.0) * 0.75, 48)
	v.draw_colored_polygon(pit, Color("#2e2160"))
	v.draw_polyline(pit + PackedVector2Array([pit[0]]), Color("#9B5DE5"), 3.0, true)
	# Bases
	var font: Font = UI.title_font()
	for id in bases:
		var p = players.get(id)
		if p == null:
			continue
		var c: Vector2 = bases[id]
		var col: Color = p.player_color
		var ring := UI.ellipse_points(c, BASE_R, BASE_R * 0.8, 40)
		v.draw_colored_polygon(ring, Color(col, 0.28))
		v.draw_polyline(ring + PackedVector2Array([ring[0]]), col, 5.0, true)
		v.draw_colored_polygon(UI.ellipse_points(c, BASE_R * 0.62, BASE_R * 0.5, 32), Color(col.darkened(0.4), 0.5))
		v.draw_string_outline(font, c + Vector2(-60, BASE_R * 0.8 + 22), "BASE", HORIZONTAL_ALIGNMENT_CENTER, 120, 16, 5, Color(0, 0, 0, 0.8))
		v.draw_string(font, c + Vector2(-60, BASE_R * 0.8 + 22), "BASE", HORIZONTAL_ALIGNMENT_CENTER, 120, 16, col.lightened(0.3))
	if pentagon:
		v.draw_polyline(arena_poly + PackedVector2Array([arena_poly[0]]), Color("#6d5fb8"), 4.0, true)
	else:
		# Walls (raised rim)
		UI.draw_block(v, Rect2(ARENA.position.x - WALL_T, ARENA.position.y - WALL_T + WALL_H, ARENA.size.x + WALL_T * 2.0, WALL_T), WALL_H, Color("#4a3f86"), Color("#2e2660"))
		UI.draw_block(v, Rect2(ARENA.position.x - WALL_T, ARENA.position.y, WALL_T, ARENA.size.y + WALL_H), WALL_H, Color("#4a3f86"), Color("#2e2660"))
		UI.draw_block(v, Rect2(ARENA.end.x, ARENA.position.y, WALL_T, ARENA.size.y + WALL_H), WALL_H, Color("#4a3f86"), Color("#2e2660"))
		UI.draw_block(v, Rect2(ARENA.position.x - WALL_T, ARENA.end.y + WALL_H, ARENA.size.x + WALL_T * 2.0, WALL_T), WALL_H, Color("#4a3f86"), Color("#2e2660"))


func _gem_shape(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var top := c + Vector2(0, -r)
	var left := c + Vector2(-r * 0.85, -r * 0.25)
	var right := c + Vector2(r * 0.85, -r * 0.25)
	var bottom := c + Vector2(0, r)
	ci.draw_colored_polygon(PackedVector2Array([left, top, right, bottom]), col)
	ci.draw_colored_polygon(PackedVector2Array([left, top, c + Vector2(0, -r * 0.25)]), col.lightened(0.35))
	ci.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -r * 0.25), right, bottom]), col.darkened(0.3))
	ci.draw_polyline(PackedVector2Array([left, top, right, bottom, left]), Color(1, 1, 1, 0.8), 1.5, true)


func _draw_gems() -> void:
	var n := gem_node
	for g in gem_view:
		var uid: int = int(g[0])
		var pos: Vector2 = g[1]
		var big: bool = int(g[2]) > 1
		var r: float = GEM_R * (1.6 if big else 1.0)
		var bob: float = sin(_t * 4.0 + float(uid)) * 3.0
		n.draw_colored_polygon(UI.ellipse_points(pos + Vector2(0, 6), r * 0.9, r * 0.35, 14), Color(0, 0, 0, 0.4))
		var col := Color("#FFD60A") if big else Color("#3ddcff").lerp(Color("#c77dff"), 0.5 + 0.5 * sin(float(uid)))
		n.draw_circle(pos + Vector2(0, -10 + bob), r * 1.5, Color(col, 0.15 + 0.08 * sin(_t * 6.0 + float(uid))))
		_gem_shape(n, pos + Vector2(0, -10 + bob), r, col)
		if int(_t * 3.0 + float(uid)) % 5 == 0:
			var sp := pos + Vector2(r * 0.5, -10 - r * 0.6 + bob)
			n.draw_line(sp + Vector2(-4, 0), sp + Vector2(4, 0), Color.WHITE, 2.0)
			n.draw_line(sp + Vector2(0, -4), sp + Vector2(0, 4), Color.WHITE, 2.0)


func _draw_carried() -> void:
	var n := carry_node
	for id in player_order:
		var p = players[id]
		if p.is_eliminated:
			continue
		var held: Array = carry.get(id, [])
		for k in held.size():
			var big: bool = int(held[k]) > 1
			var col := Color("#FFD60A") if big else Color("#3ddcff")
			var off := Vector2((float(k) - float(held.size() - 1) * 0.5) * 20.0, -92.0 + sin(_t * 8.0 + float(k)) * 2.0)
			_gem_shape(n, p.position + off, 9.0 if not big else 12.0, col)
	# Your own base pulses while you're carrying
	var me := GameManager.my_id()
	if bases.has(me) and not (carry.get(me, []) as Array).is_empty():
		var c: Vector2 = bases[me]
		var k2: float = 0.5 + 0.5 * sin(_t * 6.0)
		n.draw_polyline(UI.ellipse_points(c, BASE_R + 8.0 + k2 * 6.0, (BASE_R + 8.0 + k2 * 6.0) * 0.8, 40) + PackedVector2Array([c + Vector2(BASE_R + 8.0 + k2 * 6.0, 0)]), Color(1, 1, 1, 0.5 + 0.4 * k2), 3.0, true)
