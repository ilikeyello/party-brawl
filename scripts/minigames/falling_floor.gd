extends "res://scripts/minigames/minigame_base.gd"
## FALLING FLOOR - a 15x8 floor of stone tiles over lava.
## Step on a tile and it cracks. Step on a cracked tile and it drops away a moment later.
## Standing still too long also makes your tile drop, so keep moving!
## DASH = a quick hop: tiles don't crack while you hop, and you can jump over a 1-tile gap.
## Dash into rivals to shove them toward the holes.
## After a while the floor crumbles on its own, from the outside in. Last one standing wins.

const COLS := 15
const ROWS := 8
const TILE := 64.0
const ORIGIN := Vector2(160.0, 104.0)
const BLOCK_H := 16.0
const CRACK_TIME := 1.0          # a falling tile drops after this long
const GONE := 255
const CRACKED := 1               # tiles[i]: 0 = solid, 1 = cracked (still safe),
const FALL_MIN := 2              # 2..201 = about to drop, 255 = gone
const CRACK_MAX := 201
const STAND_LIMIT := 1.8         # standing on one tile this long makes it drop
const AIR_GRACE := 0.09          # still "in the air" this long after a hop ends
const QUAKE_AT := 18.0           # floor starts crumbling on its own
const QUAKE_EVERY_START := 0.7
const QUAKE_EVERY_END := 0.18
const QUAKE_RAMP := 30.0
const FALL_ANIM := 0.55

var tiles := PackedByteArray()
var quaking := false
var _crack_t := PackedFloat32Array()   # host: how long each tile has been cracking
var _air: Dictionary = {}              # host: id -> hop time left
var _on_cell: Dictionary = {}          # host: id -> tile they're standing on
var _on_time: Dictionary = {}          # host: id -> how long they've stood there
var _quake_timer := 0.0

var backdrop: Node2D
var board: Node2D
var _mesh: ArrayMesh
var _prev := PackedByteArray()
var _fall_anim := PackedFloat32Array()  # client: > 0 while a tile is dropping
var _t := 0.0
var _quake_shown := false


func _init() -> void:
	game_id = "falling_floor"
	game_title = "FALLING FLOOR"
	instruction = "KEEP MOVING! LAST ONE STANDING WINS"
	duration = 60.0
	knock_strength = 380.0
	elim_style = "fall"
	camera_center = Vector2(640, 372)
	camera_zoom = 0.9
	follow_cam = true   # phones: zoom in + follow your player
	key_hint = "WASD / ARROWS: move     SPACE / SHIFT / CLICK: hop"


func build_arena() -> void:
	tiles.resize(COLS * ROWS)
	tiles.fill(0)
	_crack_t.resize(COLS * ROWS)
	_crack_t.fill(0.0)
	_prev = tiles.duplicate()
	_fall_anim.resize(COLS * ROWS)
	_fall_anim.fill(0.0)
	backdrop = Node2D.new()
	backdrop.name = "Lava"
	floor_layer.add_child(backdrop)
	backdrop.draw.connect(_draw_backdrop)
	board = Node2D.new()
	board.name = "Floor"
	floor_layer.add_child(board)
	board.draw.connect(_draw_board)


func configure_player(p) -> void:
	p.dash_cooldown_time = 1.0
	p.speed_mult = 0.8   # a bit slower than other games: easier to steer between holes


func get_spawn_points() -> Array:
	return [
		_cell_center(Vector2i(2, 1)),
		_cell_center(Vector2i(COLS - 3, 1)),
		_cell_center(Vector2i(COLS - 3, ROWS - 2)),
		_cell_center(Vector2i(2, ROWS - 2)),
		_cell_center(Vector2i(COLS >> 1, ROWS >> 1)),
	]


func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori((pos.x - ORIGIN.x) / TILE), floori((pos.y - ORIGIN.y) / TILE))


func _cell_center(c: Vector2i) -> Vector2:
	return ORIGIN + Vector2((float(c.x) + 0.5) * TILE, (float(c.y) + 0.5) * TILE)


func _valid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < COLS and c.y < ROWS


func _idx(c: Vector2i) -> int:
	return c.y * COLS + c.x


# ---------------------------------------------------------------- host logic

