extends RefCounted
## Shared styling + drawing helpers. Fonts: Lilita One (titles) + Fredoka (body), both SIL OFL.
## Used with: const UI := preload("res://scripts/ui_kit.gd")

const TITLE_FONT_PATH := "res://fonts/LilitaOne-Regular.ttf"
const BODY_FONT_PATH := "res://fonts/Fredoka.ttf"

static var _title_font: Font = null
static var _body_font: Font = null


## Loads a font whether or not the editor has imported it yet (raw .ttf fallback).
static func _load_font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is Font:
			return res
	if FileAccess.file_exists(path):
		var ff := FontFile.new()
		if ff.load_dynamic_font(path) == OK:
			return ff
	return ThemeDB.fallback_font


static func title_font() -> Font:
	if _title_font == null:
		_title_font = _load_font(TITLE_FONT_PATH)
	return _title_font


static func body_font() -> Font:
	if _body_font == null:
		var base := _load_font(BODY_FONT_PATH)
		var fv := FontVariation.new()
		fv.base_font = base
		fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): 600}
		_body_font = fv
	return _body_font


static func box(col: Color, radius: int = 14, border_col: Color = Color(0, 0, 0, 0), border_w: int = 0, shadow: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(radius)
	if border_w > 0:
		sb.border_color = border_col
		sb.set_border_width_all(border_w)
	if shadow > 0:
		sb.shadow_color = Color(0, 0, 0, 0.45)
		sb.shadow_size = shadow
		sb.shadow_offset = Vector2(0, shadow * 0.5)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = body_font()
	t.default_font_size = 18
	t.set_stylebox("normal", "LineEdit", box(Color("#1a1736"), 10, Color("#4b4690"), 2))
	t.set_stylebox("focus", "LineEdit", box(Color("#211d45"), 10, Color("#00F5D4"), 2))
	t.set_stylebox("read_only", "LineEdit", box(Color("#15132b"), 10, Color("#2f2b5c"), 2))
	t.set_color("font_color", "LineEdit", Color.WHITE)
	t.set_color("font_placeholder_color", "LineEdit", Color(1, 1, 1, 0.35))
	t.set_color("caret_color", "LineEdit", Color("#00F5D4"))
	t.set_font_size("font_size", "LineEdit", 20)
	t.set_stylebox("panel", "PanelContainer", box(Color(0.09, 0.08, 0.2, 0.93), 22, Color("#3d3880"), 3, 16))
	t.set_color("font_color", "Label", Color.WHITE)
	t.set_font_size("font_size", "CheckButton", 18)
	t.set_color("font_color", "CheckButton", Color.WHITE)
	t.set_color("font_hover_color", "CheckButton", Color("#00F5D4"))
	t.set_color("font_pressed_color", "CheckButton", Color.WHITE)
	t.set_color("font_hover_pressed_color", "CheckButton", Color("#00F5D4"))
	t.set_stylebox("focus", "CheckButton", StyleBoxEmpty.new())
	return t


static func label_settings(size: int, col: Color, outline: int = 0, shadow: bool = false) -> LabelSettings:
	var s := LabelSettings.new()
	s.font = title_font() if size >= 24 else body_font()
	s.font_size = size
	s.font_color = col
	if outline > 0:
		s.outline_size = outline
		s.outline_color = Color(0.03, 0.02, 0.08)
	if shadow:
		s.shadow_size = 0
		s.shadow_color = Color(0, 0, 0, 0.6)
		s.shadow_offset = Vector2(0, 6)
	return s


static func make_label(text: String, size: int = 18, col: Color = Color.WHITE, outline: int = 0, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = label_settings(size, col, outline)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Chunky "3D" arcade button: thick darker bottom border that squashes when pressed.
static func make_button(text: String, col: Color, font_size: int = 22) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	var normal := box(col, 14)
	normal.border_color = col.darkened(0.45)
	normal.border_width_bottom = 7
	normal.content_margin_left = 18
	normal.content_margin_right = 18
	normal.content_margin_top = 10
	normal.content_margin_bottom = 10
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = col.lightened(0.12)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = col.darkened(0.08)
	pressed.border_width_bottom = 2
	pressed.content_margin_top = 15
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.28, 0.27, 0.36)
	disabled.border_color = Color(0.16, 0.15, 0.22)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("hover_pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_font_override("font", title_font())
	b.add_theme_font_size_override("font_size", font_size)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.4))
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	b.add_theme_constant_override("outline_size", 6)
	return b


