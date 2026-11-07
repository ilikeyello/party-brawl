extends CanvasLayer
## Universal controls + top HUD.
## - Virtual joystick (bottom-left) with multi-touch index tracking
## - DASH / ACT button (bottom-right) with radial cooldown
## - Keyboard (WASD / arrows + Space) and gamepad fallback
## - Top bar: minigame name, 1-line instruction, big timer, live player badges

const UI := preload("res://scripts/ui_kit.gd")
## Control sizes. On phones the whole UI is scaled up (GameManager.ui_scale up to 1.6) so menus are
## readable, which made the in-game controls huge and they covered the game. So the controls are
## shrunk back down a bit on phones (see _update_sizes) and tucked closer into the corners.
var JOY_RADIUS := 75.0
var KNOB_RADIUS := 32.0
var BUTTON_SIZE := 110.0
var _ctl_k := 1.0          # 1.0 on PC/tablets, ~0.75 on phones
var _corner := Vector2(150.0, 140.0)   # control centres: this far in from the bottom corners
const DEADZONE := 0.12
const FULL_AT := 0.6          # stick reaches full speed at 60% of the radius
const SLING_FULL := 170.0     # sumo slingshot: pull this far for full power

var joystick_vector: Vector2 = Vector2.ZERO
var action_held: bool = false
var cooldown_ratio: float = 0.0
var action_label: String = "DASH"
var action_color: Color = Color("#FF9F1C")
## Keyboard/mouse hint shown at the bottom on PC (set by each minigame).
var key_hint: String = "WASD / ARROWS: move     SPACE / SHIFT / CLICK: dash"
var pc_key: String = "SPACE"

var _joy_touch: int = -1
var _btn_touch: int = -1
var _knob: Vector2 = Vector2.ZERO
var _joy_origin: Vector2 = Vector2.ZERO
## Sumo: touches outside the joystick corner aim directly (touch where you want to slide).
var free_aim: bool = false
## D-pad mode (Light Trails): a 4-way pad instead of the joystick (turns are 90 degrees).
var dpad_mode: bool = false
var DPAD_BTN := 62.0          # size of each arrow button
var DPAD_GAP := 66.0          # centre of the pad -> centre of each arrow
var _dpad_touch: int = -1
var _dpad_dir: Vector2 = Vector2.ZERO
## Swipe mode (Light Trails): swipe anywhere in the direction you want to go. The last swipe
## stays "on" until the next one, so a quick second swipe gets queued for the next corner.
## One finger can do several swipes in a row without lifting (e.g. up, then right).
var swipe_mode: bool = false
const SWIPE_MIN := 34.0       # finger has to move this far to count as a swipe
var _swipe_touch: int = -1
var _swipe_from: Vector2 = Vector2.ZERO
var _swipe_dir: Vector2 = Vector2.ZERO
var _swipe_t: float = 9.0     # time since the last swipe (for the little arrow that fades out)
var _swipe_at: Vector2 = Vector2.ZERO
## Hold mode (Balloon Pump): touching anywhere on the screen holds the action button.
var hold_mode: bool = false
var hold_hint: String = "HOLD ANYWHERE"
var free_active: bool = false
var free_pos: Vector2 = Vector2.ZERO
var free_start: Vector2 = Vector2.ZERO
var _free_touch: int = -1
var _latched: bool = false
var _t: float = 0.0
var _last_secs: int = -1

var root: Control
var pad: Control
var title_label: Label
var rules_label: Label
var timer_label: Label
var top_left: PanelContainer
var timer_panel: PanelContainer
var badges_box: VBoxContainer
var center_label: Label
var flash_rect: ColorRect
var _badge_rows: Dictionary = {}
var _center_tween: Tween


