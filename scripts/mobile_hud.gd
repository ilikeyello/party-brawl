extends CanvasLayer
## Universal controls + top HUD.
## - Virtual joystick (bottom-left) with multi-touch index tracking
## - DASH / ACT button (bottom-right) with radial cooldown
## - Keyboard (WASD / arrows + Space) and gamepad fallback
## - Top bar: minigame name, 1-line instruction, big timer, live player badges

const UI := preload("res://scripts/ui_kit.gd")
const JOY_RADIUS := 75.0
const KNOB_RADIUS := 32.0
const BUTTON_SIZE := 110.0
const DEADZONE := 0.12
const FULL_AT := 0.6          # stick reaches full speed at 60% of the radius

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
var free_active: bool = false
var free_pos: Vector2 = Vector2.ZERO
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
	var s := _vp_size()
	if timer_panel != null:
		timer_panel.position = Vector2((s.x - timer_panel.size.x) * 0.5, 8)
		timer_label.pivot_offset = timer_label.size * 0.5
	if badges_box != null:
		badges_box.position = Vector2(s.x - badges_box.size.x - 12, 10)
	pad.queue_redraw()


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
	var c := Vector2(s.x - 70.0, s.y - 62.0)
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
			if _btn_touch == -1 and st.position.distance_to(btn_center()) <= BUTTON_SIZE * 0.8:
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
		else:
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
		if sd.index == _joy_touch:
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


func _set_knob(p: Vector2) -> void:
	var off := p - _joy_origin
	# If the thumb slides past the edge, drag the stick along with it.
	if off.length() > JOY_RADIUS:
		_joy_origin = p - off.normalized() * JOY_RADIUS
		off = p - _joy_origin
	_knob = off


func _in_joy_zone(p: Vector2) -> bool:
	var s := _vp_size()
	if p.y < s.y * 0.16:
		return false   # top bar
	if free_aim:
		return p.x < s.x * 0.3 and p.y > s.y * 0.5
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
	return Vector2(150.0, s.y - 140.0)


func btn_center() -> Vector2:
	var s := _vp_size()
	return Vector2(s.x - 150.0, s.y - 140.0)


# ---------------------------------------------------------------- drawing

func _draw_pad() -> void:
	if not GameManager.touch_mode:
		_draw_pc_hud()
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

	# Action button (raised; sinks when pressed)
	var bc := btn_center()
	var r := BUTTON_SIZE * 0.5
	var down := _is_action_down()
	var btn_ready := cooldown_ratio <= 0.0
	var col := action_color if btn_ready else Color("#8c6d4a")
	var depth := 8.0
	var lift := 2.0 if down else depth
	var top := bc + Vector2(0, depth - lift)
	pad.draw_circle(bc + Vector2(0, depth + 4), r, Color(0, 0, 0, 0.3))
	pad.draw_circle(bc + Vector2(0, depth), r, col.darkened(0.5))
	pad.draw_circle(top, r, col)
	pad.draw_circle(top + Vector2(-r * 0.3, -r * 0.35), r * 0.28, Color(1, 1, 1, 0.3))
	if cooldown_ratio > 0.01:
		# Radial "pie" showing remaining cooldown
		pad.draw_arc(top, r * 0.5, -PI * 0.5, -PI * 0.5 + TAU * cooldown_ratio, 40, Color(0, 0, 0, 0.45), r, false)
	if 1.0 - cooldown_ratio > 0.01:
		var ring_col := Color("#FEE440") if btn_ready else Color(1, 1, 1, 0.7)
		if btn_ready:
			ring_col.a = 0.6 + 0.4 * sin(_t * 6.0)
		pad.draw_arc(top, r + 5.0, -PI * 0.5, -PI * 0.5 + TAU * (1.0 - cooldown_ratio), 48, ring_col, 4.0, true)
	var font: Font = UI.title_font()
	var text_pos := top + Vector2(-r, 7)
	pad.draw_string_outline(font, text_pos, action_label, HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, 17, 6, Color(0, 0, 0, 0.6))
	pad.draw_string(font, text_pos, action_label, HORIZONTAL_ALIGNMENT_CENTER, r * 2.0, 17, Color.WHITE)
