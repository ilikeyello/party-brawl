extends CharacterBody2D
## Universal party character used by every minigame.
## Host: simulates movement for everyone (humans via their sent input, bots via bot_think()).
## Clients: just smoothly follow the positions/flags the host sends.
## Looks "3D": floor shadow, shaded ball body raised off the ground, bobbing, depth scaling.

signal dash_started(player)

const UI := preload("res://scripts/ui_kit.gd")
const RADIUS := 24.0
const BASE_SPEED := 260.0
const DASH_SPEED := 650.0
const DASH_TIME := 0.18
const DASH_COOLDOWN := 1.2
const ACCEL := 1800.0
const FRICTION := 1500.0
const KNOCK_DECAY := 1400.0
const LIFT := 12.0

var peer_id: int = 0
var slot: int = 0
var is_bot: bool = false
var player_color: Color = Color.WHITE
var display_name: String = ""
var elim_style: String = "fall"

# Input (written by the host from network input or bot brain)
var move_input: Vector2 = Vector2.ZERO
var action_input: bool = false

# Tuning set per minigame
var speed_mult: float = 1.0
var dash_cooldown_time: float = DASH_COOLDOWN
var accel_mult: float = 1.0
var friction_mult: float = 1.0

# Simulation state
var move_vel: Vector2 = Vector2.ZERO
var knockback_vel: Vector2 = Vector2.ZERO
var is_dashing: bool = false
var dash_timer: float = 0.0
var dash_cooldown: float = 0.0
var dash_dir: Vector2 = Vector2.DOWN
var stun_timer: float = 0.0
var hit_immunity: float = 0.0
var is_eliminated: bool = false
var has_bomb: bool = false
var freeze_timer: float = 0.0      # frozen in ice: can't move
var shield_timer: float = 0.0      # bomb can't be passed to you
var boost_timer: float = 0.0       # speed boost
var tagback_timer: float = 0.0     # just passed the bomb: can't get it straight back
var bomb_fuse: float = 0.0
var facing: Vector2 = Vector2.DOWN
var bot_brain: Dictionary = {}

# Network smoothing (clients)
var net_pos: Vector2 = Vector2.ZERO
var net_vel: Vector2 = Vector2.ZERO

# Visual nodes
var shadow: Node2D
var visual: Node2D
var trail: CPUParticles2D
var name_label: Label
var bomb_label: Label
var _anim_t: float = 0.0
var _bob: float = 0.0
var _scorched: bool = false
var _bomb_pulse: float = 0.0


func setup(id: int, info: Dictionary, style: String) -> void:
	peer_id = id
	slot = int(info.get("slot", 0))
	is_bot = bool(info.get("is_bot", false))
	player_color = info.get("color", Color.WHITE)
	elim_style = style
	var nm: String = str(info.get("name", "P%d" % (slot + 1)))
	if is_bot and nm.begins_with("BOT"):
		display_name = nm
	else:
		display_name = "P%d %s" % [slot + 1, nm]
	_anim_t = randf() * 10.0


func _ready() -> void:
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	collision_layer = 2
	collision_mask = 1
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = RADIUS - 2.0
	cs.shape = circle
	add_child(cs)

	shadow = Node2D.new()
	shadow.name = "Shadow"
	add_child(shadow)
	shadow.draw.connect(_draw_shadow)

	trail = CPUParticles2D.new()
	trail.name = "DashTrail"
	trail.emitting = false
	trail.amount = 32
	trail.lifetime = 0.35
	trail.local_coords = false
	trail.gravity = Vector2.ZERO
	trail.spread = 180.0
	trail.initial_velocity_min = 10.0
	trail.initial_velocity_max = 45.0
	trail.scale_amount_min = 7.0
	trail.scale_amount_max = 13.0
	trail.position = Vector2(0, -LIFT)
	var grad := Gradient.new()
	grad.set_color(0, Color(player_color.lightened(0.3), 0.9))
	grad.set_color(1, Color(player_color, 0.0))
	trail.color_ramp = grad
	add_child(trail)

	visual = Node2D.new()
	visual.name = "Visual"
	add_child(visual)
	visual.draw.connect(_draw_body)

	name_label = Label.new()
	name_label.text = display_name
	name_label.label_settings = UI.label_settings(15, Color.WHITE, 5)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.size = Vector2(160, 22)
	name_label.position = Vector2(-80, -LIFT - RADIUS - 30)
	name_label.z_index = 20
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(name_label)

	bomb_label = Label.new()
	bomb_label.label_settings = UI.label_settings(28, Color("#FFD60A"), 7)
	bomb_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bomb_label.size = Vector2(80, 50)
	bomb_label.position = Vector2(-40, -LIFT - RADIUS - 96)
	bomb_label.z_index = 21
	bomb_label.visible = false
	bomb_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bomb_label)

	net_pos = position


