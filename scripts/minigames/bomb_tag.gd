extends "res://scripts/minigames/minigame_base.gd"
## BOMB TAG (maze edition)
## - A maze with loops and dead ends. Touch a rival to pass the bomb.
## - The bomb holder is faster and dashes more often.
## - NO TAG-BACKS: after you pass the bomb you can't receive it again for a few seconds,
##   so the new holder has to hunt someone else.
## - Power-ups: FREEZE (freeze everyone else), TIME (+3s if you hold the bomb, -2s if you don't),
##   SPEED (run faster), SHIELD (the bomb can't be passed to you). Dead ends hide the best loot.

const COLS := 15
const ROWS := 8
const CELL := 64.0
const ARENA := Rect2(160, 104, 960, 512)
## Pac-Man style: every corridor loops, no dead ends, and the middle row has
## warp tunnels at both sides (run off the left edge, come out on the right).
const MAZE := [
	"...............",
	".###.##.##.###.",
	"...............",
	"#.##.##.##.##.#",
	"...............",
	".##..#...#..##.",
	".##..#...#..##.",
	"...............",
]
const WARP_ROW := 4
const WALL_T := 40.0
const TUNNEL_LEN := 80.0
const WARP_AT := 26.0     # how far past the edge before you pop out the other side
const WALL_H := 24.0
const BLOCK_H := 24.0
const BLOCK_INSET := 3.0

const FUSE_TIME := 12.0
const FUSE_MAX := 18.0
const RESPAWN_DELAY := 1.5
const PASS_DIST := 54.0
const PASS_COOLDOWN := 0.5
const TAGBACK_TIME := 3.0
const HOLDER_SPEED_MULT := 1.22
const HOLDER_DASH_CD := 0.7
const NORMAL_DASH_CD := 1.2

const PU_TYPES := ["freeze", "time", "speed", "shield"]
const PU_COLORS := [Color("#7FDBFF"), Color("#2ECC71"), Color("#FEE440"), Color("#B388FF")]
const PU_NAMES := ["FREEZE", "TIME", "SPEED", "SHIELD"]
const PU_SPAWN_EVERY := 4.5
const PU_MAX := 3
const PU_PICK_DIST := 36.0
const FREEZE_TIME := 1.6
const SPEED_TIME := 3.5
const SHIELD_TIME := 4.0

var holder_id: int = 0
var fuse: float = FUSE_TIME
var next_bomb_in: float = 0.0
var pass_cooldown: float = 0.0
var pu_timer: float = 2.5
var powerups: Array = []           # [uid, type, cell_x, cell_y]
var _pu_uid: int = 0
var _last_fuse_sec: int = -1
var _tick_sec: int = -1
var _last_holder_seen: int = 0

var open_cells: PackedByteArray = PackedByteArray()
var dead_ends: Array = []
var floor_node: Node2D
var floor_fx: Node2D
var pu_node: Node2D
var pu_labels: Node2D
var _t: float = 0.0


func _init() -> void:
	game_id = "bomb_tag"
	game_title = "BOMB TAG"
	instruction = "PASS THE BOMB! NO TAG-BACKS!"
	duration = 90.0
	knock_strength = 300.0
	elim_style = "explode"
	camera_center = Vector2(640, 372)
	camera_zoom = 0.9


# ---------------------------------------------------------------- maze

