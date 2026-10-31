extends Control
## Animated menu background: drifting stripes and bouncing 3D-looking party balls.

const UI := preload("res://scripts/ui_kit.gd")

var balls: Array = []
var _t: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in 12:
		balls.append({
			"p": Vector2(randf_range(80.0, 1200.0), randf_range(80.0, 640.0)),
			"v": Vector2.from_angle(randf() * TAU) * randf_range(40.0, 110.0),
			"r": randf_range(16.0, 44.0),
			"c": GameManager.COLORS[i % 4],
			"h": randf() * TAU,
		})


func _process(delta: float) -> void:
	_t += delta
	var s := size
	if s.x < 100.0 or s.y < 100.0:
		return
	for b in balls:
		var r: float = b["r"]
		var v: Vector2 = b["v"]
		var p: Vector2 = b["p"] + v * delta
		if p.x < r or p.x > s.x - r:
			v.x = -v.x
		if p.y < r or p.y > s.y - r:
			v.y = -v.y
		b["p"] = p.clamp(Vector2(r, r), s - Vector2(r, r))
		b["v"] = v
	queue_redraw()


func _draw() -> void:
	var s := size
	draw_rect(Rect2(Vector2.ZERO, s), Color("#120f2a"))
	# Moving diagonal stripes
	var shift: float = fmod(_t * 24.0, 120.0)
	var i := -12
	while i < int(s.x / 120.0) + 14:
		var x: float = float(i) * 120.0 + shift
		draw_colored_polygon(PackedVector2Array([
			Vector2(x, 0), Vector2(x + 60.0, 0),
			Vector2(x + 60.0 - s.y * 0.5, s.y), Vector2(x - s.y * 0.5, s.y)]), Color(1, 1, 1, 0.025))
		i += 1
	# Floor glow at the bottom
	draw_rect(Rect2(0, s.y * 0.75, s.x, s.y * 0.25), Color(0.6, 0.2, 1.0, 0.05))
	for b in balls:
		var p: Vector2 = b["p"]
		var r: float = b["r"]
		var hop: float = absf(sin(_t * 2.5 + float(b["h"]))) * r * 0.7
		var sh: float = 1.0 - hop / (r * 3.0)
		draw_colored_polygon(UI.ellipse_points(p + Vector2(0, r * 0.95), r * 0.9 * sh, r * 0.32 * sh, 24), Color(0, 0, 0, 0.3))
		var vv: Vector2 = b["v"]
		UI.draw_ball(self, p - Vector2(0, hop), r, b["c"], vv.normalized(), true)
