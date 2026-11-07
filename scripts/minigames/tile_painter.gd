extends "res://scripts/minigames/minigame_base.gd"
## TILE PAINTER - 16x10 board of raised tiles. Walk to paint, dash to splash a 3x3 area
## and stun anyone you hit. Most tiles at the buzzer wins (equal tiles = a real tie).
## Chaos:
##  - Power-ups: PAINT BOMB (thrown somewhere that is not your colour yet, big splash when it lands), ROLLER (paint 3 wide for a while),
##    FREEZE (everyone else frozen), SWAP (trade ALL your tiles with the leader's!)
##  - ERASER BOT rolls in after a while, wiping paint and bumping players
##  - FRENZY in the last 10 seconds: power-ups rain down and dashes recharge twice as fast

const COLS := 16
const ROWS := 10
const TILE := 48.0
const ORIGIN := Vector2(640.0 - 16 * 48.0 * 0.5, 360.0 - 10 * 48.0 * 0.5)
const DEFAULT_COL := Color("#2B2D42")
const STUN_TIME := 1.2
const BOARD_DEPTH := 22.0

const PU_TYPES := ["bomb", "roller", "freeze", "swap"]
const PU_NAMES := ["PAINT BOMB", "ROLLER", "FREEZE", "SWAP"]
const PU_COLORS := [Color("#FF6B35"), Color("#2ECC71"), Color("#7FDBFF"), Color("#FFFFFF")]
const PU_WEIGHTS := [3, 3, 2, 1]
const PU_EVERY := 4.0
const PU_EVERY_FRENZY := 1.3
const PU_MAX := 3
const PU_MAX_FRENZY := 6
const PU_PICK_DIST := 32.0
const PAINT_BOMB_FUSE := 1.75       # includes the throw
const BOMB_FLIGHT := 0.55           # the bomb flies through the air this long
const PAINT_BOMB_RADIUS := 2.7
const ROLLER_TIME := 5.0
const FREEZE_TIME := 1.6
const FRENZY_AT := 10.0

const ERASER_SPAWN_AT := 12.0
const ERASER_SPEED := 125.0
const ERASER_RADIUS := 26.0

var tiles: PackedByteArray = PackedByteArray()   # 0 = unpainted, else slot + 1
var _prev_tiles: PackedByteArray = PackedByteArray()
var _pop: PackedFloat32Array = PackedFloat32Array()
var _counts: Array = [0, 0, 0, 0, 0, 0]

var powerups: Array = []          # [uid, type, cx, cy]
var paint_bombs: Array = []       # [uid, cx, cy, value, t_left, thrown_from]
var rollers: Dictionary = {}      # id -> time left (host); clients get a list of ids
var roller_ids: Array = []
var _uid: int = 0
var pu_timer: float = 2.0
var frenzy: bool = false
var eraser_active: bool = false
var eraser_pos: Vector2 = Vector2(640, 120)
var _eraser_target: Vector2 = Vector2(640, 360)
var _eraser_retarget: float = 0.0

var board: Node2D
var pu_node: Node2D
var pu_labels: Node2D
var eraser_node: Node2D
var _t: float = 0.0
var _frenzy_shown: bool = false
var _eraser_shown: bool = false
var _seen_bombs: Dictionary = {}
var _board_dirty := true
var _last_rollers := 0
var board_static: Node2D
var _board_mesh: ArrayMesh


func _init() -> void:
	arena_rect = Rect2(ORIGIN, Vector2(COLS * TILE, ROWS * TILE + BOARD_DEPTH))
	game_id = "tile_painter"
	game_title = "TILE PAINTER"
	instruction = "PAINT THE MOST TILES!"
	duration = 45.0
	knock_strength = 350.0
	elim_style = "fall"