# ---------------------------------------------------------------- host simulation

func server_step(delta: float) -> void:
	if is_eliminated:
		return
	dash_cooldown = maxf(dash_cooldown - delta, 0.0)
	stun_timer = maxf(stun_timer - delta, 0.0)
	hit_immunity = maxf(hit_immunity - delta, 0.0)
	freeze_timer = maxf(freeze_timer - delta, 0.0)
	shield_timer = maxf(shield_timer - delta, 0.0)
	boost_timer = maxf(boost_timer - delta, 0.0)
	tagback_timer = maxf(tagback_timer - delta, 0.0)
	var stunned := stun_timer > 0.0 or freeze_timer > 0.0
	var boost: float = 1.4 if boost_timer > 0.0 else 1.0
	var desired := Vector2.ZERO
	if stunned:
		is_dashing = false
	else:
		desired = move_input.limit_length(1.0) * BASE_SPEED * speed_mult * boost
	if move_input.length() > 0.2:
		facing = move_input.normalized()

	if action_input and not stunned and not is_dashing and dash_cooldown <= 0.0:
		_start_dash()

	if is_dashing:
		dash_timer -= delta
		move_vel = dash_dir * DASH_SPEED
		if dash_timer <= 0.0:
			is_dashing = false
			move_vel = dash_dir * BASE_SPEED * speed_mult
	else:
		var rate: float = ACCEL * accel_mult if desired != Vector2.ZERO else FRICTION * friction_mult
		move_vel = move_vel.move_toward(desired, rate * delta)

	knockback_vel = knockback_vel.move_toward(Vector2.ZERO, KNOCK_DECAY * friction_mult * delta)
	velocity = move_vel + knockback_vel
	move_and_slide()
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var n := col.get_normal()
		if knockback_vel.dot(n) < 0.0:
			knockback_vel = knockback_vel.bounce(n) * 0.6
		if move_vel.dot(n) < 0.0:
			move_vel = move_vel.slide(n)
		if is_dashing and dash_dir.dot(n) < 0.0:
			dash_dir = dash_dir.bounce(n)


func _start_dash() -> void:
	is_dashing = true
	dash_timer = DASH_TIME
	dash_cooldown = dash_cooldown_time
	if move_input.length() > 0.2:
		dash_dir = move_input.normalized()
	elif facing.length() > 0.1:
		dash_dir = facing.normalized()
	else:
		dash_dir = Vector2.DOWN
	dash_started.emit(self)


func bot_think(delta: float, minigame) -> void:
	var cmd: Dictionary = minigame.get_bot_command(self, delta)
	var target: Vector2 = cmd.get("move", Vector2.ZERO)
	move_input = move_input.lerp(target.limit_length(1.0), clampf(delta * 9.0, 0.0, 1.0))
	action_input = bool(cmd.get("act", false))


func get_net_flags() -> int:
	var f := 0
	if is_dashing:
		f |= 1
	if is_eliminated:
		f |= 2
	if has_bomb:
		f |= 4
	if stun_timer > 0.0:
		f |= 8
	if freeze_timer > 0.0:
		f |= 16
	if shield_timer > 0.0:
		f |= 32
	if boost_timer > 0.0:
		f |= 64
	if tagback_timer > 0.0:
		f |= 128
	return f


func set_eliminated(style: String) -> void:
	if is_eliminated:
		return
	is_eliminated = true
	has_bomb = false
	is_dashing = false
	move_vel = Vector2.ZERO
	knockback_vel = Vector2.ZERO
	velocity = Vector2.ZERO
	collision_layer = 0
	collision_mask = 0
	_play_elimination(style)


# ---------------------------------------------------------------- client sync

func apply_net(pos: Vector2, vel: Vector2, flags: int, cd: float) -> void:
	net_pos = pos
	net_vel = vel
	is_dashing = (flags & 1) != 0
	has_bomb = (flags & 4) != 0
	stun_timer = 1.0 if (flags & 8) != 0 else 0.0
	freeze_timer = 1.0 if (flags & 16) != 0 else 0.0
	shield_timer = 1.0 if (flags & 32) != 0 else 0.0
	boost_timer = 1.0 if (flags & 64) != 0 else 0.0
	tagback_timer = 1.0 if (flags & 128) != 0 else 0.0
	dash_cooldown = cd
	if (flags & 2) != 0 and not is_eliminated:
		position = pos
		set_eliminated(elim_style)


# ---------------------------------------------------------------- visuals