func _ready() -> void:
	layer = 5
	root = Control.new()
	root.name = "HUDRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	flash_rect = ColorRect.new()
	flash_rect.color = Color(1, 1, 1, 0)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(flash_rect)
	flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	pad = Control.new()
	pad.name = "TouchPad"
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(pad)
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.draw.connect(_draw_pad)

	# Top-left: minigame name + instruction
	top_left = PanelContainer.new()
	top_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tl_box := UI.box(Color(0.05, 0.04, 0.14, 0.78), 14, Color(1, 1, 1, 0.15), 2)
	tl_box.content_margin_top = 6
	tl_box.content_margin_bottom = 6
	top_left.add_theme_stylebox_override("panel", tl_box)
	top_left.position = Vector2(12, 10)
	root.add_child(top_left)
	var tlv := VBoxContainer.new()
	tlv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tlv.add_theme_constant_override("separation", 0)
	top_left.add_child(tlv)
	title_label = UI.make_label("", 22, Color("#FEE440"), 6)
	rules_label = UI.make_label("", 14, Color.WHITE, 4)
	tlv.add_child(title_label)
	tlv.add_child(rules_label)

	# Top-center: big timer
	timer_panel = PanelContainer.new()
	timer_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tp_box := UI.box(Color(0.05, 0.04, 0.14, 0.78), 16, Color(1, 1, 1, 0.2), 2)
	tp_box.content_margin_top = 0
	tp_box.content_margin_bottom = 2
	timer_panel.add_theme_stylebox_override("panel", tp_box)
	root.add_child(timer_panel)
	timer_label = UI.make_label("25", 40, Color.WHITE, 8, HORIZONTAL_ALIGNMENT_CENTER)
	timer_label.custom_minimum_size = Vector2(90, 0)
	timer_panel.add_child(timer_label)

	# Top-right: player badges
	badges_box = VBoxContainer.new()
	badges_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badges_box.add_theme_constant_override("separation", 4)
	badges_box.custom_minimum_size = Vector2(176, 0)
	root.add_child(badges_box)

	# Center pop-up text (FINISH!, YOU'RE OUT!)
	center_label = UI.make_label("", 64, Color.WHITE, 14, HORIZONTAL_ALIGNMENT_CENTER)
	center_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	center_label.visible = false
	root.add_child(center_label)
	center_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_t += delta
	_update_sizes()
	var s := _vp_size()
	var ins: Vector4 = GameManager.safe_insets
	if top_left != null:
		top_left.position = Vector2(12.0 + ins.x, 10.0 + ins.y)
	if timer_panel != null:
		timer_panel.position = Vector2((s.x - timer_panel.size.x) * 0.5, 8.0 + ins.y)
		timer_label.pivot_offset = timer_label.size * 0.5
	if badges_box != null:
		badges_box.position = Vector2(s.x - badges_box.size.x - 12.0 - ins.z, 10.0 + ins.y)
	_swipe_t += delta
	# Only redraw the controls when something about them changed (was every frame).
	var key: Array = [GameManager.touch_mode, free_aim, hold_mode, dpad_mode, _joy_touch, _knob.round(), _joy_origin.round(),
		_btn_touch, _dpad_touch, (get_move_vector() * 20.0).round(), free_active, free_pos.round(), free_start.round(),
		snappedf(cooldown_ratio, 0.01), _is_action_down(), action_label, action_color, pc_key, key_hint, hold_hint,
		s, ins, _ring_pulse_step(), swipe_mode, _swipe_dir, _swipe_touch, _swipe_at.round(), mini(int(_swipe_t * 10.0), 6)]
	if key != _pad_key:
		_pad_key = key
		pad.queue_redraw()


var _pad_key: Array = []


func _update_sizes() -> void:
	var k: float = 1.0
	if GameManager.touch_mode:
		k = clampf(1.2 / maxf(GameManager.ui_scale, 0.01), 0.72, 1.0)
	if _sized and is_equal_approx(k, _ctl_k):
		return
	_sized = true
	_ctl_k = k
	JOY_RADIUS = 75.0 * k
	KNOB_RADIUS = 32.0 * k
	BUTTON_SIZE = 110.0 * k
	DPAD_BTN = 62.0 * k
	DPAD_GAP = 66.0 * k
	_corner = Vector2(150.0, 140.0) * k
	_pad_key = []


var _sized := false


## How much room the controls take at each side of the screen (canvas units, not counting the
## notch insets). The minigame camera keeps the playing area out of these strips on touch screens.
func side_zone() -> float:
	if not GameManager.touch_mode:
		return 0.0
	_update_sizes()
	var left: float = _corner.x + JOY_RADIUS + 10.0
	var right: float = _corner.x + BUTTON_SIZE * 0.5 + 12.0
	if badges_box != null:
		right = maxf(right, badges_box.size.x + 12.0 + 8.0)   # the score list in the top-right corner
	return maxf(left, right)