func game_step(delta: float) -> void:
	for p in alive_players():
		var id: int = int(p.peer_id)
		var air: float = float(_air.get(id, 0.0))
		if p.is_dashing:
			air = AIR_GRACE
		else:
			air = maxf(air - delta, 0.0)
		_air[id] = air
		if air > 0.0:
			continue   # hopping: no cracking, no falling
		var c := _cell_of(p.position)
		if not _valid(c) or tiles[_idx(c)] == GONE:
			eliminate_player(p)
			continue
		var i := _idx(c)
		if _on_cell.get(id, Vector2i(-99, -99)) != c:
			# Stepped onto a new tile: solid -> cracked, cracked -> drops
			_on_cell[id] = c
			_on_time[id] = 0.0
			if tiles[i] == 0:
				tiles[i] = CRACKED
			elif tiles[i] == CRACKED:
				_start_crack(i)
		else:
			_on_time[id] = float(_on_time.get(id, 0.0)) + delta
			if float(_on_time[id]) >= STAND_LIMIT and tiles[i] <= CRACKED:
				_start_crack(i)
	for i in tiles.size():
		var v: int = tiles[i]
		if v < FALL_MIN or v == GONE:
			continue
		_crack_t[i] += delta
		if _crack_t[i] >= CRACK_TIME:
			tiles[i] = GONE
		else:
			tiles[i] = clampi(FALL_MIN + int(_crack_t[i] / CRACK_TIME * float(CRACK_MAX - FALL_MIN)), FALL_MIN, CRACK_MAX)
	if elapsed >= QUAKE_AT:
		quaking = true
		_quake_timer -= delta
		if _quake_timer <= 0.0:
			var k: float = clampf((elapsed - QUAKE_AT) / QUAKE_RAMP, 0.0, 1.0)
			_quake_timer = lerpf(QUAKE_EVERY_START, QUAKE_EVERY_END, k)
			_crumble_one()


func _start_crack(i: int) -> void:
	tiles[i] = FALL_MIN
	_crack_t[i] = 0.0


## The floor crumbles from the outside in: pick a few random solid tiles, crack the one
## furthest from the middle (never the one someone is standing on).
func _crumble_one() -> void:
	var taken := {}
	for p in alive_players():
		taken[_cell_of(p.position)] = true
	var mid := Vector2(float(COLS - 1) * 0.5, float(ROWS - 1) * 0.5 * 1.8)
	var best := -1
	var best_d := -1.0
	for _k in 7:
		var c := Vector2i(randi() % COLS, randi() % ROWS)
		if tiles[_idx(c)] > CRACKED or taken.has(c):
			continue
		var d: float = (Vector2(c.x, float(c.y) * 1.8) - mid).length() + randf() * 2.0
		if d > best_d:
			best_d = d
			best = _idx(c)
	if best >= 0:
		_start_crack(best)


func on_dash_hit(_attacker, victim) -> void:
	victim.stun_timer = 0.25


func survivor_score(_id: int) -> float:
	return 0.0   # everyone still standing at the buzzer ties


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if alive_count() == 0:
		return "EVERYONE FELL!"
	if w.size() == 1:
		return "%s WINS!" % str(w[0])
	return "TIE! " + " & ".join(PackedStringArray(w))


func get_extra_state() -> Dictionary:
	return {"tiles": tiles, "qk": quaking}


func apply_extra_state(m: Dictionary) -> void:
	if m.has("tiles"):
		var incoming: PackedByteArray = m["tiles"]
		if incoming.size() == COLS * ROWS:
			tiles = incoming
	quaking = bool(m.get("qk", quaking))


# ---------------------------------------------------------------- bot AI

## How safe it is to stand at `pos`: 1 = solid, lower = cracking, -3 = hole / off the edge.
func _safety(pos: Vector2) -> float:
	var c := _cell_of(pos)
	if not _valid(c):
		return -3.0
	var v: int = tiles[_idx(c)]
	if v == GONE:
		return -3.0
	if v == 0:
		return 1.0
	if v == CRACKED:
		return 0.35
	return -0.2 - float(v) / float(CRACK_MAX) * 1.6


func _open_area(pos: Vector2) -> float:
	var c := _cell_of(pos)
	var n := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cc := c + Vector2i(dx, dy)
			if _valid(cc) and tiles[_idx(cc)] == 0:
				n += 2
			elif _valid(cc) and tiles[_idx(cc)] == CRACKED:
				n += 1
	return float(n) / 18.0