static func ellipse_points(c: Vector2, rx: float, ry: float, segments: int = 32) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in segments:
		var a: float = TAU * float(i) / float(segments)
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


## A shaded "3D" ball with a white rim and two eyes looking toward `look`.
static func draw_ball(ci: CanvasItem, c: Vector2, r: float, col: Color, look: Vector2 = Vector2.DOWN, eyes: bool = true) -> void:
	var dark := col.darkened(0.45)
	ci.draw_circle(c, r, dark)
	ci.draw_circle(c + Vector2(-0.1, -0.12) * r, r * 0.86, col)
	ci.draw_circle(c + Vector2(-0.28, -0.32) * r, r * 0.42, col.lightened(0.22))
	ci.draw_circle(c + Vector2(-0.4, -0.44) * r, r * 0.15, Color(1, 1, 1, 0.85))
	ci.draw_arc(c, r, 0.0, TAU, 40, Color.WHITE, maxf(2.0, r * 0.125), true)
	if eyes:
		var d := look.normalized() if look.length() > 0.1 else Vector2.DOWN
		var side := Vector2(-d.y, d.x)
		var base := c + d * r * 0.36 + Vector2(0, -r * 0.14)
		for i in 2:
			var s: float = -1.0 if i == 0 else 1.0
			var e: Vector2 = base + side * r * 0.3 * s
			ci.draw_circle(e, r * 0.22, Color.WHITE)
			ci.draw_circle(e + d * r * 0.09, r * 0.11, Color(0.08, 0.08, 0.12))


static func draw_crown(ci: CanvasItem, c: Vector2, w: float, col: Color = Color("#FFD60A")) -> void:
	var h: float = w * 0.62
	var pts := PackedVector2Array([
		c + Vector2(-w * 0.5, h * 0.5),
		c + Vector2(-w * 0.5, -h * 0.3),
		c + Vector2(-w * 0.25, h * 0.05),
		c + Vector2(0.0, -h * 0.5),
		c + Vector2(w * 0.25, h * 0.05),
		c + Vector2(w * 0.5, -h * 0.3),
		c + Vector2(w * 0.5, h * 0.5),
	])
	ci.draw_colored_polygon(pts, col)
	ci.draw_rect(Rect2(c + Vector2(-w * 0.5, h * 0.32), Vector2(w, h * 0.18)), col.darkened(0.25))
	ci.draw_circle(c + Vector2(0.0, -h * 0.5), w * 0.07, Color.WHITE)
	ci.draw_circle(c + Vector2(-w * 0.5, -h * 0.3), w * 0.06, Color("#FF4D6D"))
	ci.draw_circle(c + Vector2(w * 0.5, -h * 0.3), w * 0.06, Color("#00F5D4"))


## Raised block: footprint is the ground rect, h is how tall it looks.
static func draw_block(ci: CanvasItem, footprint: Rect2, h: float, top: Color, front: Color) -> void:
	var top_rect := Rect2(footprint.position - Vector2(0, h), footprint.size)
	var front_rect := Rect2(footprint.position.x, footprint.end.y - h, footprint.size.x, h)
	ci.draw_rect(front_rect, front)
	ci.draw_rect(Rect2(front_rect.position, Vector2(front_rect.size.x, 3)), front.lightened(0.15))
	ci.draw_rect(top_rect, top)
	if top_rect.size.x > 12 and top_rect.size.y > 12:
		ci.draw_rect(top_rect.grow(-5), top.lightened(0.08))
	ci.draw_rect(top_rect, top.lightened(0.3), false, 2.0)