## Height of the top bar (title / timer / scores).
func top_zone() -> float:
	return 62.0


## The "ready" ring on the action button gently pulses (in steps, so it doesn't force a redraw
## every single frame). Battery Saver keeps it steady.
func _ring_pulse_step() -> int:
	if Sfx.battery_saver or cooldown_ratio > 0.0 or not GameManager.touch_mode:
		return 0
	return int(roundf((0.5 + 0.5 * sin(_t * 6.0)) * 6.0))


# ---------------------------------------------------------------- public API

func setup(game_title: String, rules: String) -> void:
	title_label.text = game_title
	rules_label.text = rules


func set_time(t: float) -> void:
	var secs: int = ceili(maxf(t, 0.0))
	timer_label.text = str(secs)
	var urgent := t <= 5.0 and t > 0.0
	timer_label.label_settings.font_color = Color("#FF4D6D") if urgent else Color.WHITE
	if urgent and secs != _last_secs:
		Sfx.play("tick", -4.0)
		timer_label.scale = Vector2(1.35, 1.35)
		var tw := timer_label.create_tween()
		tw.tween_property(timer_label, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_last_secs = secs


func set_cooldown(ratio: float) -> void:
	cooldown_ratio = clampf(ratio, 0.0, 1.0)


## entries: [{ "id": int, "text": String, "color": Color, "out": bool }]
func set_badges(entries: Array) -> void:
	for e in entries:
		var id: int = int(e["id"])
		var lbl: Label = _badge_rows.get(id)
		if lbl == null:
			var panel := PanelContainer.new()
			panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var c: Color = e["color"]
			var sb := UI.box(Color(c.darkened(0.6), 0.88), 10, c, 2)
			sb.content_margin_top = 2
			sb.content_margin_bottom = 2
			sb.content_margin_left = 10
			sb.content_margin_right = 10
			panel.add_theme_stylebox_override("panel", sb)
			lbl = UI.make_label("", 15, Color.WHITE, 4)
			panel.add_child(lbl)
			badges_box.add_child(panel)
			_badge_rows[id] = lbl
		lbl.text = str(e["text"])
		var pnl := lbl.get_parent() as Control
		pnl.modulate.a = 0.45 if bool(e.get("out", false)) else 1.0


func show_center(text: String, col: Color = Color.WHITE, dur: float = 1.2) -> void:
	if _center_tween != null and _center_tween.is_valid():
		_center_tween.kill()
	center_label.text = text
	center_label.label_settings.font_color = col
	center_label.visible = true
	center_label.modulate.a = 1.0
	center_label.pivot_offset = center_label.size * 0.5
	center_label.scale = Vector2(0.4, 0.4)
	_center_tween = center_label.create_tween()
	_center_tween.tween_property(center_label, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_center_tween.tween_interval(dur)
	_center_tween.tween_property(center_label, "modulate:a", 0.0, 0.3)


## PC: no on-screen controls, just a small action/cooldown badge and a key hint.
func _draw_pc_hud() -> void:
	var s := _vp_size()
	var font: Font = UI.title_font()
	var c := Vector2(s.x - 70.0 - GameManager.safe_insets.z, s.y - 62.0 - GameManager.safe_insets.w)
	var r := 30.0
	var btn_ready := cooldown_ratio <= 0.0
	var col := action_color if btn_ready else Color("#8c6d4a")
	pad.draw_circle(c + Vector2(0, 4), r, Color(0, 0, 0, 0.35))
	pad.draw_circle(c, r, col.darkened(0.2))
	if cooldown_ratio > 0.01:
		pad.draw_arc(c, r * 0.5, -PI * 0.5, -PI * 0.5 + TAU * cooldown_ratio, 32, Color(0, 0, 0, 0.45), r, false)
	pad.draw_arc(c, r + 3.0, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - cooldown_ratio), 40, Color("#FEE440") if btn_ready else Color(1, 1, 1, 0.6), 3.0, true)
	pad.draw_string_outline(font, c + Vector2(-60, 6), pc_key, HORIZONTAL_ALIGNMENT_CENTER, 120, 14, 5, Color(0, 0, 0, 0.7))
	pad.draw_string(font, c + Vector2(-60, 6), pc_key, HORIZONTAL_ALIGNMENT_CENTER, 120, 14, Color.WHITE)
	pad.draw_string_outline(font, c + Vector2(-100, -r - 10.0), action_label, HORIZONTAL_ALIGNMENT_CENTER, 200, 16, 6, Color(0, 0, 0, 0.7))
	pad.draw_string(font, c + Vector2(-100, -r - 10.0), action_label, HORIZONTAL_ALIGNMENT_CENTER, 200, 16, Color.WHITE)
	if key_hint != "":
		var y := s.y - 14.0
		pad.draw_string_outline(font, Vector2(0, y), key_hint, HORIZONTAL_ALIGNMENT_CENTER, s.x, 16, 6, Color(0, 0, 0, 0.75))
		pad.draw_string(font, Vector2(0, y), key_hint, HORIZONTAL_ALIGNMENT_CENTER, s.x, 16, Color(1, 1, 1, 0.75))


func set_action(label: String, col: Color = Color("#FF9F1C")) -> void:
	action_label = label
	action_color = col


func flash(col: Color) -> void:
	flash_rect.color = col
	var tw := flash_rect.create_tween()
	tw.tween_property(flash_rect, "color:a", 0.0, 0.45)


# ---------------------------------------------------------------- input

func get_move_vector() -> Vector2:
	if swipe_mode and _swipe_dir != Vector2.ZERO:
		joystick_vector = _swipe_dir
		return _swipe_dir
	if _dpad_touch != -1:
		joystick_vector = _dpad_dir
		return _dpad_dir
	if _joy_touch != -1:
		var raw := _knob / JOY_RADIUS
		var l := raw.length()
		if l <= DEADZONE:
			joystick_vector = Vector2.ZERO
		else:
			var mag: float = clampf((l - DEADZONE) / (FULL_AT - DEADZONE), 0.0, 1.0)
			joystick_vector = raw / l * mag
		return joystick_vector
	var k := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		k.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		k.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		k.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		k.y += 1.0
	var j := Vector2(Input.get_joy_axis(0, JOY_AXIS_LEFT_X), Input.get_joy_axis(0, JOY_AXIS_LEFT_Y))
	if j.length() > 0.25:
		k += j
	k = k.limit_length(1.0)
	joystick_vector = k
	return joystick_vector


## True if the action should fire this frame (held or tapped since last read).
func consume_action() -> bool:
	var a := _latched or _is_action_down()
	_latched = false
	return a


func _is_action_down() -> bool:
	return action_held or Input.is_physical_key_pressed(KEY_SPACE) or Input.is_physical_key_pressed(KEY_SHIFT) or Input.is_joy_button_pressed(0, JOY_BUTTON_A)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			if hold_mode and _btn_touch == -1:
				_btn_touch = st.index
				action_held = true
				_latched = true
			elif swipe_mode and _swipe_touch == -1 and st.position.y > _vp_size().y * 0.12 \
					and st.position.distance_to(btn_center()) > BUTTON_SIZE * 0.8:
				_swipe_touch = st.index
				_swipe_from = st.position
			elif dpad_mode and _dpad_touch == -1 and _in_dpad_zone(st.position):
				_dpad_touch = st.index
				_dpad_dir = _dpad_dir_at(st.position)
			elif _btn_touch == -1 and st.position.distance_to(btn_center()) <= BUTTON_SIZE * 0.8:
				_btn_touch = st.index
				action_held = true
				_latched = true
			elif _joy_touch == -1 and _in_joy_zone(st.position):
				_joy_touch = st.index
				_joy_origin = st.position      # floating stick: appears under the thumb
				_set_knob(st.position)
			elif free_aim and _free_touch == -1:
				_free_touch = st.index
				free_active = true
				free_pos = st.position
				free_start = st.position
		else:
			if st.index == _swipe_touch:
				# A short flick that ended before reaching SWIPE_MIN still counts if it's clear enough.
				_try_swipe(st.position, SWIPE_MIN * 0.6)
				_swipe_touch = -1
			if st.index == _dpad_touch:
				_dpad_touch = -1
				_dpad_dir = Vector2.ZERO
			if st.index == _joy_touch:
				_joy_touch = -1
				_knob = Vector2.ZERO
			if st.index == _free_touch:
				_free_touch = -1
				free_active = false
			if st.index == _btn_touch:
				_btn_touch = -1
				action_held = false
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		if sd.index == _swipe_touch:
			_try_swipe(sd.position, SWIPE_MIN)
		elif sd.index == _dpad_touch:
			# Slide your thumb from one arrow to another without lifting it
			var nd := _dpad_dir_at(sd.position)
			if nd != Vector2.ZERO:
				_dpad_dir = nd
		elif sd.index == _joy_touch:
			_set_knob(sd.position)
		elif sd.index == _free_touch:
			free_pos = sd.position
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and (k.physical_keycode == KEY_SPACE or k.physical_keycode == KEY_SHIFT or k.physical_keycode == KEY_ENTER):
			_latched = true
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# Real mouse clicks (not touches turned into clicks) = action on PC.
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and mb.device != InputEvent.DEVICE_ID_EMULATION and not GameManager.touch_mode:
			_latched = true
	elif event is InputEventJoypadButton:
		var jb := event as InputEventJoypadButton
		if jb.pressed and jb.button_index == JOY_BUTTON_A:
			_latched = true


func _try_swipe(p: Vector2, min_dist: float) -> void:
	var off := p - _swipe_from
	if off.length() < min_dist:
		return
	var d: Vector2
	if absf(off.x) > absf(off.y):
		d = Vector2(signf(off.x), 0.0)
	else:
		d = Vector2(0.0, signf(off.y))
	if d != _swipe_dir:
		_swipe_t = 0.0
		_swipe_at = p
	_swipe_dir = d
	_swipe_from = p    # start measuring the next swipe from here


func _set_knob(p: Vector2) -> void:
	var off := p - _joy_origin
	# If the thumb slides past the edge, drag the stick along with it.
	if off.length() > JOY_RADIUS:
		_joy_origin = p - off.normalized() * JOY_RADIUS
		off = p - _joy_origin
	_knob = off


func dpad_center() -> Vector2:
	var s := _vp_size()
	return Vector2(_corner.x + 10.0 * _ctl_k + GameManager.safe_insets.x, s.y - _corner.y - 20.0 * _ctl_k - GameManager.safe_insets.w)


## The whole left part of the screen counts, so a thumb a bit off the pad still works.
func _in_dpad_zone(p: Vector2) -> bool:
	var s := _vp_size()
	return p.y > s.y * 0.16 and p.x < s.x * 0.5


## Which arrow a touch is on: the direction from the pad's centre (straight lines only).
func _dpad_dir_at(p: Vector2) -> Vector2:
	var off := p - dpad_center()
	if off.length() < 14.0:
		return Vector2.ZERO
	if absf(off.x) > absf(off.y):
		return Vector2(signf(off.x), 0.0)
	return Vector2(0.0, signf(off.y))


func _draw_dpad() -> void:
	var c := dpad_center()
	pad.draw_circle(c + Vector2(0, 6), DPAD_GAP + DPAD_BTN * 0.6, Color(0, 0, 0, 0.22))
	pad.draw_circle(c, DPAD_GAP + DPAD_BTN * 0.6, Color(1, 1, 1, 0.07))
	var held := get_move_vector()
	for d in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		var on: bool = held.dot(d) > 0.7
		var bc: Vector2 = c + d * DPAD_GAP
		var depth := 2.0 if on else 6.0
		var r := Rect2(bc - Vector2(DPAD_BTN, DPAD_BTN) * 0.5, Vector2(DPAD_BTN, DPAD_BTN))
		pad.draw_rect(Rect2(r.position + Vector2(0, 6), r.size), Color(0, 0, 0, 0.3))
		var top := Rect2(r.position + Vector2(0, 6.0 - depth), r.size)
		pad.draw_rect(top, Color("#00F5D4") if on else Color(1, 1, 1, 0.22))
		pad.draw_rect(top, Color(1, 1, 1, 0.6), false, 2.0)
		var tc: Vector2 = top.get_center()
		var side := Vector2(-d.y, d.x)
		var tri := PackedVector2Array([tc + d * 16.0, tc - d * 10.0 + side * 15.0, tc - d * 10.0 - side * 15.0])
		pad.draw_colored_polygon(tri, Color(0.05, 0.05, 0.15, 0.9) if on else Color.WHITE)
	pad.draw_circle(c, 14.0, Color(1, 1, 1, 0.15))


func _in_joy_zone(p: Vector2) -> bool:
	var s := _vp_size()
	if p.y < s.y * 0.16:
		return false   # top bar
	if free_aim:
		return false   # sumo on phones: the whole screen is the slingshot
	return p.x < s.x * 0.5


## Raw stick direction*distance (0..1) for aiming, no speed curve.
func get_stick_raw() -> Vector2:
	if _joy_touch == -1:
		return Vector2.ZERO
	return _knob / JOY_RADIUS


func _vp_size() -> Vector2:
	if root == null:
		return Vector2(1280, 720)
	return root.get_viewport_rect().size


func joy_center() -> Vector2:
	if _joy_touch != -1:
		return _joy_origin
	var s := _vp_size()
	return Vector2(_corner.x + GameManager.safe_insets.x, s.y - _corner.y - GameManager.safe_insets.w)


func btn_center() -> Vector2:
	var s := _vp_size()
	return Vector2(s.x - _corner.x - GameManager.safe_insets.z, s.y - _corner.y - GameManager.safe_insets.w)


# ---------------------------------------------------------------- drawing

func _draw_pad() -> void:
	if not GameManager.touch_mode:
		_draw_pc_hud()
		return
	if free_aim:
		_draw_sling()
		_draw_action_button()
		return
	if hold_mode:
		var hs := _vp_size()
		var hf: Font = UI.title_font()
		var hp := Vector2(20.0 + GameManager.safe_insets.x, hs.y - 40.0 - GameManager.safe_insets.w)
		pad.draw_string_outline(hf, hp, hold_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 6, Color(0, 0, 0, 0.7))
		pad.draw_string(hf, hp, hold_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 1, 0.85))
		_draw_action_button()
		return
	if swipe_mode:
		_draw_swipe()
		_draw_action_button()
		return
	if dpad_mode:
		_draw_dpad()
		_draw_action_button()
		return
	# Joystick base
	var jc := joy_center()
	var touching := _joy_touch != -1
	pad.draw_circle(jc + Vector2(0, 7), JOY_RADIUS, Color(0, 0, 0, 0.28))
	pad.draw_circle(jc, JOY_RADIUS, Color(1, 1, 1, 0.12 if touching else 0.08))
	pad.draw_arc(jc, JOY_RADIUS, 0.0, TAU, 64, Color(1, 1, 1, 0.4), 3.0, true)
	for i in 4:
		var d := Vector2.from_angle(float(i) * PI * 0.5)
		var tip := jc + d * (JOY_RADIUS - 10.0)
		var side := Vector2(-d.y, d.x)
		pad.draw_colored_polygon(PackedVector2Array([tip, tip - d * 10.0 + side * 8.0, tip - d * 10.0 - side * 8.0]), Color(1, 1, 1, 0.35))
	# Knob (also mirrors keyboard direction)
	var knob := _knob if touching else get_move_vector() * JOY_RADIUS * 0.8
	var kp := jc + knob
	pad.draw_circle(kp + Vector2(0, 6), KNOB_RADIUS, Color(0, 0, 0, 0.3))
	pad.draw_circle(kp, KNOB_RADIUS, Color(1, 1, 1, 0.6 if touching else 0.4))
	pad.draw_circle(kp + Vector2(-9, -10), KNOB_RADIUS * 0.33, Color(1, 1, 1, 0.5))
	_draw_action_button()