func build_arena() -> void:
	tiles.resize(COLS * ROWS)
	tiles.fill(0)
	_prev_tiles = tiles.duplicate()
	_pop.resize(COLS * ROWS)
	_pop.fill(0.0)

	board_static = Node2D.new()
	board_static.name = "Backdrop"
	floor_layer.add_child(board_static)
	board_static.draw.connect(_draw_backdrop)

	board = Node2D.new()
	board.name = "Board"
	floor_layer.add_child(board)
	board.draw.connect(_draw_board)

	pu_node = Node2D.new()
	pu_node.name = "PowerUps"
	floor_layer.add_child(pu_node)
	pu_node.draw.connect(_draw_powerups)

	pu_labels = Node2D.new()
	pu_labels.name = "PowerUpLabels"
	fx_layer.add_child(pu_labels)
	pu_labels.draw.connect(_draw_pu_labels)

	eraser_node = Node2D.new()
	eraser_node.name = "EraserBot"
	eraser_node.visible = false
	world.add_child(eraser_node)
	eraser_node.draw.connect(_draw_eraser)

	var rect := _board_rect()
	var w := 40.0
	add_wall(Rect2(rect.position.x - w, rect.position.y - w, rect.size.x + w * 2.0, w))
	add_wall(Rect2(rect.position.x - w, rect.end.y, rect.size.x + w * 2.0, w))
	add_wall(Rect2(rect.position.x - w, rect.position.y, w, rect.size.y))
	add_wall(Rect2(rect.end.x, rect.position.y, w, rect.size.y))


func _board_rect() -> Rect2:
	return Rect2(ORIGIN, Vector2(COLS * TILE, ROWS * TILE))