func _process(delta: float) -> void:
	_anim_t += delta
	var v: Vector2 = velocity
	if not GameManager.is_host():
		if not is_eliminated:
			if position.distance_to(net_pos) > 160.0:
				position = net_pos
			else:
				position = position.lerp(net_pos, clampf(delta * 16.0, 0.0, 1.0))
		v = net_vel
		if v.length() > 20.0:
			facing = facing.lerp(v.normalized(), clampf(delta * 12.0, 0.0, 1.0))
			if facing.length() < 0.1:
				facing = v.normalized()

	if is_eliminated:
		trail.emitting = false
		shadow.queue_redraw()
		return

	var speed := v.length()
	_bob = absf(sin(_anim_t * 14.0)) * 4.0 * clampf(speed / BASE_SPEED, 0.0, 1.0)
	trail.emitting = is_dashing or (boost_timer > 0.0 and speed > 60.0)

	# Perspective: things lower on screen are "closer" and slightly bigger.
	var depth_scale: float = lerpf(0.92, 1.06, clampf(position.y / 720.0, 0.0, 1.0))
	var squash := Vector2(1.12, 0.9) if is_dashing else Vector2.ONE
	visual.scale = squash * depth_scale
	shadow.scale = Vector2.ONE * depth_scale

	if freeze_timer > 0.0:
		visual.modulate = Color(0.65, 0.9, 1.4)
	elif stun_timer > 0.0:
		visual.modulate = Color(1, 1, 1, 0.35) if int(_anim_t * 20.0) % 2 == 0 else Color(1.6, 1.6, 1.6, 1.0)
	else:
		visual.modulate = Color.WHITE

	name_label.visible = not has_bomb
	bomb_label.visible = has_bomb
	_bomb_pulse = maxf(_bomb_pulse - delta * 2.5, 0.0)
	if has_bomb:
		bomb_label.text = str(ceili(maxf(bomb_fuse, 0.0)))
		var urgent := bomb_fuse <= 5.0
		bomb_label.label_settings.font_color = Color("#FF4D6D") if urgent else Color("#FFD60A")
		bomb_label.label_settings.font_size = 40 if urgent else 28
		bomb_label.pivot_offset = bomb_label.size * 0.5
	visual.queue_redraw()
	shadow.queue_redraw()


func _draw_shadow() -> void:
	if _scorched:
		shadow.draw_colored_polygon(UI.ellipse_points(Vector2(0, 4), 42, 18, 28), Color(0.05, 0.03, 0.03, 0.75))
		shadow.draw_colored_polygon(UI.ellipse_points(Vector2(0, 4), 26, 11, 24), Color(0.25, 0.08, 0.02, 0.8))
		return
	if is_eliminated:
		return
	var shrink: float = 1.0 - _bob * 0.03
	shadow.draw_colored_polygon(UI.ellipse_points(Vector2(0, 5), 23.0 * shrink, 9.0 * shrink, 24), Color(0, 0, 0, 0.38))


func _draw_body() -> void:
	var c := Vector2(0, -LIFT - _bob)
	if tagback_timer > 0.0:
		# Dashed ring = "can't get the bomb back yet"
		for i in 12:
			var a0: float = float(i) * TAU / 12.0 + _anim_t * 2.0
			visual.draw_arc(c, RADIUS + 9.0, a0, a0 + TAU / 24.0, 4, Color(1, 1, 1, 0.8), 3.0, true)
	UI.draw_ball(visual, c, RADIUS, player_color, facing, true)
	if shield_timer > 0.0:
		var sp: float = 0.5 + 0.5 * sin(_anim_t * 6.0)
		visual.draw_circle(c, RADIUS + 8.0, Color(0.7, 0.45, 1.0, 0.18 + sp * 0.1))
		visual.draw_arc(c, RADIUS + 8.0, 0.0, TAU, 40, Color(0.85, 0.7, 1.0, 0.9), 3.0, true)
		visual.draw_arc(c, RADIUS + 3.0, PI * 1.1, PI * 1.5, 12, Color(1, 1, 1, 0.7), 3.0, true)
	if freeze_timer > 0.0:
		# Ice block around the player
		var ice := Rect2(c - Vector2(RADIUS + 7.0, RADIUS + 7.0), Vector2(RADIUS + 7.0, RADIUS + 7.0) * 2.0)
		visual.draw_rect(ice, Color(0.7, 0.92, 1.0, 0.35))
		visual.draw_rect(ice, Color(0.85, 0.97, 1.0, 0.95), false, 3.0)
		visual.draw_line(ice.position + Vector2(8, 10), ice.position + Vector2(22, 4), Color(1, 1, 1, 0.9), 3.0)
		visual.draw_line(ice.position + Vector2(8, 20), ice.position + Vector2(14, 16), Color(1, 1, 1, 0.7), 2.0)
	if boost_timer > 0.0:
		for i in 3:
			var off: float = float(i - 1) * 9.0
			var tip := c + Vector2(off, -RADIUS - 8.0 - absf(sin(_anim_t * 10.0 + float(i))) * 5.0)
			visual.draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-4, 7), tip + Vector2(4, 7)]), Color("#FFE066"))
	if stun_timer > 0.0:
		for i in 3:
			var ang: float = _anim_t * 7.0 + float(i) * TAU / 3.0
			var sp := c + Vector2(cos(ang) * 20.0, -RADIUS - 6.0 + sin(ang) * 6.0)
			visual.draw_circle(sp, 4.5, Color("#FFD60A"))
			visual.draw_circle(sp, 2.0, Color.WHITE)
	if has_bomb:
		_draw_bomb(c + Vector2(0, -RADIUS - 20.0))