func get_bot_command(p, delta: float) -> Dictionary:
	var brain: Dictionary = p.bot_brain
	var think: float = float(brain.get("think", 0.0)) - delta
	var dir: Vector2 = brain.get("dir", Vector2.ZERO)
	# Think again right away if the tile underfoot or just ahead is about to go.
	var urgent: bool = _safety(p.position) < 0.0 or (dir != Vector2.ZERO and _safety(p.position + dir * 40.0) < 0.0)
	if think <= 0.0 or (urgent and think < 0.12):
		think = randf_range(0.14, 0.24)
		dir = _bot_pick_dir(p, dir)
	brain["think"] = think
	brain["dir"] = dir
	var act := false
	if float(p.dash_cooldown) <= 0.0 and dir != Vector2.ZERO:
		var ahead1 := _safety(p.position + dir * 58.0)
		var ahead2 := _safety(p.position + dir * 122.0)
		if ahead1 < 0.0 and ahead2 > 0.5:
			act = true   # hop over the gap
		else:
			var near = nearest_alive_other(p)
			if near != null and p.position.distance_to(near.position) < 85.0 and randf() < 0.2:
				var to_n: Vector2 = (near.position - p.position).normalized()
				if _safety(p.position + to_n * 120.0) > 0.0:
					dir = to_n
					act = true
	return {"move": dir, "act": act}