func _draw_action_button() -> void:
	# Action button (raised; sinks when pressed)
	var bc := btn_center()
	var r := BUTTON_SIZE * 0.5
	var down := _is_action_down()
	var btn_ready := cooldown_ratio <= 0.0
	var col := action_color if btn_ready else Color("#8c6d4a")
	if GameManager.touch_mode and not down:
		col.a = 0.62   # see-through so the game shows behind it
	var depth := 8.0 * _ctl_k
	var lift := 2.0 if down else depth
	var top := bc + Vector2(0, depth - lift)
	var see_through: bool = GameManager.touch_mode and not down
	pad.draw_circle(bc + Vector2(0, depth + 4), r, Color(0, 0, 0, 0.15 if see_through else 0.3))
	pad.draw_circle(bc + Vector2(0, depth), r, Color(col.darkened(0.5), 0.3 if see_through else 1.0))
	pad.draw_circle(top, r, col)
	pad.draw_circle(top + Vector2(-r * 0.3, -r * 0.35), r * 0.28, Color(1, 1, 1, 0.3))
	if cooldown_ratio > 0.01:
		# Radial "pie" showing remaining cooldown
		pad.draw_arc(top, r * 0.5, -PI * 0.5, -PI * 0.5 + TAU * cooldown_ratio, 40, Color(0, 0, 0, 0.45), r, false)
	if 1.0 - cooldown_ratio > 0.01:
		var ring_col := Color("#FEE440") if btn_ready else Color(1, 1, 1, 0.7)
		if btn_ready:
			ring_col.a = 0.2 + 0.8 * float(_ring_pulse_step()) / 6.0 if not Sfx.battery_saver else 0.85
		pad.draw_arc(top, r + 5.0, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - cooldown_ratio), 48, ring_col, 4.0, true)
	var font: Font = UI.title_font()
	var text_pos := top + Vector2(-r, 7)
	pad.draw_string_outline(font, text_pos, action_label, HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, 17, 6, Color(0, 0, 0, 0.6))
	pad.draw_string(font, text_pos, action_label, HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, 17, Color.WHITE)


