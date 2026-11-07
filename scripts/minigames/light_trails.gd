extends "res://scripts/minigames/minigame_base.gd"
## LIGHT TRAILS - everyone rides nonstop and leaves a glowing wall behind them.
## Steer with the stick / arrow keys (no U-turns). Hit a trail or the edge = out.
## BOOST = a short burst of speed. Riders speed up over time. A crashed rider's trail
## fades away after a moment. Last rider standing wins.
##
## The grid is the truth (host). Each cell byte: bits 0-2 = own (slot + 1),
## bits 3-6 = which sides connect to the next trail cell (R, D, L, U),
## bit 7 = "reserved": the rider is on the way into this cell right now.

const COLS := 40
const ROWS := 21
const CELL := 24.0
const ORIGIN := Vector2(160.0, 108.0)
const SPEED_START := 7.0        # cells per second
const SPEED_END := 11.0
const SPEED_RAMP := 40.0
const BOOST_MULT := 1.8
const BOOST_TIME := 0.5
const BOOST_CD := 3.0
const DEREZ_TIME := 1.2
const RESERVED := 128
const DIRS := [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]   # R D L U
## Pinwheel start: [cell, direction index] per slot.
const STARTS := [
	[Vector2i(4, 3), 0], [Vector2i(35, 17), 2], [Vector2i(36, 4), 1], [Vector2i(3, 16), 3], [Vector2i(20, 12), 3],
]
const TRAIL_W := 11.0

var grid := PackedByteArray()
var heads: Dictionary = {}        # host: id -> {cell, next, dir, want, prog, bt, bcd}
var _derez: Dictionary = {}       # host: own value -> seconds left
var _grid_dirty := true
var _packed := PackedByteArray()

var backdrop: Node2D
var trails: Node2D
var heads_node: Node2D
var _mesh: ArrayMesh
var _prev := PackedByteArray()
var _t := 0.0
var _speed := SPEED_START
var _was_boost := false


func _init() -> void:
	game_id = "light_trails"
	game_title = "LIGHT TRAILS"
	instruction = "DON'T HIT A TRAIL! LAST RIDER WINS"
	duration = 60.0
	elim_style = "explode"
	camera_center = Vector2(640, 372)
	camera_zoom = 0.9
	key_hint = "WASD / ARROWS: steer     SPACE / SHIFT / CLICK: boost"


func build_arena() -> void:
	grid.resize(COLS * ROWS)
	grid.fill(0)
	_prev = grid.duplicate()
	backdrop = Node2D.new()
	backdrop.name = "Grid"
	floor_layer.add_child(backdrop)
	backdrop.draw.connect(_draw_backdrop)
	trails = Node2D.new()
	trails.name = "Trails"
	floor_layer.add_child(trails)
	trails.draw.connect(_draw_trails)
	heads_node = Node2D.new()
	heads_node.name = "Riders"
	floor_layer.add_child(heads_node)
	heads_node.draw.connect(_draw_heads)


func configure_player(p) -> void:
	# The rider is drawn by this game (a glowing light cycle), not as the usual ball.
	p.visual.visible = false
	p.shadow.visible = false
	p.dash_sound = false
	var st: Array = STARTS[int(p.slot) % STARTS.size()]
	p.facing = Vector2(DIRS[int(st[1])])
	p.name_label.position.y += 22.0


func get_spawn_points() -> Array:
	var out: Array = []
	for st in STARTS:
		out.append(_center(st[0]))
	return out


func _center(c: Vector2i) -> Vector2:
	return ORIGIN + Vector2((float(c.x) + 0.5) * CELL, (float(c.y) + 0.5) * CELL)