func _bot_pick_dir(p, prev: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_s := -INF
	var others: Array = []
	for o in alive_players():
		if o != p:
			others.append(o)
	for k in 16:
		var d := Vector2.from_angle(float(k) * TAU / 16.0)
		var s := 0.0
		var w := 1.0
		for step in [28.0, 56.0, 90.0, 130.0, 175.0]:
			var sf := _safety(p.position + d * float(step))
			s += sf * w
			if sf <= -2.5:
				s -= 4.0 * w
				break
			w *= 0.75
		s += _open_area(p.position + d * 150.0) * 0.8
		var probe: Vector2 = p.position + d * 100.0
		for o in others:
			if probe.distance_to(o.position) < 70.0:
				s -= 0.5
		s += d.dot(prev) * 0.45 + randf() * 0.35
		if s > best_s:
			best_s = s
			best = d
	return best


# ---------------------------------------------------------------- client side

func client_process(delta: float) -> void:
	_t += delta
	hud.set_action("HOP", Color("#FF9F43"))
	var dirty := false
	var changed := false
	var cracked := false
	for i in tiles.size():
		var v: int = tiles[i]
		var pv: int = _prev[i]
		if v != pv:
			changed = true
			dirty = true
			if v == GONE:
				_fall_anim[i] = FALL_ANIM
			elif v >= FALL_MIN and pv < FALL_MIN or v == CRACKED:
				cracked = true
		if _fall_anim[i] > 0.0:
			_fall_anim[i] = maxf(_fall_anim[i] - delta, 0.0)
			dirty = true
		elif v >= FALL_MIN and v != GONE:
			dirty = true   # tiles about to drop wobble
	if changed:
		_prev = tiles.duplicate()
	if cracked:
		Sfx.play("crack", -9.0, 0.15, 90)
	if quaking and not _quake_shown and state == "running":
		_quake_shown = true
		hud.show_center("THE FLOOR IS CRUMBLING!", Color("#FF9F43"), 1.2)
		Sfx.play("shrink")
		add_shake(6.0)
	if dirty:
		board.queue_redraw()


# ---------------------------------------------------------------- drawing

func _board_rect() -> Rect2:
	return Rect2(ORIGIN, Vector2(COLS * TILE, ROWS * TILE))


## Lava under the floor (drawn once).
func _draw_backdrop() -> void:
	var b := backdrop
	b.draw_rect(Rect2(-1400, -1000, 4080, 2720), Color("#1a0a0a"))
	var r := _board_rect()
	for k in 5:
		var g: float = float(5 - k)
		b.draw_rect(r.grow(18.0 + g * 16.0), Color(1.0, 0.3 + 0.04 * float(k), 0.05, 0.05 + 0.03 * float(k)))
	b.draw_rect(r.grow(18.0), Color("#c2410c"))
	b.draw_rect(r.grow(6.0), Color("#ea580c"))
	# Bright swirls in the lava
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for _i in 70:
		var at := Vector2(rng.randf_range(r.position.x - 10, r.end.x + 10), rng.randf_range(r.position.y - 10, r.end.y + 10))
		b.draw_colored_polygon(UI.ellipse_points(at, rng.randf_range(10, 34), rng.randf_range(4, 10), 14), Color(1.0, rng.randf_range(0.55, 0.8), 0.15, 0.55))
	for _i in 30:
		var at := Vector2(rng.randf_range(r.position.x, r.end.x), rng.randf_range(r.position.y, r.end.y))
		b.draw_circle(at, rng.randf_range(3, 7), Color(1.0, 0.9, 0.5, 0.7))


func _quad(verts: PackedVector2Array, cols: PackedColorArray, r: Rect2, c: Color) -> void:
	var a := r.position
	var b := Vector2(r.end.x, r.position.y)
	var d := Vector2(r.position.x, r.end.y)
	var e := r.end
	verts.append_array(PackedVector2Array([a, b, e, a, e, d]))
	for _k in 6:
		cols.append(c)


func _line_quad(verts: PackedVector2Array, cols: PackedColorArray, a: Vector2, b: Vector2, w: float, c: Color) -> void:
	var n := (b - a).orthogonal().normalized() * w * 0.5
	verts.append_array(PackedVector2Array([a - n, b - n, b + n, a - n, b + n, a + n]))
	for _k in 6:
		cols.append(c)


func _draw_board() -> void:
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	for y in ROWS:
		for x in COLS:
			var i: int = y * COLS + x
			var v: int = tiles[i]
			var checker: bool = (x + y) % 2 == 0
			var base := Color("#6b7a99") if checker else Color("#5d6b88")
			var r := Rect2(ORIGIN + Vector2(float(x) * TILE + 2.0, float(y) * TILE + 2.0), Vector2(TILE - 4.0, TILE - 4.0 - BLOCK_H * 0.25))
			if v == GONE:
				var fa: float = _fall_anim[i]
				if fa <= 0.0:
					continue
				# Dropping into the lava: shrink, sink and glow
				var f: float = 1.0 - fa / FALL_ANIM
				var shrink: float = f * 14.0
				var rr := r.grow(-shrink)
				rr.position.y += f * 34.0
				var col := base.lerp(Color("#ff6a00"), f)
				col.a = 1.0 - f
				_quad(verts, cols, Rect2(rr.position + Vector2(0, BLOCK_H), rr.size), Color(col.darkened(0.5), col.a))
				_quad(verts, cols, rr, col)
				continue
			# k: 0 = solid, 0.2 = cracked, then up to 1 just before it drops
			var k: float = 0.0
			if v == CRACKED:
				k = 0.2
			elif v >= FALL_MIN:
				k = 0.5 + 0.5 * float(v - FALL_MIN) / float(CRACK_MAX - FALL_MIN)
			var top := base
			if v == CRACKED:
				top = base.darkened(0.12)
			elif v >= FALL_MIN:
				top = base.lerp(Color("#ffb347"), clampf(k * 1.6, 0.0, 1.0)).lerp(Color("#ff3b1f"), clampf((k - 0.6) * 2.5, 0.0, 1.0))
				var wob: float = k * 2.5
				r.position += Vector2(sin(_t * 47.0 + float(i)) * wob, cos(_t * 53.0 + float(i) * 1.7) * wob * 0.6)
			_quad(verts, cols, Rect2(r.position + Vector2(0, r.size.y), Vector2(r.size.x, BLOCK_H)), top.darkened(0.55))
			_quad(verts, cols, r, top)
			_quad(verts, cols, Rect2(r.position, Vector2(r.size.x, 4)), top.lightened(0.18))
			_quad(verts, cols, Rect2(r.position + Vector2(8, 10), Vector2(10, 4)), top.lightened(0.3))
			if k > 0.12:
				# Crack lines
				var c := r.get_center()
				var dk := Color(0.12, 0.05, 0.03, 0.85)
				_line_quad(verts, cols, c + Vector2(-20, -16), c + Vector2(-2, 2), 3.0, dk)
				_line_quad(verts, cols, c + Vector2(-2, 2), c + Vector2(18, -6), 3.0, dk)
				if k > 0.45:
					_line_quad(verts, cols, c + Vector2(-2, 2), c + Vector2(4, 20), 3.0, dk)
					_line_quad(verts, cols, c + Vector2(10, -2), c + Vector2(22, 14), 2.5, dk)
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	if _mesh == null:
		_mesh = ArrayMesh.new()
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	board.draw_mesh(_mesh, null)