func _is_open(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < COLS and c.y < ROWS and open_cells[c.y * COLS + c.x] == 1


func cell_of(pos: Vector2) -> Vector2i:
	var c := Vector2i(floori((pos.x - ARENA.position.x) / CELL), floori((pos.y - ARENA.position.y) / CELL))
	return Vector2i(clampi(c.x, 0, COLS - 1), clampi(c.y, 0, ROWS - 1))


func cell_center(c: Vector2i) -> Vector2:
	return ARENA.position + Vector2((float(c.x) + 0.5) * CELL, (float(c.y) + 0.5) * CELL)


func _neighbors(c: Vector2i) -> Array:
	var out: Array = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = c + d
		if _is_open(n):
			out.append(n)
	# Warp tunnel
	if c.y == WARP_ROW and c.x == 0:
		out.append(Vector2i(COLS - 1, WARP_ROW))
	elif c.y == WARP_ROW and c.x == COLS - 1:
		out.append(Vector2i(0, WARP_ROW))
	return out


## Open in direction d from cell c (counts the warp tunnels as open).
func _open_dir(c: Vector2i, d: Vector2i) -> bool:
	if c.y == WARP_ROW and ((c.x == 0 and d.x < 0) or (c.x == COLS - 1 and d.x > 0)):
		return true
	return _is_open(c + d)


## Breadth-first distances (in cells) from `start` to every open cell. -1 = unreachable.
func bfs(start: Vector2i) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(COLS * ROWS)
	dist.fill(-1)
	if not _is_open(start):
		start = _nearest_open(start)
	dist[start.y * COLS + start.x] = 0
	var q: Array = [start]
	var head := 0
	while head < q.size():
		var c: Vector2i = q[head]
		head += 1
		var dc: int = dist[c.y * COLS + c.x]
		for n in _neighbors(c):
			var ni: int = n.y * COLS + n.x
			if dist[ni] == -1:
				dist[ni] = dc + 1
				q.append(n)
	return dist


func _nearest_open(c: Vector2i) -> Vector2i:
	var best := Vector2i(0, 0)
	var bd := INF
	for y in ROWS:
		for x in COLS:
			var v := Vector2i(x, y)
			if _is_open(v):
				var d: float = Vector2(v - c).length()
				if d < bd:
					bd = d
					best = v
	return best


func build_arena() -> void:
	open_cells.resize(COLS * ROWS)
	for y in ROWS:
		var row: String = MAZE[y]
		for x in COLS:
			open_cells[y * COLS + x] = 1 if row[x] == "." else 0
	for y in ROWS:
		for x in COLS:
			var c := Vector2i(x, y)
			if _is_open(c) and _neighbors(c).size() == 1:
				dead_ends.append(c)

	floor_node = Node2D.new()
	floor_node.name = "ArenaFloor"
	floor_layer.add_child(floor_node)
	floor_node.draw.connect(_draw_floor)

	floor_fx = Node2D.new()
	floor_fx.name = "FloorFX"
	floor_layer.add_child(floor_fx)
	floor_fx.draw.connect(_draw_floor_fx)

	pu_node = Node2D.new()
	pu_node.name = "PowerUps"
	floor_layer.add_child(pu_node)
	pu_node.draw.connect(_draw_powerups)
	pu_labels = Node2D.new()
	pu_labels.name = "PowerUpLabels"
	fx_layer.add_child(pu_labels)
	pu_labels.draw.connect(_draw_pu_labels)

	# Outer walls (collision)
	add_wall(Rect2(ARENA.position.x - WALL_T, ARENA.position.y - WALL_T, ARENA.size.x + WALL_T * 2.0, WALL_T))
	add_wall(Rect2(ARENA.position.x - WALL_T, ARENA.end.y, ARENA.size.x + WALL_T * 2.0, WALL_T))
	# Side walls with a gap for the warp tunnel, plus tunnel walls and an end cap.
	var ty: float = ARENA.position.y + float(WARP_ROW) * CELL
	for side in [-1, 1]:
		var x0: float = ARENA.position.x - WALL_T if side < 0 else ARENA.end.x
		add_wall(Rect2(x0, ARENA.position.y, WALL_T, ty - ARENA.position.y))
		add_wall(Rect2(x0, ty + CELL, WALL_T, ARENA.end.y - ty - CELL))
		var tx: float = ARENA.position.x - TUNNEL_LEN if side < 0 else ARENA.end.x
		add_wall(Rect2(tx, ty - 20.0, TUNNEL_LEN, 20.0))
		add_wall(Rect2(tx, ty + CELL, TUNNEL_LEN, 20.0))
		var cap_x: float = ARENA.position.x - TUNNEL_LEN - 20.0 if side < 0 else ARENA.end.x + TUNNEL_LEN
		add_wall(Rect2(cap_x, ty - 20.0, 20.0, CELL + 40.0))
	var front := Node2D.new()
	front.name = "FrontWall"
	front.position = Vector2(0, ARENA.end.y + WALL_T)
	front.draw.connect(_draw_front_wall.bind(front))
	world.add_child(front)

	# Maze blocks: merge horizontal runs into one block each
	for y in ROWS:
		var x := 0
		while x < COLS:
			if _is_open(Vector2i(x, y)):
				x += 1
				continue
			var start := x
			while x < COLS and not _is_open(Vector2i(x, y)):
				x += 1
			var rect := Rect2(ARENA.position + Vector2(float(start) * CELL, float(y) * CELL), Vector2(float(x - start) * CELL, CELL))
			add_wall(rect.grow(-BLOCK_INSET))
			var bv := Node2D.new()
			bv.name = "Block"
			bv.position = Vector2(rect.position.x, rect.end.y)
			bv.draw.connect(_draw_block.bind(bv, rect.size))
			world.add_child(bv)


func get_spawn_points() -> Array:
	return [cell_center(Vector2i(0, 0)), cell_center(Vector2i(14, 0)), cell_center(Vector2i(14, 7)), cell_center(Vector2i(0, 7)), cell_center(Vector2i(7, 4))]


## Cornering help for human players (keyboard or joystick):
## - moving along a corridor nudges you to its centre so you don't snag on block corners
## - pressing toward a wall next to an opening slides you over to the opening
func filter_human_input(p, mv: Vector2) -> Vector2:
	if mv.length() < 0.3:
		return mv
	# Joystick pushes that are close to straight up/down/left/right snap to that direction,
	# so you run cleanly down corridors (true diagonals still work).
	var ang: float = mv.angle()
	var snapped_ang: float = snappedf(ang, PI * 0.5)
	if absf(angle_difference(ang, snapped_ang)) < deg_to_rad(27.0):
		mv = Vector2.from_angle(snapped_ang) * mv.length()
	var pos: Vector2 = p.position
	var c := cell_of(pos)
	var center := cell_center(c)
	var horiz: bool = absf(mv.x) >= absf(mv.y)
	var main_dir := Vector2i(int(signf(mv.x)), 0) if horiz else Vector2i(0, int(signf(mv.y)))
	var side_off: float = (pos.y - center.y) if horiz else (pos.x - center.x)
	var out := mv
	if _open_dir(c, main_dir):
		# Open ahead: line up with the lane (unless the player is clearly steering diagonally).
		var cross: float = absf(mv.y) if horiz else absf(mv.x)
		if cross < 0.5 and absf(side_off) > 2.0:
			var fix: float = clampf(-side_off / 12.0, -1.0, 1.0) * 0.9
			if horiz:
				out.y = fix
			else:
				out.x = fix
	else:
		# Blocked ahead: if the neighbour cell we're drifting toward has an opening, slide to it.
		var side_dir := Vector2i(0, int(signf(side_off))) if horiz else Vector2i(int(signf(side_off)), 0)
		if side_dir != Vector2i.ZERO and _is_open(c + side_dir) and _is_open(c + side_dir + main_dir) and absf(side_off) > 6.0:
			if horiz:
				out = Vector2(mv.x * 0.3, signf(side_off))
			else:
				out = Vector2(signf(side_off), mv.y * 0.3)
	return out.limit_length(1.0)


func configure_player(p) -> void:
	p.dash_cooldown_time = NORMAL_DASH_CD


# ---------------------------------------------------------------- host logic

func on_game_start() -> void:
	_give_bomb_random()


func game_step(delta: float) -> void:
	pass_cooldown = maxf(pass_cooldown - delta, 0.0)
	_do_warps()
	_update_powerups(delta)
	if holder_id == 0:
		if alive_count() > 1:
			next_bomb_in -= delta
			if next_bomb_in <= 0.0:
				_give_bomb_random()
		return
	var holder = players.get(holder_id)
	if holder == null or holder.is_eliminated:
		holder_id = 0
		next_bomb_in = RESPAWN_DELAY
		return
	fuse = maxf(fuse - delta, 0.0)
	holder.bomb_fuse = fuse
	if fuse <= 0.0 or time_left <= 0.0:
		_explode(holder)
		return
	if pass_cooldown <= 0.0:
		for p in alive_players():
			if p == holder or not can_receive(p):
				continue
			if p.position.distance_to(holder.position) <= PASS_DIST:
				_pass_bomb(holder, p)
				break


func _do_warps() -> void:
	for p in alive_players():
		var x: float = p.position.x
		if x < ARENA.position.x - WARP_AT:
			p.position.x = ARENA.end.x + WARP_AT - 8.0
			p.position.y = cell_center(Vector2i(0, WARP_ROW)).y
			push_event(p.position + Vector2(-30, -50), "WARP!", Color("#00F5D4"))
		elif x > ARENA.end.x + WARP_AT:
			p.position.x = ARENA.position.x - WARP_AT + 8.0
			p.position.y = cell_center(Vector2i(0, WARP_ROW)).y
			push_event(p.position + Vector2(30, -50), "WARP!", Color("#00F5D4"))


func can_receive(p) -> bool:
	return not p.is_eliminated and p.tagback_timer <= 0.0 and p.shield_timer <= 0.0


func _set_holder(p) -> void:
	var old = players.get(holder_id)
	if old != null:
		old.has_bomb = false
		old.speed_mult = 1.0
		old.dash_cooldown_time = NORMAL_DASH_CD
	p.has_bomb = true
	p.speed_mult = HOLDER_SPEED_MULT
	p.dash_cooldown_time = HOLDER_DASH_CD
	p.dash_cooldown = minf(float(p.dash_cooldown), HOLDER_DASH_CD)
	p.bomb_fuse = fuse
	holder_id = int(p.peer_id)


func _pass_bomb(from, to) -> void:
	_set_holder(to)
	from.tagback_timer = TAGBACK_TIME
	pass_cooldown = PASS_COOLDOWN
	# Little shove apart so it reads as a "tag"
	var n: Vector2 = (to.position - from.position).normalized()
	to.knockback_vel += n * 220.0
	from.knockback_vel -= n * 160.0
	push_event((from.position + to.position) * 0.5 + Vector2(0, -50), "TAG!", Color("#FF4D6D"))


func _give_bomb_random() -> void:
	var alive := alive_players()
	if alive.size() < 2:
		return
	for p in alive:
		p.tagback_timer = 0.0
	fuse = FUSE_TIME
	holder_id = 0
	_set_holder(alive[randi() % alive.size()])
	pass_cooldown = 1.0


func _explode(holder) -> void:
	holder_id = 0
	holder.speed_mult = 1.0
	var hpos: Vector2 = holder.position
	eliminate_player(holder, "explode")
	next_bomb_in = RESPAWN_DELAY
	for other in alive_players():
		var off: Vector2 = other.position - hpos
		var d: float = off.length()
		if d < 170.0:
			var dir: Vector2 = off / d if d > 0.01 else Vector2.RIGHT
			other.knockback_vel += dir * 420.0 * (1.0 - d / 170.0 * 0.5)
			other.stun_timer = maxf(float(other.stun_timer), 0.3)


func _update_powerups(delta: float) -> void:
	pu_timer -= delta
	if pu_timer <= 0.0:
		pu_timer = PU_SPAWN_EVERY
		if powerups.size() < PU_MAX:
			_spawn_powerup()
	for i in range(powerups.size() - 1, -1, -1):
		var pu: Array = powerups[i]
		var pos := cell_center(Vector2i(int(pu[2]), int(pu[3])))
		for p in alive_players():
			if p.position.distance_to(pos) <= PU_PICK_DIST:
				powerups.remove_at(i)
				_apply_powerup(p, int(pu[1]), pos)
				break


func _spawn_powerup() -> void:
	var taken: Array = []
	for pu in powerups:
		taken.append(Vector2i(int(pu[2]), int(pu[3])))
	var candidates: Array = []
	var pool: Array = dead_ends if randf() < 0.55 else []
	if pool.is_empty():
		for y in ROWS:
			for x in COLS:
				if _is_open(Vector2i(x, y)):
					pool.append(Vector2i(x, y))
	for c in pool:
		if taken.has(c):
			continue
		var near := false
		for p in alive_players():
			if Vector2(cell_of(p.position)).distance_to(Vector2(c)) < 2.5:
				near = true
				break
		if not near:
			candidates.append(c)
	if candidates.is_empty():
		return
	var cell: Vector2i = candidates[randi() % candidates.size()]
	var typ: int = randi() % PU_TYPES.size()
	_pu_uid += 1
	powerups.append([_pu_uid, typ, cell.x, cell.y])


func _apply_powerup(p, typ: int, pos: Vector2) -> void:
	var col: Color = PU_COLORS[typ]
	match PU_TYPES[typ]:
		"freeze":
			for o in alive_players():
				if o != p:
					o.freeze_timer = FREEZE_TIME
					o.move_vel = Vector2.ZERO
			push_event(pos + Vector2(0, -40), "FREEZE!", col)
		"time":
			var holder = players.get(holder_id)
			if holder != null and holder == p:
				fuse = minf(fuse + 3.0, FUSE_MAX)
				push_event(pos + Vector2(0, -40), "BOMB +3s", col)
			elif holder != null:
				fuse = maxf(fuse - 2.0, 1.5)
				push_event(pos + Vector2(0, -40), "BOMB -2s!", Color("#FF9F1C"))
			else:
				push_event(pos + Vector2(0, -40), "TIME", col)
		"speed":
			p.boost_timer = SPEED_TIME
			push_event(pos + Vector2(0, -40), "SPEED!", col)
		"shield":
			p.shield_timer = SHIELD_TIME
			push_event(pos + Vector2(0, -40), "SHIELD!", col)


func should_end() -> bool:
	if alive_count() <= 1:
		return true
	return time_left <= 0.0 and holder_id == 0


# ---------------------------------------------------------------- bot AI

func get_bot_command(p, delta: float) -> Dictionary:
	var brain: Dictionary = p.bot_brain
	var my_cell := cell_of(p.position)
	var dm := bfs(my_cell)
	var holder = players.get(holder_id)
	if holder != null and holder.is_eliminated:
		holder = null

	if p.has_bomb:
		# HUNT: nearest rival (by maze distance) who can receive the bomb.
		var best = null
		var best_d := 9999
		for o in alive_players():
			if o == p or not can_receive(o):
				continue
			var d: int = dm[cell_of(o.position).y * COLS + cell_of(o.position).x]
			if d >= 0 and d < best_d:
				best_d = d
				best = o
		if best == null:
			best = nearest_alive_other(p)
		# Grab a power-up on the way if it's very close and there's time.
		var pu_cell := _close_powerup(dm, 2, ["freeze", "speed", "time"])
		if pu_cell != Vector2i(-1, -1) and fuse > 3.0:
			return {"move": _follow(p, pu_cell, cell_center(pu_cell)), "act": false}
		if best == null:
			return {"move": Vector2.ZERO, "act": false}
		var tpos: Vector2 = best.position
		var mv := _follow(p, cell_of(tpos), tpos)
		var close: bool = p.position.distance_to(tpos) < 120.0 and mv.dot((tpos - p.position).normalized()) > 0.7
		return {"move": mv, "act": close and float(p.dash_cooldown) <= 0.0}

	if holder == null:
		# Between bombs: collect power-ups, otherwise drift to a personal spot.
		var pc := _close_powerup(dm, 6, PU_TYPES)
		if pc != Vector2i(-1, -1):
			return {"move": _follow(p, pc, cell_center(pc)), "act": false}
		var home := Vector2i(3 + (int(p.slot) % 2) * 8, 2 + (int(p.slot) >> 1) * 3)
		if not _is_open(home):
			home = _nearest_open(home)
		return {"move": _follow(p, home, cell_center(home)) * 0.6, "act": false}

	# FLEE: pick a reachable cell that is far from the holder (re-planned a few times a second).
	var safe: bool = p.tagback_timer > 0.5 or p.shield_timer > 0.5
	var dh := bfs(cell_of(holder.position))
	var plan_t: float = float(brain.get("plan_t", 0.0)) - delta
	var goal: Vector2i = brain.get("goal", my_cell)
	var dist_h: float = p.position.distance_to(holder.position)
	if plan_t <= 0.0 or not _is_open(goal):
		plan_t = randf_range(0.3, 0.5)
		goal = my_cell
		var best_score := -INF
		for y in ROWS:
			for x in COLS:
				var c := Vector2i(x, y)
				var i: int = y * COLS + x
				if dm[i] < 0 or dm[i] > 7:
					continue
				var score: float = float(dh[i]) * 1.0 - float(dm[i]) * 0.35
				if dh[i] <= dm[i] and not safe:
					score -= 4.0          # holder gets there first
				if dead_ends.has(c):
					score -= 2.5          # don't get cornered
				for pu in powerups:
					if int(pu[2]) == x and int(pu[3]) == y:
						score += 3.0 if not safe else 5.0
				score += randf() * 0.6
				if score > best_score:
					best_score = score
					goal = c
	brain["plan_t"] = plan_t
	brain["goal"] = goal
	var mv2 := _follow(p, goal, cell_center(goal))
	var urgency: float = 1.0 if (dist_h < 330.0 and not safe) else 0.75
	var act2: bool = dist_h < 100.0 and not safe and float(p.dash_cooldown) <= 0.0 and mv2.dot((p.position - holder.position).normalized()) > 0.3
	return {"move": mv2 * urgency, "act": act2}


## Steer one step along the shortest maze path toward `goal` (final approach to `goal_pos`).
func _follow(p, goal: Vector2i, goal_pos: Vector2) -> Vector2:
	var here := cell_of(p.position)
	if here == goal:
		var d: Vector2 = goal_pos - p.position
		return d.normalized() if d.length() > 6.0 else Vector2.ZERO
	var dg := bfs(goal)
	var cur: int = dg[here.y * COLS + here.x]
	var next := here
	for n in _neighbors(here):
		var dn: int = dg[n.y * COLS + n.x]
		if dn >= 0 and (cur < 0 or dn < cur):
			cur = dn
			next = n
	var target: Vector2 = cell_center(next)
	if absi(next.x - here.x) > 1:
		# Going through the warp tunnel: keep running toward the edge.
		var dir_x: float = -1.0 if here.x == 0 else 1.0
		return Vector2(dir_x, clampf((cell_center(here).y - p.position.y) / 20.0, -1.0, 1.0)).normalized()
	var v: Vector2 = target - p.position
	return v.normalized() if v.length() > 1.0 else Vector2.ZERO


func _close_powerup(dm: PackedInt32Array, max_steps: int, wanted: Array) -> Vector2i:
	var best := Vector2i(-1, -1)
	var bd := max_steps + 1
	for pu in powerups:
		if not wanted.has(PU_TYPES[int(pu[1])]):
			continue
		var i: int = int(pu[3]) * COLS + int(pu[2])
		if dm[i] >= 0 and dm[i] < bd:
			bd = dm[i]
			best = Vector2i(int(pu[2]), int(pu[3]))
	return best


# ---------------------------------------------------------------- network + HUD

func stat_text(id: int) -> String:
	var p = players[id]
	if p.is_eliminated:
		return "BOOM"
	if p.has_bomb:
		return "BOMB!"
	if p.freeze_timer > 0.0:
		return "FROZEN"
	if p.shield_timer > 0.0:
		return "SHIELD"
	if p.tagback_timer > 0.0:
		return "SAFE*"
	return "run!"


func finish_text() -> String:
	var w := winner_names(compute_rank_groups())
	if w.size() == 1:
		return "%s SURVIVES!" % str(w[0])
	if w.size() > 1:
		return "TIE! " + " & ".join(PackedStringArray(w))
	return "TIME!"


func get_extra_state() -> Dictionary:
	return {"h": holder_id, "f": fuse, "pu": powerups}


func apply_extra_state(m: Dictionary) -> void:
	holder_id = int(m.get("h", holder_id))
	fuse = float(m.get("f", fuse))
	powerups = m.get("pu", powerups)
	var holder = players.get(holder_id)
	if holder != null:
		holder.bomb_fuse = fuse


func client_process(delta: float) -> void:
	_t += delta
	if holder_id != _last_holder_seen:
		var holder = players.get(holder_id)
		if holder != null and not holder.is_eliminated:
			spawn_burst(holder.position + Vector2(0, -50), Color("#FF4D6D"), 16, 220.0, 7.0, 0.4)
			spawn_ring(holder.position + Vector2(0, -12), Color("#FF4D6D"), 70.0, 0.3)
			if holder_id == GameManager.my_id():
				hud.show_center("YOU HAVE THE BOMB!", Color("#FF4D6D"), 0.6)
		_last_holder_seen = holder_id
	# Bomb fuse ticks every second (louder and higher in the last 5).
	var hb = players.get(holder_id)
	if hb != null and not hb.is_eliminated and state == "running":
		var ts: int = ceili(fuse)
		if ts != _tick_sec:
			_tick_sec = ts
			if ts <= 5:
				Sfx.play("tick_hi", -1.0)
			else:
				Sfx.play("tick", -9.0)
	else:
		_tick_sec = -1
	# Last 5 seconds of the fuse: pulse every second, and flash the holder's screen red.
	var holder2 = players.get(holder_id)
	if holder2 != null and not holder2.is_eliminated and fuse <= 5.0 and state == "running":
		var sec: int = ceili(fuse)
		if sec != _last_fuse_sec:
			_last_fuse_sec = sec
			holder2.pulse_bomb()
			if holder_id == GameManager.my_id():
				hud.flash(Color(1.0, 0.1, 0.1, 0.22))
			add_shake(1.5 + (5.0 - fuse) * 0.6)
	else:
		_last_fuse_sec = -1
	var me = players.get(GameManager.my_id())
	if me != null and me.has_bomb:
		hud.set_action("DASH!", Color("#FF4D6D"))
	else:
		hud.set_action("DASH", Color("#FF9F1C"))
	floor_fx.queue_redraw()
	pu_node.queue_redraw()
	pu_labels.queue_redraw()


# ---------------------------------------------------------------- drawing (pseudo-3D)

func _draw_floor() -> void:
	var f := floor_node
	f.draw_rect(Rect2(-1400, -1000, 4080, 2720), Color("#0b0a18"))
	var outer := ARENA.grow(WALL_T)
	f.draw_rect(Rect2(outer.position + Vector2(14, 22), outer.size), Color(0, 0, 0, 0.5))
	for y in ROWS:
		for x in COLS:
			var r := Rect2(ARENA.position + Vector2(float(x) * CELL, float(y) * CELL), Vector2(CELL, CELL))
			var c := Color("#272044") if (x + y) % 2 == 0 else Color("#2e2752")
			f.draw_rect(r, c)
	# Block shadows on the floor
	for y in ROWS:
		for x in COLS:
			if not _is_open(Vector2i(x, y)):
				var r2 := Rect2(ARENA.position + Vector2(float(x) * CELL, float(y) * CELL), Vector2(CELL, CELL))
				f.draw_rect(Rect2(r2.position + Vector2(12, 10), r2.size), Color(0, 0, 0, 0.28))
	var top_c := Color("#3a4a8c")
	var front_c := Color("#1f2853")
	UI.draw_block(f, Rect2(ARENA.position.x - WALL_T, ARENA.position.y - WALL_T, ARENA.size.x + WALL_T * 2.0, WALL_T), WALL_H, top_c, front_c)
	var ty: float = ARENA.position.y + float(WARP_ROW) * CELL
	for side in [-1, 1]:
		var x0: float = ARENA.position.x - WALL_T if side < 0 else ARENA.end.x
		var tx: float = ARENA.position.x - TUNNEL_LEN if side < 0 else ARENA.end.x
		# Tunnel floor with glowing chevrons
		f.draw_rect(Rect2(tx, ty, TUNNEL_LEN, CELL), Color("#1b2550"))
		UI.draw_block(f, Rect2(x0, ARENA.position.y, WALL_T, ty - ARENA.position.y), WALL_H, top_c, front_c)
		UI.draw_block(f, Rect2(x0, ty + CELL, WALL_T, ARENA.end.y - ty - CELL), WALL_H, top_c, front_c)
		UI.draw_block(f, Rect2(tx, ty - 20.0, TUNNEL_LEN, 20.0), WALL_H * 0.6, top_c, front_c)
		UI.draw_block(f, Rect2(tx, ty + CELL, TUNNEL_LEN, 20.0), WALL_H * 0.6, top_c, front_c)
	f.draw_line(Vector2(ARENA.position.x, ARENA.position.y - 1), Vector2(ARENA.end.x, ARENA.position.y - 1), Color(0.0, 0.96, 0.83, 0.5), 3.0)


## Only the parts that move (drawn every frame; the floor above is drawn once).
func _draw_floor_fx() -> void:
	var f := floor_fx
	var holder = players.get(holder_id)
	if holder != null and not holder.is_eliminated:
		var pulse: float = 0.5 + 0.5 * sin(_t * (8.0 + (FUSE_TIME - minf(fuse, FUSE_TIME)) * 3.0))
		var hp: Vector2 = holder.position
		f.draw_colored_polygon(UI.ellipse_points(hp + Vector2(0, 4), 46 + pulse * 10.0, 20 + pulse * 4.0, 28), Color(1.0, 0.2, 0.15, 0.18 + pulse * 0.2))
	var ty: float = ARENA.position.y + float(WARP_ROW) * CELL
	var p2: float = 0.5 + 0.5 * sin(_t * 5.0)
	for side in [-1, 1]:
		var tx: float = ARENA.position.x - TUNNEL_LEN if side < 0 else ARENA.end.x
		for k in 3:
			var cx: float = tx + TUNNEL_LEN * (0.2 + 0.3 * float(k))
			var cy: float = ty + CELL * 0.5
			var dx: float = -10.0 if side < 0 else 10.0
			f.draw_polyline(PackedVector2Array([Vector2(cx - dx, cy - 12), Vector2(cx + dx, cy), Vector2(cx - dx, cy + 12)]), Color(0.0, 0.96, 0.83, 0.3 + 0.5 * p2 * (float(k + 1) / 3.0)), 4.0, true)


func _draw_front_wall(n: Node2D) -> void:
	var fp := Rect2(ARENA.position.x - WALL_T, -WALL_T, ARENA.size.x + WALL_T * 2.0, WALL_T)
	UI.draw_block(n, fp, WALL_H, Color("#3a4a8c"), Color("#1f2853"))
	n.draw_line(Vector2(ARENA.position.x, -WALL_T - WALL_H + 1), Vector2(ARENA.end.x, -WALL_T - WALL_H + 1), Color(0.0, 0.96, 0.83, 0.5), 3.0)


func _draw_block(n: Node2D, sz: Vector2) -> void:
	# Local origin = bottom-left of the block footprint (so y-sorting works).
	var fp := Rect2(0, -sz.y, sz.x, sz.y)
	UI.draw_block(n, fp, BLOCK_H, Color("#6c5ce7"), Color("#3a2c9e"))
	var top := Rect2(fp.position - Vector2(0, BLOCK_H), fp.size)
	n.draw_line(top.position + Vector2(4, 4), Vector2(top.end.x - 4, top.position.y + 4), Color(1, 1, 1, 0.25), 2.0)
	# Studs on top so long blocks read as separate tiles
	var count: int = int(sz.x / CELL)
	for i in count:
		var cpos := top.position + Vector2((float(i) + 0.5) * CELL, CELL * 0.5)
		n.draw_circle(cpos, 9.0, Color("#5546d0"))
		n.draw_circle(cpos + Vector2(-2, -2), 5.0, Color("#8b7ff0"))


func _draw_powerups() -> void:
	for pu in powerups:
		var typ: int = int(pu[1])
		var base := cell_center(Vector2i(int(pu[2]), int(pu[3])))
		var bob: float = sin(_t * 3.0 + float(pu[0])) * 4.0
		var c: Vector2 = base + Vector2(0, -20 + bob)
		var col: Color = PU_COLORS[typ]
		pu_node.draw_colored_polygon(UI.ellipse_points(base + Vector2(0, 6), 16.0 - bob * 0.5, 6.0, 18), Color(0, 0, 0, 0.35))
		pu_node.draw_circle(c, 22.0, Color(col, 0.25 + 0.1 * sin(_t * 5.0)))
		pu_node.draw_circle(c, 17.0, col.darkened(0.35))
		pu_node.draw_circle(c + Vector2(0, -1.5), 15.5, col)
		pu_node.draw_circle(c + Vector2(-5, -6), 4.0, Color(1, 1, 1, 0.5))
		_draw_pu_icon(PU_TYPES[typ], c)


## Power-up names, drawn on the top layer so maze blocks never hide them.
func _draw_pu_labels() -> void:
	var font: Font = UI.title_font()
	for pu in powerups:
		var typ: int = int(pu[1])
		var base := cell_center(Vector2i(int(pu[2]), int(pu[3])))
		var pu_name: String = PU_NAMES[typ]
		var at := base + Vector2(-45, -44)
		pu_labels.draw_string_outline(font, at, pu_name, HORIZONTAL_ALIGNMENT_CENTER, 90, 14, 5, Color(0, 0, 0, 0.85))
		pu_labels.draw_string(font, at, pu_name, HORIZONTAL_ALIGNMENT_CENTER, 90, 14, PU_COLORS[typ].lightened(0.3))


func _draw_pu_icon(kind: String, c: Vector2) -> void:
	var w := Color.WHITE
	var dk := Color(0.1, 0.1, 0.18)
	match kind:
		"freeze":
			for i in 3:
				var d := Vector2.from_angle(float(i) * PI / 3.0) * 10.0
				pu_node.draw_line(c - d, c + d, w, 2.5)
				var e := d.normalized()
				var s := Vector2(-e.y, e.x) * 3.5
				pu_node.draw_line(c + d * 0.65 + s, c + d, w, 2.0)
				pu_node.draw_line(c + d * 0.65 - s, c + d, w, 2.0)
				pu_node.draw_line(c - d * 0.65 + s, c - d, w, 2.0)
				pu_node.draw_line(c - d * 0.65 - s, c - d, w, 2.0)
		"time":
			pu_node.draw_circle(c, 10.0, w)
			pu_node.draw_arc(c, 10.0, 0.0, TAU, 20, dk, 2.0, true)
			pu_node.draw_line(c, c + Vector2(0, -7), dk, 2.5)
			pu_node.draw_line(c, c + Vector2(5, 2), dk, 2.5)
		"speed":
			pu_node.draw_colored_polygon(PackedVector2Array([
				c + Vector2(3, -12), c + Vector2(-7, 2), c + Vector2(-1, 2),
				c + Vector2(-4, 12), c + Vector2(7, -3), c + Vector2(1, -3)]), dk)
		"shield":
			var pts := PackedVector2Array([
				c + Vector2(-9, -9), c + Vector2(9, -9), c + Vector2(9, 0),
				c + Vector2(0, 11), c + Vector2(-9, 0)])
			pu_node.draw_colored_polygon(pts, w)
			pu_node.draw_line(c + Vector2(0, -7), c + Vector2(0, 8), dk, 2.0)
