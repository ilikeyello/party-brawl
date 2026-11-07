extends Control
## Animated menu background: drifting stripes and bouncing 3D-looking party balls.
## Performance: everything is drawn ONCE and then only moved around (the balls were being fully
## re-drawn every frame before, which cost ~6 ms per frame in the browser). A ball is re-drawn only
## when it bounces (its eyes turn to the new direction). Battery Saver keeps it all still.

const UI := preload("res://scripts/ui_kit.gd")
const STRIPE_GAP := 120.0

var balls: Array = []
var _t: float = 0.0
var _stripes: Node2D
var _glow: Node2D
var _drawn_size := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_stripes = Node2D.new()
	add_child(_stripes)
	_stripes.draw.connect(_draw_stripes)
	_glow = Node2D.new()
	add_child(_glow)
	_glow.draw.connect(_draw_glow)
	for i in 12:
		var b := {
			"p": Vector2(randf_range(80.0, 1200.0), randf_range(80.0, 640.0)),
			"v": Vector2.from_angle(randf() * TAU) * randf_range(40.0, 110.0),
			"r": randf_range(16.0, 44.0),
			"c": GameManager.COLORS[i % 4],
			"h": randf() * TAU,
		}
		var sh := Node2D.new()
		add_child(sh)
		var r: float = b["r"]
		sh.draw.connect(func(): sh.draw_colored_polygon(UI.ellipse_points(Vector2.ZERO, r * 0.9, r * 0.32, 24), Color(0, 0, 0, 0.3)))
		var body := Node2D.new()
		add_child(body)
		body.draw.connect(func(): UI.draw_ball(body, Vector2.ZERO, r, b["c"], (b["v"] as Vector2).normalized(), true))
		b["shadow"] = sh
		b["body"] = body
		balls.append(b)
	_place_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_node_ready():
		_place_all()


func _process(delta: float) -> void:
	var s := size
	if s.x < 100.0 or s.y < 100.0:
		return
	if s != _drawn_size:
		_drawn_size = s
		queue_redraw()
		_stripes.queue_redraw()
		_glow.queue_redraw()
	if Sfx.battery_saver:
		return
	_t += delta
	for b in balls:
		var r: float = b["r"]
		var v: Vector2 = b["v"]
		var p: Vector2 = b["p"] + v * delta
		var bounced := false
		if p.x < r or p.x > s.x - r:
			v.x = -v.x
			bounced = true
		if p.y < r or p.y > s.y - r:
			v.y = -v.y
			bounced = true
		b["p"] = p.clamp(Vector2(r, r), s - Vector2(r, r))
		b["v"] = v
		if bounced:
			(b["body"] as Node2D).queue_redraw()
	_place_all()


func _place_all() -> void:
	if _stripes == null:
		return
	_stripes.position.x = fmod(_t * 24.0, STRIPE_GAP)
	for b in balls:
		var p: Vector2 = b["p"]
		var r: float = b["r"]
		var hop: float = absf(sin(_t * 2.5 + float(b["h"]))) * r * 0.7
		var sh: float = 1.0 - hop / (r * 3.0)
		(b["shadow"] as Node2D).position = p + Vector2(0, r * 0.95)
		(b["shadow"] as Node2D).scale = Vector2(sh, sh)
		(b["body"] as Node2D).position = p - Vector2(0, hop)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#120f2a"))


func _draw_stripes() -> void:
	var s := size
	var i := -12
	while i < int(s.x / STRIPE_GAP) + 14:
		var x: float = float(i) * STRIPE_GAP
		_stripes.draw_colored_polygon(PackedVector2Array([
			Vector2(x, 0), Vector2(x + 60.0, 0),
			Vector2(x + 60.0 - s.y * 0.5, s.y), Vector2(x - s.y * 0.5, s.y)]), Color(1, 1, 1, 0.025))
		i += 1


func _draw_glow() -> void:
	var s := size
	_glow.draw_rect(Rect2(0, s.y * 0.75, s.x, s.y * 0.25), Color(0.6, 0.2, 1.0, 0.05))
