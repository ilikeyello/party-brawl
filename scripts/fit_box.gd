extends Container
## Centers its child and scales it down (never up) so it always fits the screen.
## Used for menus so they work on everything from big monitors to small phones.

@export var margin: float = 8.0


func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN:
		_fit()


func _process(_delta: float) -> void:
	_fit()


func _fit() -> void:
	for c in get_children():
		if not (c is Control) or not (c as Control).visible:
			continue
		var child := c as Control
		var need := child.get_combined_minimum_size()
		if need.x <= 0.0 or need.y <= 0.0:
			continue
		var avail := size - Vector2(margin, margin) * 2.0
		var s: float = minf(1.0, minf(avail.x / need.x, avail.y / need.y))
		s = maxf(s, 0.2)
		child.size = need
		child.scale = Vector2(s, s)
		child.position = ((size - need * s) * 0.5).floor()
