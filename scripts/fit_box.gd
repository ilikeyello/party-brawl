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
		# Stay clear of the notch / Dynamic Island / rounded corners.
		var ins: Vector4 = GameManager.safe_insets
		var area := Rect2(Vector2(ins.x, ins.y), size - Vector2(ins.x + ins.z, ins.y + ins.w)).grow(-margin)
		var s: float = minf(1.0, minf(area.size.x / need.x, area.size.y / need.y))
		s = maxf(s, 0.2)
		child.size = need
		child.scale = Vector2(s, s)
		child.position = (area.position + (area.size - need * s) * 0.5).floor()