func _valid(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < COLS and c.y < ROWS


func _idx(c: Vector2i) -> int:
	return c.y * COLS + c.x


func _free(c: Vector2i) -> bool:
	return _valid(c) and grid[_idx(c)] == 0


static func _bit(d: int) -> int:
	return 1 << (3 + d)


# ---------------------------------------------------------------- host logic

func on_game_start() -> void:
	for id in player_order:
		var p = players[id]
		var st: Array = STARTS[int(p.slot) % STARTS.size()]
		var cell: Vector2i = st[0]
		var d: int = int(st[1])
		var own: int = int(p.slot) + 1
		var nxt: Vector2i = cell + DIRS[d]
		grid[_idx(cell)] = own | _bit(d)
		grid[_idx(nxt)] = own | _bit((d + 2) % 4) | RESERVED
		heads[id] = {"cell": cell, "next": nxt, "dir": d, "want": -1, "prog": 0.0, "bt": 0.0, "bcd": 0.0}
	_grid_dirty = true


func simulate_players(delta: float) -> void:
	_speed = lerpf(SPEED_START, SPEED_END, clampf(elapsed / SPEED_RAMP, 0.0, 1.0))
	var arrivals: Array = []
	for id in player_order:
		var p = players[id]
		if p.is_eliminated or not heads.has(id):
			continue
		if GameManager.players.has(id):
			p.is_bot = bool(GameManager.players[id]["is_bot"])
		var h: Dictionary = heads[id]
		var mv := Vector2.ZERO
		var act := false
		if p.is_bot:
			var cmd: Dictionary = get_bot_command(p, delta)
			mv = cmd.get("move", Vector2.ZERO)
			act = bool(cmd.get("act", false))
		else:
			var inp: Dictionary = GameManager.get_input(int(id))
			mv = inp.get("move", Vector2.ZERO)
			act = bool(inp.get("act", false))
		_read_turn(h, mv)
		h["bt"] = maxf(float(h["bt"]) - delta, 0.0)
		h["bcd"] = maxf(float(h["bcd"]) - delta, 0.0)
		if act and float(h["bcd"]) <= 0.0:
			h["bt"] = BOOST_TIME
			h["bcd"] = BOOST_CD
		p.boost_timer = float(h["bt"])
		p.dash_cooldown = float(h["bcd"])
		var mult: float = BOOST_MULT if float(h["bt"]) > 0.0 else 1.0
		h["prog"] = float(h["prog"]) + _speed * mult * delta
		if float(h["prog"]) >= 1.0:
			h["prog"] = float(h["prog"]) - 1.0
			arrivals.append(id)
	# Everyone who reached a cell this tick picks their next cell at the same time,
	# so two riders aiming for the same cell both crash (a fair head-on).
	var claims: Dictionary = {}
	for id in arrivals:
		var h: Dictionary = heads[id]
		h["cell"] = h["next"]
		grid[_idx(h["cell"])] = grid[_idx(h["cell"])] & ~RESERVED
		var want: int = int(h["want"])
		if want >= 0 and want != (int(h["dir"]) + 2) % 4:
			h["dir"] = want
		h["want"] = -1
		var nxt: Vector2i = h["cell"] + DIRS[int(h["dir"])]
		h["next"] = nxt
		if not claims.has(nxt):
			claims[nxt] = []
		claims[nxt].append(id)
		_grid_dirty = true
	for nxt in claims:
		var ids: Array = claims[nxt]
		var blocked: bool = not _free(nxt) or ids.size() > 1
		for id in ids:
			var h: Dictionary = heads[id]
			var p = players[id]
			if blocked:
				p.position = _center(h["cell"]).lerp(_center(h["cell"]) + Vector2(DIRS[int(h["dir"])]) * CELL, 0.3)
				_crash(p)
			else:
				var d: int = int(h["dir"])
				grid[_idx(h["cell"])] = grid[_idx(h["cell"])] | _bit(d)
				grid[_idx(nxt)] = (int(p.slot) + 1) | _bit((d + 2) % 4) | RESERVED
	for id in player_order:
		var p = players[id]
		if p.is_eliminated or not heads.has(id):
			continue
		var h: Dictionary = heads[id]
		var dv := Vector2(DIRS[int(h["dir"])])
		var a := _center(h["cell"])
		p.position = a + dv * CELL * clampf(float(h["prog"]), 0.0, 1.0)
		var mult: float = BOOST_MULT if float(h["bt"]) > 0.0 else 1.0
		p.move_vel = dv * _speed * mult * CELL
		p.velocity = p.move_vel
		p.facing = dv


func _read_turn(h: Dictionary, mv: Vector2) -> void:
	if mv.length() < 0.4:
		return
	var d: int
	if absf(mv.x) > absf(mv.y):
		d = 0 if mv.x > 0.0 else 2
	else:
		d = 1 if mv.y > 0.0 else 3
	var cur: int = int(h["dir"])
	if d == cur:
		h["want"] = -1
	elif d != (cur + 2) % 4:
		h["want"] = d


func _crash(p) -> void:
	if p.is_eliminated:
		return
	p.move_vel = Vector2.ZERO
	p.boost_timer = 0.0
	eliminate_player(p)
	var own: int = int(p.slot) + 1
	_derez[own] = DEREZ_TIME
	# Their reserved cell (if any) is no longer coming
	var h: Dictionary = heads.get(int(p.peer_id), {})
	if not h.is_empty() and _valid(h["next"]):
		var v: int = grid[_idx(h["next"])]
		if (v & 7) == own and (v & RESERVED) != 0:
			grid[_idx(h["next"])] = 0
	_grid_dirty = true


func game_step(delta: float) -> void:
	for own in _derez.keys():
		_derez[own] = float(_derez[own]) - delta
		if float(_derez[own]) <= 0.0:
			_derez.erase(own)
			for i in grid.size():
				if (grid[i] & 7) == int(own):
					grid[i] = 0
			_grid_dirty = true


func cooldown_ratio_for(p) -> float:
	return float(p.dash_cooldown) / BOOST_CD


func survivor_score(_id: int) -> float:
	return 0.0


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if alive_count() == 0:
		return "TOTAL CRASH!"
	if w.size() == 1:
		return "%s WINS!" % str(w[0])
	return "TIE! " + " & ".join(PackedStringArray(w))


func get_extra_state() -> Dictionary:
	if _grid_dirty:
		_grid_dirty = false
		_packed = grid.compress(FileAccess.COMPRESSION_DEFLATE)
	return {"g": _packed, "sp": _speed}


func apply_extra_state(m: Dictionary) -> void:
	if m.has("g"):
		var packed: PackedByteArray = m["g"]
		if packed.size() > 0:
			var g := packed.decompress(COLS * ROWS, FileAccess.COMPRESSION_DEFLATE)
			if g.size() == COLS * ROWS:
				grid = g
	_speed = float(m.get("sp", _speed))


# ---------------------------------------------------------------- bot AI

func get_bot_command(p, _delta: float) -> Dictionary:
	var h: Dictionary = heads.get(int(p.peer_id), {})
	if h.is_empty():
		return {"move": Vector2.ZERO, "act": false}
	var brain: Dictionary = p.bot_brain
	var nxt: Vector2i = h["next"]
	# Decide right after reaching a cell, and look again halfway (the grid keeps changing).
	var key := Vector3i(nxt.x, nxt.y, 1 if float(h["prog"]) > 0.55 else 0)
	if brain.get("key", Vector3i(-99, -99, -99)) != key:
		brain["key"] = key
		brain["d"] = _bot_choose(p, nxt, int(h["dir"]))
	var d: int = int(brain.get("d", int(h["dir"])))
	var act := false
	if float(h["bcd"]) <= 0.0 and randf() < 0.015 and _run_length(nxt, d, 12) >= 10:
		act = true
	return {"move": Vector2(DIRS[d]), "act": act}


func _bot_choose(p, from: Vector2i, cur: int) -> int:
	var opts := [cur, (cur + 1) % 4, (cur + 3) % 4]
	var best: int = cur
	var best_s := -INF
	var free_opts: Array = []
	for d in opts:
		var c: Vector2i = from + DIRS[d]
		var s: float
		if not _free(c):
			s = -1000.0 + randf()
		else:
			free_opts.append(d)
			s = float(_flood(c, 120)) + float(_run_length(from, d, 8)) * 0.8 + (2.0 if d == cur else 0.0) + randf() * 3.0
			# Stay away from cells another rider is about to enter (head-on risk)
			for oid in heads:
				if int(oid) == int(p.peer_id) or players[oid].is_eliminated:
					continue
				var on: Vector2i = heads[oid]["next"]
				if absi(on.x - c.x) + absi(on.y - c.y) <= 1:
					s -= 30.0
		if s > best_s:
			best_s = s
			best = d
	# Now and then bots make a less clever (but not suicidal) choice.
	if free_opts.size() > 1 and randf() < 0.05:
		best = int(free_opts[randi() % free_opts.size()])
	return best


func _run_length(from: Vector2i, d: int, limit: int) -> int:
	var n := 0
	var c := from
	while n < limit:
		c += DIRS[d]
		if not _free(c):
			break
		n += 1
	return n


## How many free cells can be reached from `start` (capped).
## Uses reusable flat arrays (no Dictionary / pop_front), so bots think ~5x cheaper on the host.
var _seen_mark := PackedInt32Array()
var _seen_gen: int = 0
var _fq := PackedInt32Array()


func _flood(start: Vector2i, limit: int) -> int:
	if not _valid(start):
		return 1
	var total: int = COLS * ROWS
	if _seen_mark.size() != total:
		_seen_mark.resize(total)
		_seen_mark.fill(0)
		_fq.resize(total)
		_seen_gen = 0
	_seen_gen += 1
	var gen: int = _seen_gen
	var si: int = start.y * COLS + start.x
	_seen_mark[si] = gen
	_fq[0] = si
	var head: int = 0
	var tail: int = 1
	var n: int = 0
	while head < tail and n < limit:
		var i: int = _fq[head]
		head += 1
		n += 1
		var x: int = i % COLS
		var j: int
		if x > 0:
			j = i - 1
			if _seen_mark[j] != gen and grid[j] == 0:
				_seen_mark[j] = gen
				_fq[tail] = j
				tail += 1
		if x < COLS - 1:
			j = i + 1
			if _seen_mark[j] != gen and grid[j] == 0:
				_seen_mark[j] = gen
				_fq[tail] = j
				tail += 1
		if i >= COLS:
			j = i - COLS
			if _seen_mark[j] != gen and grid[j] == 0:
				_seen_mark[j] = gen
				_fq[tail] = j
				tail += 1
		if i + COLS < total:
			j = i + COLS
			if _seen_mark[j] != gen and grid[j] == 0:
				_seen_mark[j] = gen
				_fq[tail] = j
				tail += 1
	return n


# ---------------------------------------------------------------- client side

func client_process(delta: float) -> void:
	_t += delta
	hud.set_action("BOOST", Color("#00F5D4"))
	hud.swipe_mode = true
	var me = players.get(GameManager.my_id())
	if me != null:
		var b: bool = float(me.boost_timer) > 0.0 and not me.is_eliminated
		if b and not _was_boost:
			Sfx.play("dash", -2.0, 0.08)
		_was_boost = b
	if grid != _prev:
		_prev = grid.duplicate()
		trails.queue_redraw()
	heads_node.queue_redraw()


func _draw_backdrop() -> void:
	var b := backdrop
	b.draw_rect(Rect2(-1400, -1000, 4080, 2720), Color("#050816"))
	var r := Rect2(ORIGIN, Vector2(COLS * CELL, ROWS * CELL))
	for k in 4:
		b.draw_rect(r.grow(6.0 + float(k) * 6.0), Color(0.0, 0.96, 0.83, 0.07), false, 6.0)
	b.draw_rect(r, Color("#0b1030"))
	var line := Color(0.3, 0.5, 1.0, 0.12)
	for x in range(COLS + 1):
		b.draw_line(ORIGIN + Vector2(float(x) * CELL, 0), ORIGIN + Vector2(float(x) * CELL, ROWS * CELL), line, 1.0)
	for y in range(ROWS + 1):
		b.draw_line(ORIGIN + Vector2(0, float(y) * CELL), ORIGIN + Vector2(COLS * CELL, float(y) * CELL), line, 1.0)
	b.draw_rect(r, Color("#00F5D4"), false, 3.0)


func _quad(verts: PackedVector2Array, cols: PackedColorArray, r: Rect2, c: Color) -> void:
	var a := r.position
	var b := Vector2(r.end.x, r.position.y)
	var d := Vector2(r.position.x, r.end.y)
	var e := r.end
	verts.append_array(PackedVector2Array([a, b, e, a, e, d]))
	for _k in 6:
		cols.append(c)


func _draw_trails() -> void:
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	# Two passes: soft glow first, then the bright core on top.
	for pass_i in 2:
		var w: float = TRAIL_W + 12.0 if pass_i == 0 else TRAIL_W
		var hw: float = w * 0.5
		for y in ROWS:
			for x in COLS:
				var v: int = grid[y * COLS + x]
				var own: int = v & 7
				if own == 0 or (v & RESERVED) != 0:
					continue
				var col: Color = GameManager.COLORS[clampi(own - 1, 0, 4)]
				col = Color(col, 0.22) if pass_i == 0 else col.lightened(0.15)
				var c := _center(Vector2i(x, y))
				_quad(verts, cols, Rect2(c - Vector2(hw, hw), Vector2(w, w)), col)
				# Joins to the right / down neighbour (left / up are drawn by that neighbour)
				if (v & _bit(0)) != 0 and x + 1 < COLS and (grid[y * COLS + x + 1] & RESERVED) == 0:
					_quad(verts, cols, Rect2(c + Vector2(hw, -hw), Vector2(CELL - w, w)), col)
				if (v & _bit(1)) != 0 and y + 1 < ROWS and (grid[(y + 1) * COLS + x] & RESERVED) == 0:
					_quad(verts, cols, Rect2(c + Vector2(-hw, hw), Vector2(w, CELL - w)), col)
		if pass_i == 1:
			# White-hot centre line
			for y in ROWS:
				for x in COLS:
					var v2: int = grid[y * COLS + x]
					if (v2 & 7) == 0 or (v2 & RESERVED) != 0:
						continue
					var c2 := _center(Vector2i(x, y))
					var core := Color(1, 1, 1, 0.55)
					_quad(verts, cols, Rect2(c2 - Vector2(2, 2), Vector2(4, 4)), core)
					if (v2 & _bit(0)) != 0 and x + 1 < COLS and (grid[y * COLS + x + 1] & RESERVED) == 0:
						_quad(verts, cols, Rect2(c2 + Vector2(2, -2), Vector2(CELL - 4, 4)), core)
					if (v2 & _bit(1)) != 0 and y + 1 < ROWS and (grid[(y + 1) * COLS + x] & RESERVED) == 0:
						_quad(verts, cols, Rect2(c2 + Vector2(-2, 2), Vector2(4, CELL - 4)), core)
	if _mesh == null:
		_mesh = ArrayMesh.new()
	_mesh.clear_surfaces()
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	trails.draw_mesh(_mesh, null)


## Snap a coordinate back to the cell centre behind the rider (along its direction).
func _back_center(coord: float, origin: float, dir_sign: float) -> float:
	var t: float = (coord - origin) / CELL - 0.5
	var k: float = floorf(t + 0.001) if dir_sign > 0.0 else ceilf(t - 0.001)
	return origin + (k + 0.5) * CELL


func _draw_heads() -> void:
	var n := heads_node
	for id in player_order:
		var p = players[id]
		if p.is_eliminated:
			continue
		var col: Color = p.player_color
		var pos: Vector2 = p.position
		var f: Vector2 = p.facing
		if absf(f.x) > absf(f.y):
			f = Vector2(signf(f.x), 0.0)
		else:
			f = Vector2(0.0, signf(f.y) if f.y != 0.0 else 1.0)
		# Trail piece from the last cell centre up to the rider
		var back := pos
		if f.x != 0.0:
			back.x = _back_center(pos.x, ORIGIN.x, f.x)
		else:
			back.y = _back_center(pos.y, ORIGIN.y, f.y)
		if state != "intro" and back.distance_to(pos) > 0.5:
			var hw := TRAIL_W * 0.5
			var r := Rect2(back, Vector2.ZERO).expand(pos)
			n.draw_rect(r.grow(hw + 6.0), Color(col, 0.22))
			n.draw_rect(r.grow(hw), col.lightened(0.15))
			n.draw_rect(r.grow(2.0), Color(1, 1, 1, 0.55))
		# The light cycle: glowing arrow head
		var side := Vector2(-f.y, f.x)
		var boosting: bool = float(p.boost_timer) > 0.0
		var glow_r: float = 18.0 + (5.0 if boosting else 0.0) + sin(_t * 10.0) * 2.0
		n.draw_circle(pos, glow_r, Color(col, 0.25))
		var tip := pos + f * 17.0
		var wing_l := pos + side * 11.0 - f * 7.0
		var wing_r := pos - side * 11.0 - f * 7.0
		var body := PackedVector2Array([tip, wing_l, pos - f * 2.0, wing_r])
		n.draw_colored_polygon(body, col.lightened(0.1))
		n.draw_polyline(PackedVector2Array([tip, wing_l, pos - f * 2.0, wing_r, tip]), Color.WHITE, 2.5, true)
		n.draw_circle(pos + f * 4.0, 4.0, Color.WHITE)
		if boosting:
			for k in 3:
				var off: float = float(k + 1) * 9.0
				n.draw_line(pos - f * (10.0 + off) + side * 8.0, pos - f * (16.0 + off) + side * 8.0, Color(1, 1, 1, 0.7), 2.0)
				n.draw_line(pos - f * (10.0 + off) - side * 8.0, pos - f * (16.0 + off) - side * 8.0, Color(1, 1, 1, 0.7), 2.0)