func get_spawn_points() -> Array:
	return [
		_cell_center(Vector2i(2, 2)),
		_cell_center(Vector2i(COLS - 3, 2)),
		_cell_center(Vector2i(COLS - 3, ROWS - 3)),
		_cell_center(Vector2i(2, ROWS - 3)),
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


func _paint(c: Vector2i, val: int) -> void:
	if _valid(c):
		tiles[_idx(c)] = val


func _paint_area(c: Vector2i, val: int, radius: int) -> void:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			_paint(c + Vector2i(dx, dy), val)


# ---------------------------------------------------------------- host logic

func game_step(delta: float) -> void:
	# Frenzy: last 10 seconds
	if not frenzy and time_left <= FRENZY_AT:
		frenzy = true
		pu_timer = 0.2
		for p in alive_players():
			p.dash_cooldown_time = 0.6
	for id in player_order:
		var p = players[id]
		if p.is_eliminated:
			continue
		var val: int = int(p.slot) + 1
		var c := _cell_of(p.position)
		if float(rollers.get(id, 0.0)) > 0.0:
			_paint_area(c, val, 1)
		else:
			_paint(c, val)
	for id in rollers.keys():
		rollers[id] = float(rollers[id]) - delta
		if float(rollers[id]) <= 0.0:
			rollers.erase(id)
	_update_powerups(delta)
	_update_paint_bombs(delta)
	_update_eraser(delta)


func on_dash_started(p) -> void:
	# 3x3 paint splash where the dash begins.
	_paint_area(_cell_of(p.position), int(p.slot) + 1, 1)


func on_dash_hit(_attacker, victim) -> void:
	victim.stun_timer = STUN_TIME


func should_end() -> bool:
	return time_left <= 0.0


func _update_powerups(delta: float) -> void:
	pu_timer -= delta
	var cap: int = PU_MAX_FRENZY if frenzy else PU_MAX
	if pu_timer <= 0.0:
		pu_timer = PU_EVERY_FRENZY if frenzy else PU_EVERY
		if powerups.size() < cap:
			_spawn_powerup()
	for i in range(powerups.size() - 1, -1, -1):
		var pu: Array = powerups[i]
		var pos := _cell_center(Vector2i(int(pu[2]), int(pu[3])))
		for p in alive_players():
			if p.position.distance_to(pos) <= PU_PICK_DIST:
				powerups.remove_at(i)
				_apply_powerup(p, int(pu[1]), pos)
				break


func _spawn_powerup() -> void:
	for _try in 20:
		var c := Vector2i(randi() % COLS, randi() % ROWS)
		var ok := true
		for pu in powerups:
			if int(pu[2]) == c.x and int(pu[3]) == c.y:
				ok = false
		for p in alive_players():
			if p.position.distance_to(_cell_center(c)) < TILE * 2.0:
				ok = false
		if not ok:
			continue
		_uid += 1
		powerups.append([_uid, _weighted_type(), c.x, c.y])
		return


func _weighted_type() -> int:
	var total := 0
	for w in PU_WEIGHTS:
		total += int(w)
	var r := randi() % total
	for i in PU_WEIGHTS.size():
		r -= int(PU_WEIGHTS[i])
		if r < 0:
			return i
	return 0


func _apply_powerup(p, typ: int, pos: Vector2) -> void:
	var col: Color = PU_COLORS[typ]
	var val: int = int(p.slot) + 1
	var pcol: Color = p.player_color
	match PU_TYPES[typ]:
		"bomb":
			# Thrown to a part of the board that ISN'T your colour yet
			# (where you picked it up is usually already painted by you).
			_uid += 1
			var c := _bomb_target(val, _cell_of(pos))
			paint_bombs.append([_uid, c.x, c.y, val, PAINT_BOMB_FUSE, pos])
			push_event(pos + Vector2(0, -40), "PAINT BOMB!", col)
		"roller":
			rollers[int(p.peer_id)] = ROLLER_TIME
			push_event(pos + Vector2(0, -40), "ROLLER!", col)
		"freeze":
			for o in alive_players():
				if o != p:
					o.freeze_timer = FREEZE_TIME
					o.move_vel = Vector2.ZERO
			push_event(pos + Vector2(0, -40), "FREEZE!", col)
		"swap":
			_recount()
			var leader_val := 0
			var best := -1
			for v in range(1, 6):
				if v != val and int(_counts[v]) > best:
					best = int(_counts[v])
					leader_val = v
			if leader_val != 0 and best > int(_counts[val]):
				for i in tiles.size():
					if tiles[i] == val:
						tiles[i] = leader_val
					elif tiles[i] == leader_val:
						tiles[i] = val
				push_event(pos + Vector2(0, -40), "SWAP!!", pcol)
			else:
				# Already leading: just a big splash instead.
				_paint_area(_cell_of(pos), val, 2)
				push_event(pos + Vector2(0, -40), "SPLASH!", pcol)


## Try a handful of random spots and throw the bomb where it paints the most tiles
## that aren't yours already (random, but almost always worth it). Not right on top of you.
func _bomb_target(val: int, from: Vector2i) -> Vector2i:
	var best := Vector2i(COLS >> 1, ROWS >> 1)
	var best_n := -1
	var r: int = ceili(PAINT_BOMB_RADIUS)
	for _k in 8:
		var c := Vector2i(1 + randi() % (COLS - 2), 1 + randi() % (ROWS - 2))
		if absi(c.x - from.x) + absi(c.y - from.y) < 4:
			continue
		var n := 0
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var cc := c + Vector2i(dx, dy)
				if _valid(cc) and Vector2(dx, dy).length() <= PAINT_BOMB_RADIUS and int(tiles[_idx(cc)]) != val:
					n += 1
		if n > best_n:
			best_n = n
			best = c
	return best


func _update_paint_bombs(delta: float) -> void:
	for i in range(paint_bombs.size() - 1, -1, -1):
		var pb: Array = paint_bombs[i]
		pb[4] = float(pb[4]) - delta
		if float(pb[4]) <= 0.0:
			paint_bombs.remove_at(i)
			var c := Vector2i(int(pb[1]), int(pb[2]))
			var val: int = int(pb[3])
			for dy in range(-3, 4):
				for dx in range(-3, 4):
					if Vector2(dx, dy).length() <= PAINT_BOMB_RADIUS:
						_paint(c + Vector2i(dx, dy), val)
			var center := _cell_center(c)
			for p in alive_players():
				var off: Vector2 = p.position - center
				var d: float = off.length()
				if d < TILE * 2.2:
					p.knockback_vel += (off / d if d > 0.01 else Vector2.RIGHT) * 260.0
			push_event(center + Vector2(0, -30), "SPLAT!", GameManager.COLORS[clampi(val - 1, 0, 4)])


func _update_eraser(delta: float) -> void:
	if not eraser_active:
		if elapsed >= ERASER_SPAWN_AT:
			eraser_active = true
			eraser_pos = _cell_center(Vector2i(COLS >> 1, 0))
			_eraser_retarget = 0.0
			push_event(eraser_pos + Vector2(0, -20), "ERASER BOT!", Color("#cfd2e6"))
		return
	_eraser_retarget -= delta
	if _eraser_retarget <= 0.0 or eraser_pos.distance_to(_eraser_target) < 10.0:
		_eraser_retarget = 3.0
		_eraser_target = _densest_spot()
	var to_t: Vector2 = _eraser_target - eraser_pos
	if to_t.length() > 1.0:
		eraser_pos += to_t.normalized() * minf(ERASER_SPEED * delta, to_t.length())
	# Wipe the tile under it + its 4 neighbours
	var c := _cell_of(eraser_pos)
	for d in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		_paint(c + d, 0)
	# Bump players out of the way
	for p in alive_players():
		var off: Vector2 = p.position - eraser_pos
		var dist: float = off.length()
		if dist < ERASER_RADIUS + PLAYER_RADIUS and float(p.hit_immunity) <= 0.0:
			var n: Vector2 = off / dist if dist > 0.01 else Vector2.DOWN
			p.knockback_vel = n * 380.0
			p.move_vel = Vector2.ZERO
			p.stun_timer = maxf(float(p.stun_timer), 0.5)
			p.hit_immunity = 0.6
			_hit_count += 1
			_last_hit_pos = (p.position + eraser_pos) * 0.5 + Vector2(0, -12)


func _densest_spot() -> Vector2:
	var best := Vector2i(COLS >> 1, ROWS >> 1)
	var best_n := -1
	for _k in 14:
		var c := Vector2i(1 + randi() % (COLS - 2), 1 + randi() % (ROWS - 2))
		var n := 0
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if tiles[_idx(c + Vector2i(dx, dy))] != 0:
					n += 1
		if n > best_n:
			best_n = n
			best = c
	return _cell_center(best)


# ---------------------------------------------------------------- placements / HUD

func compute_rank_groups() -> Array:
	_recount()
	var ids: Array = player_order.duplicate()
	ids.sort_custom(func(a, b): return _count_for(int(a)) > _count_for(int(b)))
	var groups: Array = []
	var last := -1
	for id in ids:
		var n := _count_for(int(id))
		if groups.is_empty() or n != last:
			groups.append([id])
		else:
			groups[groups.size() - 1].append(id)
		last = n
	return groups


func _count_for(id: int) -> int:
	var p = players.get(id)
	if p == null:
		return 0
	return int(_counts[int(p.slot) + 1])


func _recount() -> void:
	_counts = [0, 0, 0, 0, 0, 0]
	for i in tiles.size():
		var v: int = tiles[i]
		if v >= 0 and v < _counts.size():
			_counts[v] = int(_counts[v]) + 1


func stat_text(id: int) -> String:
	var n := _count_for(id)
	var extra := ""
	if roller_ids.has(id):
		extra = " ROLL"
	return "%d tile%s%s" % [n, "" if n == 1 else "s", extra]


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if w.size() == 1:
		return "%s WINS!" % str(w[0])
	if w.size() > 1:
		return "TIE! " + " & ".join(PackedStringArray(w))
	return "TIME!"


func get_extra_state() -> Dictionary:
	return {
		"tiles": tiles, "pu": powerups, "pb": paint_bombs, "rol": rollers.keys(),
		"er": [eraser_active, eraser_pos], "fz": frenzy,
	}


func apply_extra_state(m: Dictionary) -> void:
	if m.has("tiles"):
		var incoming: PackedByteArray = m["tiles"]
		if incoming.size() == COLS * ROWS:
			tiles = incoming
	powerups = m.get("pu", powerups)
	paint_bombs = m.get("pb", paint_bombs)
	roller_ids = m.get("rol", roller_ids)
	frenzy = bool(m.get("fz", frenzy))
	var er: Array = m.get("er", [eraser_active, eraser_pos])
	eraser_active = bool(er[0])
	eraser_pos = er[1]


func client_process(delta: float) -> void:
	_t += delta
	if GameManager.is_host():
		roller_ids = rollers.keys()
	var dirty := false
	for i in tiles.size():
		if tiles[i] != _prev_tiles[i]:
			_pop[i] = 1.0
			dirty = true
		elif _pop[i] > 0.0:
			_pop[i] = maxf(_pop[i] - delta * 3.5, 0.0)
			dirty = true
	if dirty:
		_prev_tiles = tiles.duplicate()
		_recount()
	# Only redraw the board when something on it changed (saves a lot of battery on phones).
	_board_dirty = dirty or not roller_ids.is_empty() or frenzy or roller_ids.size() != _last_rollers
	_last_rollers = roller_ids.size()
	# Banners
	if frenzy and not _frenzy_shown and state == "running":
		_frenzy_shown = true
		hud.show_center("FRENZY!", Color("#FF4D6D"), 0.9)
		Sfx.play("frenzy")
		hud.flash(Color(1.0, 0.3, 0.6, 0.3))
		add_shake(6.0)
	if eraser_active and not _eraser_shown:
		_eraser_shown = true
		add_shake(4.0)
	# Paint bomb splat: shake when one disappears
	var current := {}
	for pb in paint_bombs:
		current[int(pb[0])] = true
	for uid in _seen_bombs.keys():
		if not current.has(uid):
			add_shake(8.0)
			_seen_bombs.erase(uid)
	for uid in current:
		_seen_bombs[uid] = true
	eraser_node.visible = eraser_active
	eraser_node.position = eraser_node.position.lerp(eraser_pos, clampf(delta * 18.0, 0.0, 1.0)) if eraser_node.position.distance_to(eraser_pos) < 80.0 else eraser_pos
	if frenzy:
		hud.set_action("DASH!", Color("#FF4D6D"))
	if _board_dirty:
		board.queue_redraw()
	pu_node.queue_redraw()
	pu_labels.queue_redraw()
	eraser_node.queue_redraw()


# ---------------------------------------------------------------- bot AI

func get_bot_command(p, delta: float) -> Dictionary:
	var brain: Dictionary = p.bot_brain
	var my_val: int = int(p.slot) + 1
	# Grab nearby power-ups first
	var best_pu := Vector2.INF
	var best_d := TILE * 4.5
	for pu in powerups:
		var pp := _cell_center(Vector2i(int(pu[2]), int(pu[3])))
		var d: float = p.position.distance_to(pp)
		if d < best_d:
			best_d = d
			best_pu = pp
	var mv := Vector2.ZERO
	if best_pu != Vector2.INF:
		mv = (best_pu - p.position).normalized()
	else:
		var tgt: Vector2i = brain.get("tile", Vector2i(-1, -1))
		var retarget: float = float(brain.get("t", 0.0)) - delta
		if retarget <= 0.0 or not _valid(tgt) or int(tiles[_idx(tgt)]) == my_val:
			tgt = _pick_target(p.position, my_val)
			retarget = randf_range(1.0, 2.2)
		brain["tile"] = tgt
		brain["t"] = retarget
		var to_t: Vector2 = _cell_center(tgt) - p.position
		mv = to_t.normalized() if to_t.length() > 4.0 else Vector2.ZERO
	# Steer around the eraser bot
	if eraser_active:
		var off: Vector2 = p.position - eraser_pos
		if off.length() < 110.0 and off.length() > 0.01:
			mv = (mv + off.normalized() * 1.4).normalized()
	var act := false
	if float(p.dash_cooldown) <= 0.0:
		var near = nearest_alive_other(p)
		var near_close: bool = near != null and p.position.distance_to(near.position) < 90.0
		act = near_close or randf() < (0.08 if frenzy else 0.03)
		if near_close:
			mv = (near.position - p.position).normalized()
	return {"move": mv, "act": act}


func _pick_target(pos: Vector2, my_val: int) -> Vector2i:
	var here := _cell_of(pos)
	var best := Vector2i(-1, -1)
	var best_score := INF
	for dy in range(-5, 6):
		for dx in range(-5, 6):
			var c := here + Vector2i(dx, dy)
			if not _valid(c):
				continue
			var v: int = tiles[_idx(c)]
			if v == my_val:
				continue
			var dist: float = Vector2(dx, dy).length()
			if dist < 0.5:
				continue
			var score: float = dist + randf() * 2.5 - (0.6 if v != 0 else 0.0)
			if score < best_score:
				best_score = score
				best = c
	if best == Vector2i(-1, -1):
		best = Vector2i(randi() % COLS, randi() % ROWS)
	return best


# ---------------------------------------------------------------- drawing (pseudo-3D)

func _slot_color(s: int) -> Color:
	return GameManager.COLORS[clampi(s, 0, 4)]


## Static background (drawn once).
func _draw_backdrop() -> void:
	var b := board_static
	b.draw_rect(Rect2(-1400, -1000, 4080, 2720), Color("#0e1020"))
	var rim := _board_rect().grow(14.0)
	b.draw_rect(Rect2(rim.position + Vector2(16, BOARD_DEPTH + 18), rim.size), Color(0, 0, 0, 0.5))
	b.draw_rect(Rect2(rim.position + Vector2(0, BOARD_DEPTH), rim.size), Color("#161829"))
	b.draw_rect(Rect2(rim.position.x, rim.end.y, rim.size.x, BOARD_DEPTH), Color("#23264a"))


func _quad(verts: PackedVector2Array, cols: PackedColorArray, r: Rect2, c: Color) -> void:
	var a := r.position
	var b := Vector2(r.end.x, r.position.y)
	var d := Vector2(r.position.x, r.end.y)
	var e := r.end
	verts.append_array(PackedVector2Array([a, b, e, a, e, d]))
	for k in 6:
		cols.append(c)


func _draw_board() -> void:
	var b := board
	var rect := _board_rect()
	var rim := rect.grow(14.0)
	var rim_col := Color("#3a3d5c")
	if frenzy:
		rim_col = Color("#3a3d5c").lerp(Color("#FF4D6D"), 0.4 + 0.3 * sin(_t * 10.0))
	b.draw_rect(rim, rim_col)
	b.draw_rect(Rect2(rim.position, Vector2(rim.size.x, 3)), Color("#5c6090"))
	b.draw_rect(rect.grow(2.0), Color("#111325"))
	# All 160 tiles go into ONE mesh = one draw call (was ~800 separate rectangles,
	# which is a lot of work for a phone every frame).
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	for y in ROWS:
		for x in COLS:
			var i: int = y * COLS + x
			var v: int = tiles[i]
			var base: Color = DEFAULT_COL if v == 0 else _slot_color(v - 1)
			var pop: float = _pop[i]
			var r := Rect2(ORIGIN + Vector2(float(x) * TILE + 2.0, float(y) * TILE + 2.0), Vector2(TILE - 4.0, TILE - 6.0))
			if pop > 0.0:
				r = r.grow(pop * 3.0)
				r.position.y -= pop * 4.0
				base = base.lightened(pop * 0.45)
			_quad(verts, cols, Rect2(r.position + Vector2(0, 5), r.size), base.darkened(0.5))
			_quad(verts, cols, r, base)
			_quad(verts, cols, Rect2(r.position, Vector2(r.size.x, 4)), base.lightened(0.2))
			if v != 0:
				_quad(verts, cols, Rect2(r.position + Vector2(6, 8), Vector2(r.size.x * 0.35, 4)), base.lightened(0.35))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	if _board_mesh == null:
		_board_mesh = ArrayMesh.new()
	_board_mesh.clear_surfaces()
	_board_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	b.draw_mesh(_board_mesh, null)
	# Roller brushes under players who have one
	for id in roller_ids:
		var p = players.get(id)
		if p == null or p.is_eliminated:
			continue
		var c := _cell_center(_cell_of(p.position))
		var area := Rect2(c - Vector2(TILE * 1.5, TILE * 1.5), Vector2(TILE * 3.0, TILE * 3.0)).intersection(_board_rect())
		b.draw_rect(area, Color(p.player_color, 0.18 + 0.1 * sin(_t * 12.0)))
		b.draw_rect(area, Color(1, 1, 1, 0.5), false, 2.0)


func _draw_powerups() -> void:
	for pu in powerups:
		var typ: int = int(pu[1])
		var base := _cell_center(Vector2i(int(pu[2]), int(pu[3])))
		var bob: float = sin(_t * 3.0 + float(pu[0])) * 4.0
		var c: Vector2 = base + Vector2(0, -16 + bob)
		var col: Color = PU_COLORS[typ]
		pu_node.draw_colored_polygon(UI.ellipse_points(base + Vector2(0, 8), 14.0 - bob * 0.5, 5.0, 18), Color(0, 0, 0, 0.4))
		if PU_TYPES[typ] == "swap":
			# Rainbow ring for the rare SWAP
			for k in 4:
				pu_node.draw_arc(c, 19.0, float(k) * PI * 0.5 + _t * 3.0, float(k + 1) * PI * 0.5 + _t * 3.0, 8, GameManager.COLORS[k], 5.0, true)
		else:
			pu_node.draw_circle(c, 20.0, Color(col, 0.25 + 0.1 * sin(_t * 5.0)))
		pu_node.draw_circle(c, 16.0, col.darkened(0.35))
		pu_node.draw_circle(c + Vector2(0, -1.5), 14.5, col)
		pu_node.draw_circle(c + Vector2(-5, -6), 3.5, Color(1, 1, 1, 0.5))
		_draw_pu_icon(PU_TYPES[typ], c)
	# Ticking paint bombs
	for pb in paint_bombs:
		var bc := _cell_center(Vector2i(int(pb[1]), int(pb[2])))
		var pcol: Color = _slot_color(int(pb[3]) - 1)
		var left: float = float(pb[4])
		var ring_r: float = PAINT_BOMB_RADIUS * TILE
		var flown: float = PAINT_BOMB_FUSE - left
		if flown < BOMB_FLIGHT and pb.size() > 5:
			# In the air: arc from where it was picked up to where it lands
			var f: float = clampf(flown / BOMB_FLIGHT, 0.0, 1.0)
			var from: Vector2 = pb[5]
			var ground: Vector2 = from.lerp(bc, f)
			var air: Vector2 = ground + Vector2(0, -10.0 - sin(f * PI) * 150.0)
			pu_node.draw_arc(bc, ring_r, 0.0, TAU, 48, Color(pcol, 0.25 + 0.4 * f), 3.0, true)
			pu_node.draw_colored_polygon(UI.ellipse_points(ground + Vector2(0, 8), 14.0 - sin(f * PI) * 6.0, 5.0, 16), Color(0, 0, 0, 0.35))
			pu_node.draw_circle(air, 15.0, Color(0.1, 0.08, 0.12))
			pu_node.draw_circle(air, 10.0, pcol)
			pu_node.draw_circle(air + Vector2(-4, -5), 3.5, Color(1, 1, 1, 0.6))
			continue
		var k: float = 1.0 - clampf(left / (PAINT_BOMB_FUSE - BOMB_FLIGHT), 0.0, 1.0)
		pu_node.draw_circle(bc, ring_r, Color(pcol, 0.12 + 0.12 * k))
		pu_node.draw_arc(bc, ring_r, 0.0, TAU, 48, Color(pcol, 0.8), 3.0, true)
		pu_node.draw_arc(bc, ring_r * k, 0.0, TAU, 48, Color(1, 1, 1, 0.6), 2.0, true)
		var pulse: float = 1.0 + 0.25 * sin(_t * (14.0 + k * 20.0))
		pu_node.draw_circle(bc + Vector2(0, -10), 15.0 * pulse, Color(0.1, 0.08, 0.12))
		pu_node.draw_circle(bc + Vector2(0, -10), 10.0 * pulse, pcol)
		pu_node.draw_circle(bc + Vector2(-4, -15), 3.5, Color(1, 1, 1, 0.6))


func _draw_pu_icon(kind: String, c: Vector2) -> void:
	var w := Color.WHITE
	var dk := Color(0.1, 0.1, 0.18)
	match kind:
		"bomb":
			pu_node.draw_circle(c + Vector2(-1, 2), 8.0, dk)
			pu_node.draw_line(c + Vector2(3, -5), c + Vector2(7, -10), w, 2.5)
			pu_node.draw_circle(c + Vector2(7, -10), 2.5, Color("#FFE066"))
			# drips
			pu_node.draw_circle(c + Vector2(-6, 9), 2.5, dk)
			pu_node.draw_circle(c + Vector2(3, 10), 2.0, dk)
		"roller":
			pu_node.draw_rect(Rect2(c + Vector2(-10, -9), Vector2(20, 8)), w)
			pu_node.draw_line(c + Vector2(0, -1), c + Vector2(0, 5), dk, 2.5)
			pu_node.draw_line(c + Vector2(0, 5), c + Vector2(0, 11), dk, 4.0)
		"freeze":
			for i in 3:
				var d := Vector2.from_angle(float(i) * PI / 3.0) * 9.0
				pu_node.draw_line(c - d, c + d, w, 2.5)
		"swap":
			pu_node.draw_line(c + Vector2(-8, -4), c + Vector2(7, -4), dk, 2.5)
			pu_node.draw_colored_polygon(PackedVector2Array([c + Vector2(9, -4), c + Vector2(4, -8), c + Vector2(4, 0)]), dk)
			pu_node.draw_line(c + Vector2(8, 4), c + Vector2(-7, 4), dk, 2.5)
			pu_node.draw_colored_polygon(PackedVector2Array([c + Vector2(-9, 4), c + Vector2(-4, 0), c + Vector2(-4, 8)]), dk)


func _draw_pu_labels() -> void:
	var font: Font = UI.title_font()
	for pu in powerups:
		var typ: int = int(pu[1])
		var base := _cell_center(Vector2i(int(pu[2]), int(pu[3])))
		var at := base + Vector2(-50, -40)
		pu_labels.draw_string_outline(font, at, PU_NAMES[typ], HORIZONTAL_ALIGNMENT_CENTER, 100, 13, 5, Color(0, 0, 0, 0.85))
		pu_labels.draw_string(font, at, PU_NAMES[typ], HORIZONTAL_ALIGNMENT_CENTER, 100, 13, PU_COLORS[typ].lightened(0.2))


func _draw_eraser() -> void:
	var n := eraser_node
	var spin: float = _t * 9.0
	n.draw_colored_polygon(UI.ellipse_points(Vector2(0, 6), ERASER_RADIUS, 10.0, 24), Color(0, 0, 0, 0.4))
	var c := Vector2(0, -12)
	# Body: metallic dome
	n.draw_circle(c, ERASER_RADIUS + 2.0, Color("#3a3d52"))
	n.draw_circle(c + Vector2(-2, -3), ERASER_RADIUS - 2.0, Color("#9aa0bd"))
	n.draw_circle(c + Vector2(-8, -10), ERASER_RADIUS * 0.4, Color("#d5d9ee"))
	# Spinning brushes
	for k in 6:
		var a: float = spin + float(k) * TAU / 6.0
		var tip := c + Vector2.from_angle(a) * (ERASER_RADIUS + 9.0)
		n.draw_line(c + Vector2.from_angle(a) * (ERASER_RADIUS - 2.0), tip, Color("#f1f2f8"), 3.0, true)
	# Angry red eye + stripe
	n.draw_rect(Rect2(c + Vector2(-16, -2), Vector2(32, 7)), Color("#22232f"))
	var blink: float = 0.6 + 0.4 * sin(_t * 8.0)
	n.draw_circle(c + Vector2(0, 1.5), 5.0, Color(1.0, 0.15, 0.2, blink))
	n.draw_arc(c, ERASER_RADIUS + 2.0, 0.0, TAU, 32, Color.WHITE, 2.5, true)