## Swipe mode: a hint at the bottom, a small arrow showing the way you're steering, and a quick
## arrow where your finger swiped.
func _draw_swipe() -> void:
	var s := _vp_size()
	var font: Font = UI.title_font()
	var hp := Vector2(20.0 + GameManager.safe_insets.x, s.y - 40.0 - GameManager.safe_insets.w)
	var hint := "SWIPE TO TURN"
	pad.draw_string_outline(font, hp, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, 6, Color(0, 0, 0, 0.7))
	pad.draw_string(font, hp, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(1, 1, 1, 0.8))
	if _swipe_dir != Vector2.ZERO:
		# Steady little arrow next to the hint = the direction you asked for
		_draw_swipe_arrow(hp + Vector2(font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 30.0, -8.0), _swipe_dir, 16.0, Color(0.0, 0.96, 0.83, 0.9))
		# Bigger arrow where you swiped, fading out over 0.6 s
		var a: float = clampf(1.0 - float(mini(int(_swipe_t * 10.0), 6)) / 6.0, 0.0, 1.0)
		if a > 0.0:
			_draw_swipe_arrow(_swipe_at, _swipe_dir, 34.0, Color(1, 1, 1, 0.55 * a))


func _draw_swipe_arrow(c: Vector2, d: Vector2, size_px: float, col: Color) -> void:
	var side := Vector2(-d.y, d.x)
	var tip := c + d * size_px
	var back := c - d * size_px * 0.6
	pad.draw_line(back, c, col, size_px * 0.35, true)
	pad.draw_colored_polygon(PackedVector2Array([tip, c + side * size_px * 0.7, c - side * size_px * 0.7]), col)