func _draw_bomb(b: Vector2) -> void:
	var urgency: float = clampf(1.0 - bomb_fuse / 7.0, 0.0, 1.0)
	var pulse: float = 0.5 + 0.5 * sin(_anim_t * (8.0 + urgency * 22.0))
	var r: float = 13.0 + pulse * 2.0 * (0.5 + urgency) + _bomb_pulse * 9.0
	if _bomb_pulse > 0.0:
		visual.draw_circle(b, r + 10.0 * _bomb_pulse, Color(1.0, 0.2, 0.1, 0.35 * _bomb_pulse))
	visual.draw_circle(b + Vector2(0, 3), r, Color(0, 0, 0, 0.35))
	visual.draw_circle(b, r, Color(0.09, 0.08, 0.11))
	visual.draw_circle(b, r, Color(1.0, 0.12, 0.1, pulse * (0.25 + urgency * 0.55)))
	visual.draw_circle(b + Vector2(-4, -4), r * 0.3, Color(1, 1, 1, 0.35))
	visual.draw_rect(Rect2(b + Vector2(-4, -r - 4), Vector2(8, 6)), Color(0.35, 0.35, 0.4))
	var fuse_end := b + Vector2(8, -r - 12)
	visual.draw_line(b + Vector2(0, -r - 3), fuse_end, Color(0.85, 0.75, 0.5), 3.0, true)
	var spark := 3.5 + pulse * 3.5
	visual.draw_circle(fuse_end, spark + 2.0, Color(1.0, 0.45, 0.05, 0.6))
	visual.draw_circle(fuse_end, spark, Color(1.0, 0.9, 0.3))
	for i in 4:
		var a: float = _anim_t * 18.0 + float(i) * PI * 0.5
		visual.draw_line(fuse_end, fuse_end + Vector2.from_angle(a) * (spark + 5.0), Color(1, 0.85, 0.3, 0.8), 1.5)


## Called once per second during the last 5 seconds of the fuse.
func pulse_bomb() -> void:
	_bomb_pulse = 1.0
	if bomb_label == null:
		return
	bomb_label.pivot_offset = bomb_label.size * 0.5
	bomb_label.scale = Vector2(1.8, 1.8)
	var tw := bomb_label.create_tween()
	tw.tween_property(bomb_label, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _play_elimination(style: String) -> void:
	name_label.visible = false
	bomb_label.visible = false
	trail.emitting = false
	if style == "explode":
		visual.visible = false
		_scorched = true
		shadow.queue_redraw()
		spawn_burst(Color("#FFE066"), 40, 460.0, 12.0, 0.6)
		spawn_burst(Color("#FB5607"), 34, 320.0, 16.0, 0.8)
		spawn_burst(Color(0.15, 0.13, 0.15, 0.85), 22, 160.0, 20.0, 1.1)
	else:
		var tw := create_tween().set_parallel(true)
		tw.tween_property(visual, "scale", Vector2(0.1, 0.1), 0.8).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(visual, "rotation", TAU * 1.5, 0.8)
		tw.tween_property(visual, "position:y", 70.0, 0.8).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(visual, "modulate", Color(0.6, 0.2, 0.1, 0.0), 0.8)
		tw.tween_property(shadow, "modulate:a", 0.0, 0.3)
		get_tree().create_timer(0.6).timeout.connect(_lava_splash)


func _lava_splash() -> void:
	spawn_burst(Color("#FF7B00"), 28, 260.0, 10.0, 0.7, Vector2(0, 50))
	spawn_burst(Color("#FFD166"), 14, 180.0, 6.0, 0.5, Vector2(0, 50))


func spawn_burst(col: Color, amount: int, speed: float, size: float, life: float, offset: Vector2 = Vector2(0, -LIFT)) -> void:
	var p := CPUParticles2D.new()
	p.position = offset
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = amount
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
	p.z_index = 15
	add_child(p)
	p.emitting = true
	get_tree().create_timer(life + 0.6).timeout.connect(p.queue_free)