## Sumo slingshot: line from where the drag started to the finger.
func _draw_sling() -> void:
	var font: Font = UI.title_font()
	if free_active:
		var pull := free_pos - free_start
		pad.draw_circle(free_start, 26.0, Color(1, 1, 1, 0.15))
		pad.draw_arc(free_start, 26.0, 0.0, TAU, 32, Color(1, 1, 1, 0.6), 3.0, true)
		pad.draw_line(free_start, free_pos, Color(1, 1, 1, 0.55), 6.0, true)
		pad.draw_circle(free_pos, 18.0, Color(1, 1, 1, 0.5))
		var pct: int = int(clampf(pull.length() / SLING_FULL, 0.0, 1.0) * 100.0)
		var txt := "%d%%" % pct
		pad.draw_string_outline(font, free_pos + Vector2(-50, -30), txt, HORIZONTAL_ALIGNMENT_CENTER, 100, 20, 6, Color(0, 0, 0, 0.7))
		pad.draw_string(font, free_pos + Vector2(-50, -30), txt, HORIZONTAL_ALIGNMENT_CENTER, 100, 20, Color.WHITE)
	else:
		var s := _vp_size()
		var t := "DRAG TO AIM - KEEP HOLDING + TAP LOCK IN"
		pad.draw_string_outline(font, Vector2(20.0 + GameManager.safe_insets.x, s.y - 40.0 - GameManager.safe_insets.w), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 6, Color(0, 0, 0, 0.7))
		pad.draw_string(font, Vector2(20.0 + GameManager.safe_insets.x, s.y - 40.0 - GameManager.safe_insets.w), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(1, 1, 1, 0.8))
