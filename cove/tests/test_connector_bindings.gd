extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


class DummyTerminal extends Node2D:
	var screen: Node2D

	func _init() -> void:
		screen = self

	func onscreen_size() -> Vector2:
		return Vector2(100, 50)

	func contains_point(p: Vector2) -> bool:
		return Rect2(global_position - onscreen_size() * 0.5, onscreen_size()).has_point(p)


class DummyGroup extends Node2D:
	var terminal: Node2D

	func _init() -> void:
		terminal = DummyTerminal.new()
		add_child(terminal)


func _check(ok: bool, label: String) -> void:
	if not ok:
		push_error(label)
		_failures += 1


func _check_vec(actual: Vector2, expected: Vector2, label: String) -> void:
	if not actual.is_equal_approx(expected):
		push_error("%s: expected %s, got %s" % [label, expected, actual])
		_failures += 1


func _new_cove() -> Node:
	var cove := Cove.new()
	var camera := Camera2D.new()
	camera.zoom = Vector2.ONE
	cove._cam = camera
	cove._bd_snap_mode = true
	cove.add_child(camera)
	return cove


func _add_box(cove: Node, type: String, rect: Rect2) -> Dictionary:
	var shape: Dictionary = cove._bd_new(type)
	if type == "geo":
		shape["geo"] = "rectangle"
	cove._bd_set_rect(shape, rect)
	cove._bd_add(shape)
	return shape


func _add_arrow(cove: Node, a: Vector2, b: Vector2) -> Dictionary:
	var arrow: Dictionary = cove._bd_new("arrow")
	arrow["a"] = cove._bd_a(a)
	arrow["b"] = cove._bd_a(b)
	arrow["bind_a"] = ""
	arrow["bind_b"] = ""
	arrow["bend"] = 0.0
	arrow["head_a"] = false
	arrow["head_b"] = true
	cove._bd_add(arrow)
	return arrow


func _add_line(cove: Node, points: Array) -> Dictionary:
	var line: Dictionary = cove._bd_new("line")
	line["points"] = points.map(func(p: Vector2): return cove._bd_a(p))
	cove._bd_add(line)
	return line


func _test_arrow_gap_binding() -> void:
	var cove := _new_cove()
	cove._cam.zoom = Vector2(8, 8)
	var frame := _add_box(cove, "frame", Rect2(100, 100, 200, 100))
	var gap_point := Vector2(88.1, 150)
	_check(cove._bd_bind_at(gap_point, "") == str(frame["id"]),
		"an arrow end at the live fixture's 11.9-pixel gap should bind to the frame")
	_check(cove._bd_bind_at(Vector2(200, 150), "") == str(frame["id"]),
		"an arrow dropped inside a target should retain the existing binding behavior")
	var inside := _add_arrow(cove, Vector2(0, 150), Vector2(200, 150))
	cove._bd_sel = [str(inside["id"])]
	cove._bd_handle = {"kind": "b"}
	cove._bd_do_handle(Vector2(200, 150), InputEventMouseMotion.new())
	_check(str(inside.get("bind_b", "")) == str(frame["id"]) and not inside.has("bind_b_uv"),
		"an arrow dropped deep inside a target should retain center-ray binding")
	_check_vec(cove._bd_arrow_ends(inside)[1], Vector2(90, 150),
		"a deep-inside bound arrow should still stop beyond the target outline")
	var edge := _add_arrow(cove, Vector2(500, 150), Vector2(100, 150))
	cove._bd_set_arrow_binding(edge, "b", Vector2(100, 150))
	_check(edge.has("bind_b_uv"), "an arrow dropped exactly on a left edge should store that edge anchor")
	_check_vec(cove._bd_arrow_ends(edge)[1], Vector2(100, 150),
		"an exact-edge arrow drop should not jump to the opposite edge")
	var ellipse := _add_box(cove, "geo", Rect2(500, 100, 200, 200))
	ellipse["geo"] = "ellipse"
	_check(cove._bd_bind_at(Vector2(510, 110), "") == "",
		"a point in an ellipse's bounding-box corner should not bind to the ellipse")

	frame["rot"] = PI * 0.5
	var rotated_gap: Vector2 = cove._bd_xform(frame) * Vector2(310, 150)
	_check(cove._bd_bind_at(rotated_gap, "") == str(frame["id"]),
		"near-outline binding should use a rotated target's local outline")
	var outline: PackedVector2Array = cove._bd_bind_outline(str(frame["id"]))
	_check(cove._bd_pts_bounds(outline).is_equal_approx(Rect2(150, 50, 100, 200)),
		"a rotated target's binding hint should follow its visible outline")
	_check(cove._bd_bind_outline(str(ellipse["id"])).size() == 64,
		"a non-rectangular target's binding hint should use its actual outline")
	cove.free()


func _test_binding_respects_snap_mode_and_nearest_target() -> void:
	var cove := _new_cove()
	var frame := _add_box(cove, "frame", Rect2(100, 100, 200, 100))
	var farther := _add_box(cove, "geo", Rect2(70, 130, 20, 40))
	var hidden := _add_box(cove, "geo", Rect2(90, 140, 10, 20))
	hidden["hidden"] = true
	_check(cove._bd_bind_at(Vector2(100, 150), "", true, 0.0) == str(frame["id"]),
		"the exact visible outline should beat a farther or hidden target")
	cove._bd_remove([str(farther["id"]), str(hidden["id"])])
	var inner := _add_box(cove, "geo", Rect2(150, 120, 50, 50))
	_check(cove._bd_bind_at(Vector2(210, 145), "") == str(inner["id"]),
		"a nearby inner rectangle should beat its containing frame")

	cove._bd_snap_mode = false
	var arrow := _add_arrow(cove, Vector2.ZERO, Vector2(90, 150))
	cove._bd_sel = [str(arrow["id"])]
	cove._bd_handle = {"kind": "b"}
	cove._bd_do_handle(Vector2(90, 150), InputEventMouseMotion.new())
	_check(str(arrow.get("bind_b", "")) == "",
		"a near-outline arrow should not acquire a new binding with snapping off")
	var line := _add_line(cove, [Vector2.ZERO, Vector2(100, 175)])
	cove._bd_sel = [str(line["id"])]
	cove._bd_handle = {"kind": "pt", "i": 1}
	cove._bd_do_handle(Vector2(100, 175), InputEventMouseMotion.new())
	_check(str(line.get("bind_b", "")) == "",
		"a line should not acquire a binding with snapping off")
	cove.free()


func _test_joint_move_excludes_carried_termlings() -> void:
	var cove := _new_cove()
	var frame := _add_box(cove, "frame", Rect2(100, 100, 300, 200))
	var group := DummyGroup.new()
	group.position = Vector2(200, 200)
	cove.add_child(group)
	cove._groups[77] = group
	cove._sessions[77] = "binding-test"
	_check(cove._bd_bind_at(Vector2(250, 200), "", true, 0.0) == "term:binding-test",
		"an empty exclusion should not suppress an unzoned termling target")
	cove._zone_of[77] = str(frame["id"])
	_check(cove._bd_bind_at(Vector2(250, 200), [str(frame["id"])], true, 0.0) == "",
		"a jointly moved frame's carried termling should not become a new connector target")
	cove.free()


func _test_near_target_beats_containing_background() -> void:
	var cove := _new_cove()
	_add_box(cove, "geo", Rect2(0, 0, 400, 400))
	var ellipse := _add_box(cove, "geo", Rect2(100, 100, 200, 200))
	ellipse["geo"] = "ellipse"
	_check(cove._bd_bind_at(Vector2(200, 99), "") == str(ellipse["id"]),
		"a nearby top shape should beat a containing background shape")

	var group := DummyGroup.new()
	group.position = Vector2(200, 200)
	cove.add_child(group)
	cove._groups[77] = group
	cove._sessions[77] = "nearest-term"
	_check(cove._bd_bind_at(Vector2(200, 166), "") == "term:nearest-term",
		"a nearby termling should beat a containing background shape")
	cove.free()


func _test_whole_arrow_rebinds_on_release() -> void:
	var cove := _new_cove()
	var frame := _add_box(cove, "frame", Rect2(300, 100, 200, 100))
	var arrow := _add_arrow(cove, Vector2(100, 150), Vector2(200, 150))
	cove._bd_sel = [str(arrow["id"])]
	cove._bd_down = Vector2(150, 150)
	cove._bd_moved = true
	cove._bd_start_move(false)
	var motion := InputEventMouseMotion.new()
	cove._bd_do_move(Vector2(240, 150), motion)
	cove._bd_pointer_up(Vector2(240, 150), InputEventMouseButton.new())

	_check(str(arrow.get("bind_b", "")) == str(frame["id"]),
		"releasing a whole arrow with its tip at a target gap should persist the binding")
	_check_vec(cove._bd_arrow_ends(arrow)[1], Vector2(290, 150),
		"binding a whole-arrow drop should not make its tip jump")

	var original := frame.duplicate(true)
	cove._bd_translate(frame, original, Vector2(40, 25))
	_check_vec(cove._bd_arrow_ends(arrow)[1], Vector2(330, 175),
		"a rebound arrow tip should follow a translated frame")
	cove._bd_set_rect(frame, Rect2(340, 125, 400, 200))
	_check_vec(cove._bd_arrow_ends(arrow)[1], Vector2(330, 225),
		"a rebound arrow should preserve its edge position and fixed gap through resize")
	frame["rot"] = PI * 0.5
	_check_vec(cove._bd_arrow_ends(arrow)[1], Vector2(540, 15),
		"a rebound arrow tip should rotate with its target")
	var before_delete: Vector2 = cove._bd_arrow_ends(arrow)[1]
	cove._bd_remove([str(frame["id"])])
	arrow = cove._bd_by_id[str(arrow["id"])]
	_check(str(arrow.get("bind_b", "")) == "" and not arrow.has("bind_b_uv"),
		"deleting a target should clear an arrow binding and local anchor")
	_check_vec(cove._bd_arrow_ends(arrow)[1], before_delete,
		"deleting a target should freeze the arrow tip in place")
	cove.free()


func _test_whole_line_rebinds_and_detaches() -> void:
	var cove := _new_cove()
	var frame := _add_box(cove, "frame", Rect2(300, 100, 200, 100))
	var line := _add_line(cove, [Vector2(100, 175), Vector2(200, 175)])
	cove._bd_sel = [str(line["id"])]
	cove._bd_down = Vector2(150, 175)
	cove._bd_moved = true
	cove._bd_start_move(false)
	cove._bd_do_move(Vector2(250, 175), InputEventMouseMotion.new())
	cove._bd_pointer_up(Vector2(250, 175), InputEventMouseButton.new())
	_check(str(line.get("bind_b", "")) == str(frame["id"]),
		"releasing a whole line with its endpoint on an outline should bind it")
	_check_vec(cove._bd_pts(line)[1], Vector2(300, 175),
		"binding a whole-line drop should preserve its endpoint")

	cove._bd_sel = [str(line["id"])]
	cove._bd_down = Vector2(250, 175)
	cove._bd_moved = true
	cove._bd_start_move(false)
	cove._bd_do_move(Vector2(150, 175), InputEventMouseMotion.new())
	cove._bd_pointer_up(Vector2(150, 175), InputEventMouseButton.new())
	_check(str(line.get("bind_b", "")) == "" and not line.has("bind_b_uv"),
		"dragging a line away should detach its endpoint")
	_check_vec(cove._bd_pts(line)[1], Vector2(200, 175),
		"detaching a whole line should not make its endpoint jump")
	cove.free()


func _test_whole_line_uses_last_motion_snap_state() -> void:
	var cove := _new_cove()
	cove._bd_snap_mode = false
	var frame := _add_box(cove, "frame", Rect2(300, 100, 200, 100))
	var line := _add_line(cove, [Vector2(100, 175), Vector2(200, 175)])
	cove._bd_sel = [str(line["id"])]
	cove._bd_down = Vector2(150, 175)
	cove._bd_moved = true
	cove._bd_start_move(false)
	var motion := InputEventMouseMotion.new()
	motion.meta_pressed = true
	cove._bd_do_move(Vector2(245, 175), motion)
	cove._bd_pointer_up(Vector2(245, 175), InputEventMouseButton.new())
	_check_vec(cove._bd_pts(line)[1], Vector2(300, 175),
		"the final snapped whole-line position should reach the target outline")
	_check(str(line.get("bind_b", "")) == str(frame["id"]),
		"release should bind using the snap state that produced the final geometry")
	cove.free()


func _test_line_endpoint_bindings_follow_geometry() -> void:
	var cove := _new_cove()
	var left := _add_box(cove, "frame", Rect2(0, 0, 100, 100))
	var right := _add_box(cove, "geo", Rect2(300, 100, 200, 200))
	var line := _add_line(cove, [Vector2(100, 30), Vector2(200, 120), Vector2(300, 250)])
	cove._bd_sel = [str(line["id"])]
	var motion := InputEventMouseMotion.new()

	cove._bd_handle = {"kind": "pt", "i": 0}
	cove._bd_do_handle(Vector2(100, 30), motion)
	cove._bd_handle = {"kind": "pt", "i": 2}
	cove._bd_do_handle(Vector2(300, 250), motion)

	_check(str(line.get("bind_a", "")) == str(left["id"]),
		"a line's first point should bind independently")
	_check(str(line.get("bind_b", "")) == str(right["id"]),
		"a line's last point should bind independently")
	var points: PackedVector2Array = cove._bd_pts(line)
	_check_vec(points[0], Vector2(100, 30), "binding should preserve the first edge position")
	_check_vec(points[points.size() - 1], Vector2(300, 250),
		"binding should preserve the last edge position")

	var old_left := left.duplicate(true)
	cove._bd_translate(left, old_left, Vector2(40, 20))
	points = cove._bd_pts(line)
	_check_vec(points[0], Vector2(140, 50), "a line endpoint should follow target translation")

	cove._bd_set_rect(right, Rect2(300, 100, 400, 300))
	points = cove._bd_pts(line)
	_check_vec(points[points.size() - 1], Vector2(300, 325),
		"a line endpoint should keep its edge-local fraction when the target resizes")

	right["rot"] = PI * 0.5
	points = cove._bd_pts(line)
	_check_vec(points[points.size() - 1], Vector2(425, 50),
		"a line endpoint should rotate with its target")
	cove.free()


func _test_lines_bind_only_from_explicit_endpoint_gestures() -> void:
	var cove := _new_cove()
	var frame := _add_box(cove, "frame", Rect2(100, 100, 300, 200))
	var deep := _add_line(cove, [Vector2(250, 200), Vector2(500, 200)])
	cove._bd_sel = [str(deep["id"])]
	cove._bd_handle = {"kind": "pt", "i": 0}
	cove._bd_do_handle(Vector2(250, 200), InputEventMouseMotion.new())
	_check(str(deep.get("bind_a", "")) == "",
		"a line endpoint deep inside a frame should not bind to its outline")

	var crossing := _add_line(cove, [Vector2(40, 220), Vector2(460, 220)])
	cove._bd_sel = [str(crossing["id"])]
	cove._bd_down = Vector2(250, 220)
	cove._bd_moved = true
	cove._bd_start_move(false)
	cove._bd_do_move(Vector2(260, 220), InputEventMouseMotion.new())
	cove._bd_pointer_up(Vector2(260, 220), InputEventMouseButton.new())
	_check(str(crossing.get("bind_a", "")) == "" and str(crossing.get("bind_b", "")) == "",
		"a whole line crossing a frame should not bind when neither endpoint is near its outline")

	var carried := _add_line(cove, [Vector2(110, 140), Vector2(250, 150), Vector2(390, 140)])
	cove._bd_sel = [str(frame["id"])]
	cove._bd_down = Vector2(200, 100)
	cove._bd_moved = true
	cove._bd_start_move(false)
	cove._bd_do_move(Vector2(230, 125), InputEventMouseMotion.new())
	cove._bd_pointer_up(Vector2(230, 125), InputEventMouseButton.new())
	_check(str(carried.get("bind_a", "")) == "" and str(carried.get("bind_b", "")) == "",
		"moving a frame should not auto-bind a line merely carried inside it")
	cove.free()


func _test_moving_target_adopts_touching_connectors() -> void:
	var cove := _new_cove()
	var frame := _add_box(cove, "frame", Rect2(100, 100, 200, 100))
	var arrow := _add_arrow(cove, Vector2(-100, 150), Vector2(90, 150))
	var line := _add_line(cove, [Vector2(-100, 175), Vector2(100, 175)])
	arrow["locked"] = true
	line["locked"] = true
	cove._bd_sel = [str(frame["id"])]
	cove._bd_down = Vector2(200, 150)
	cove._bd_moved = true
	cove._bd_start_move(false)
	_check(str(arrow.get("bind_b", "")) == str(frame["id"]),
		"moving a target should adopt an old arrow touching its outline")
	_check(str(line.get("bind_b", "")) == str(frame["id"]),
		"moving a target should adopt an old line touching its outline")
	cove._bd_do_move(Vector2(240, 175), InputEventMouseMotion.new())
	cove._bd_pointer_up(Vector2(240, 175), InputEventMouseButton.new())
	_check_vec(cove._bd_arrow_ends(arrow)[1], Vector2(130, 175),
		"an adopted arrow endpoint should follow the target without jumping")
	var points: PackedVector2Array = cove._bd_pts(line)
	_check_vec(points[points.size() - 1], Vector2(140, 200),
		"an adopted line endpoint should follow the target")
	cove._zone_of[77] = str(frame["id"])
	_check(cove._bd_binding_moves_with("term#77", [str(frame["id"])]),
		"a connector should retain its binding to a termling carried by the moved frame")
	cove.free()


func _test_all_moved_targets_adopt_touching_connectors() -> void:
	var cove := _new_cove()
	var left := _add_box(cove, "frame", Rect2(0, 0, 100, 100))
	var right := _add_box(cove, "frame", Rect2(300, 0, 100, 100))
	var left_line := _add_line(cove, [Vector2(-100, 25), Vector2(0, 25)])
	var right_line := _add_line(cove, [Vector2(500, 75), Vector2(400, 75)])
	cove._bd_sel = [str(left["id"]), str(right["id"])]
	cove._bd_press_id = str(left["id"])
	cove._bd_down = Vector2(0, 50)
	cove._bd_moved = true
	cove._bd_start_move(false)
	_check(str(left_line.get("bind_b", "")) == str(left["id"]),
		"the pressed frame should adopt its old connector")
	_check(str(right_line.get("bind_b", "")) == str(right["id"]),
		"a second selected frame should also adopt its old connector")
	cove.free()

	var nested_cove := _new_cove()
	var outer := _add_box(nested_cove, "frame", Rect2(0, 200, 500, 300))
	var inner := _add_box(nested_cove, "geo", Rect2(100, 250, 100, 100))
	var inner_line := _add_line(nested_cove, [Vector2(-50, 300), Vector2(100, 300)])
	nested_cove._bd_sel = [str(outer["id"])]
	nested_cove._bd_press_id = str(outer["id"])
	nested_cove._bd_down = Vector2(0, 250)
	nested_cove._bd_moved = true
	nested_cove._bd_start_move(false)
	_check(str(inner_line.get("bind_b", "")) == str(inner["id"]),
		"a box carried by a frame should adopt its old connector before both move")
	nested_cove.free()

	var rotated_cove := _new_cove()
	var rotated := _add_box(rotated_cove, "frame", Rect2(100, 100, 200, 100))
	rotated["rot"] = PI * 0.5
	var rotated_arrow := _add_arrow(rotated_cove, Vector2(200, 400), Vector2(200, 260))
	var internal_line := _add_line(rotated_cove, [Vector2(200, 60), Vector2(200, 249)])
	var outside_line := _add_line(rotated_cove, [Vector2(110, 110), Vector2(290, 190)])
	rotated_cove._bd_sel = [str(rotated["id"])]
	rotated_cove._bd_press_id = str(rotated["id"])
	rotated_cove._bd_down = Vector2(150, 150)
	rotated_cove._bd_moved = true
	rotated_cove._bd_start_move(false)
	_check(str(rotated_arrow.get("bind_b", "")) == str(rotated["id"]),
		"a rotated frame should adopt an old arrow at its visual tip gap")
	_check(str(internal_line.get("bind_a", "")) == "" and str(internal_line.get("bind_b", "")) == "",
		"a line wholly inside a rotated frame should not acquire an edge binding")
	rotated_cove._bd_do_move(Vector2(190, 175), InputEventMouseMotion.new())
	_check_vec(rotated_cove._bd_arrow_ends(rotated_arrow)[1], Vector2(240, 285),
		"an adopted arrow should follow a rotated frame")
	_check_vec(rotated_cove._bd_pts(internal_line)[0], Vector2(240, 85),
		"a connector visually inside a rotated frame should move with it")
	_check_vec(rotated_cove._bd_pts(outside_line)[0], Vector2(110, 110),
		"a connector visually outside a rotated frame should not be carried")
	rotated_cove.free()


func _test_target_deletion_freezes_line_endpoint() -> void:
	var cove := _new_cove()
	var target := _add_box(cove, "geo", Rect2(100, 100, 200, 100))
	var line := _add_line(cove, [Vector2(150, 100), Vector2(500, 300)])
	cove._bd_sel = [str(line["id"])]
	cove._bd_handle = {"kind": "pt", "i": 0}
	cove._bd_do_handle(Vector2(150, 100), InputEventMouseMotion.new())
	target["rot"] = PI * 0.5
	var before: Vector2 = cove._bd_pts(line)[0]

	cove._bd_remove([str(target["id"])])
	line = cove._bd_by_id[str(line["id"])]
	var after: Vector2 = cove._bd_pts(line)[0]
	_check(str(line.get("bind_a", "")) == "", "deleting a target should clear a line binding")
	_check(not line.has("bind_a_uv"), "deleting a target should clear its line anchor")
	_check_vec(after, before, "deleting a target should freeze the line endpoint in place")
	cove.free()


func _test_bound_line_clone_and_history() -> void:
	var cove := _new_cove()
	var target := _add_box(cove, "frame", Rect2(0, 0, 100, 100))
	var line := _add_line(cove, [Vector2(100, 25), Vector2(220, 80)])
	cove._bd_sel = [str(line["id"])]
	cove._bd_handle = {"kind": "pt", "i": 0}
	cove._bd_do_handle(Vector2(100, 25), InputEventMouseMotion.new())
	var original_point: Vector2 = cove._bd_pts(line)[0]

	var pair_ids: Array = cove._bd_clone([str(target["id"]), str(line["id"])], Vector2(25, 15))
	var target_copy: Dictionary = cove._bd_by_id[pair_ids[0]]
	var line_copy: Dictionary = cove._bd_by_id[pair_ids[1]]
	_check(str(line_copy.get("bind_a", "")) == str(target_copy["id"]),
		"copying a line with its target should remap the binding to the copied target")
	_check_vec(cove._bd_pts(line_copy)[0], original_point + Vector2(25, 15),
		"a remapped copied line should preserve its target-local anchor")

	var line_only_ids: Array = cove._bd_clone([str(line["id"])], Vector2(60, 30))
	var line_only: Dictionary = cove._bd_by_id[line_only_ids[0]]
	_check(str(line_only.get("bind_a", "")) == "", "copying a bound line alone should detach it")
	_check(not line_only.has("bind_a_uv"), "a detached line copy should discard its old anchor")
	_check_vec(cove._bd_pts(line_only)[0], original_point + Vector2(60, 30),
		"a detached line copy should freeze where the copied endpoint is drawn")

	var snap: String = cove._bd_snapshot()
	cove._bd_restore(snap)
	line = cove._bd_by_id[str(line["id"])]
	_check(str(line.get("bind_a", "")) == str(target["id"]),
		"snapshot restore should retain a bound line's target")
	_check_vec(cove._bd_pts(line)[0], original_point,
		"snapshot restore should retain a bound line's target-local position")
	cove.free()


func _test_bound_connectors_flip_with_targets() -> void:
	var line_cove := _new_cove()
	var line_target := _add_box(line_cove, "frame", Rect2(0, 0, 100, 100))
	var line := _add_line(line_cove, [Vector2(100, 25), Vector2(220, 25)])
	line_cove._bd_set_line_binding(line, "a", Vector2(100, 25))
	line_cove._bd_sel = [str(line_target["id"]), str(line["id"])]
	line_cove._bd_flip(true)
	_check_vec(line_cove._bd_pts(line)[0], Vector2(120, 25),
		"a bound line endpoint should mirror with its selected target")
	line_cove.free()

	var arrow_cove := _new_cove()
	var arrow_target := _add_box(arrow_cove, "frame", Rect2(0, 0, 100, 100))
	var arrow := _add_arrow(arrow_cove, Vector2(-50, 50), Vector2(-10, 50))
	arrow_cove._bd_set_arrow_binding(arrow, "b", Vector2(-10, 50), true)
	arrow_cove._bd_sel = [str(arrow_target["id"]), str(arrow["id"])]
	arrow_cove._bd_flip(true)
	_check_vec(arrow_cove._bd_arrow_ends(arrow)[1], Vector2(60, 50),
		"a bound arrow's visible gap should mirror with its selected target")
	arrow_cove.free()

	var resize_cove := _new_cove()
	resize_cove._bd_snap_mode = false
	var resize_target := _add_box(resize_cove, "frame", Rect2(0, 0, 100, 100))
	var resize_line := _add_line(resize_cove, [Vector2(100, 25), Vector2(220, 25)])
	resize_cove._bd_set_line_binding(resize_line, "a", Vector2(100, 25))
	resize_cove._bd_sel = [str(resize_target["id"]), str(resize_line["id"])]
	resize_cove._bd_handle = {"kind": "resize", "name": "r"}
	resize_cove._bd_snap_orig()
	resize_cove._bd_do_resize(Vector2(-220, 50), InputEventMouseMotion.new())
	_check_vec(resize_cove._bd_pts(resize_line)[0], Vector2(-100, 25),
		"a negative group resize should mirror a bound endpoint with its target")
	resize_cove.free()

	var target_only_cove := _new_cove()
	target_only_cove._bd_snap_mode = false
	var target_only := _add_box(target_only_cove, "frame", Rect2(0, 0, 100, 100))
	var external_line := _add_line(target_only_cove, [Vector2(100, 25), Vector2(220, 25)])
	target_only_cove._bd_set_line_binding(external_line, "a", Vector2(100, 25))
	target_only_cove._bd_sel = [str(target_only["id"])]
	target_only_cove._bd_handle = {"kind": "resize", "name": "r"}
	target_only_cove._bd_snap_orig()
	target_only_cove._bd_do_resize(Vector2(-100, 50), InputEventMouseMotion.new())
	_check_vec(target_only_cove._bd_pts(external_line)[0], Vector2(-100, 25),
		"a target-only negative resize should carry its external bound endpoint")
	target_only_cove._bd_do_resize(Vector2(100, 50), InputEventMouseMotion.new())
	_check_vec(target_only_cove._bd_pts(external_line)[0], Vector2(100, 25),
		"crossing back over a resize anchor should restore the original bound edge")
	target_only_cove.free()


func _test_missing_termling_uses_latest_fallback() -> void:
	var cove := _new_cove()
	var group := DummyGroup.new()
	group.position = Vector2(200, 200)
	cove.add_child(group)
	cove._groups[77] = group
	cove._sessions[77] = "binding-test"
	var line := _add_line(cove, [Vector2(250, 200), Vector2(500, 200)])
	line["bind_a"] = "term#77"
	line["bind_a_uv"] = [1.0, 0.5]
	var stale_snapshot: String = cove._bd_snapshot()
	cove._bd_undo_stack = [stale_snapshot]
	line["bind_a"] = "term:binding-test" # save-time migration after the snapshot
	group.position = Vector2(300, 230)
	group.terminal.global_position = Vector2(300, 230) # detached test nodes do not propagate transforms
	var latest: Vector2 = cove._bd_pts(line)[0]
	_check_vec(latest, Vector2(350, 230), "the bound line should follow its live termling")
	cove._bd_dirty = false
	cove._bd_save_in = -1.0
	_check(cove._bd_freeze_term_bindings(-1, false),
		"a save or graceful exit should refresh every live termling fallback")
	_check(not cove._bd_dirty and cove._bd_save_in < 0.0,
		"an immediate save-path refresh should not schedule another save")
	cove._bd_freeze_term_bindings(77)
	cove._groups.erase(77)
	_check_vec(cove._bd_pts(line)[0], latest,
		"a missing termling should leave its connector at the latest visible position")
	_check(str(line.get("bind_a", "")) == "term:binding-test",
		"a transiently missing termling should retain its stable session binding")
	_check(cove._bd_dirty and is_equal_approx(cove._bd_save_in, 0.4),
		"refreshing a termling fallback should schedule a durable board save")
	var line_id := str(line["id"])
	cove._bd_undo()
	line = cove._bd_by_id[line_id]
	_check_vec(cove._bd_pts(line)[0], latest,
		"undo should not restore a stale fallback after the termling disappears")
	cove._bd_sel = [line_id]
	cove._bd_nudge(KEY_RIGHT, false)
	_check_vec(cove._bd_pts(line)[0], latest + Vector2.RIGHT,
		"a missing-term fallback should still respond to an intentional edit")
	cove._bd_undo()
	line = cove._bd_by_id[line_id]
	_check_vec(cove._bd_pts(line)[0], latest,
		"an intentional fallback edit should remain independently undoable")
	cove.free()


func _test_deleted_connector_history_keeps_latest_term_fallback() -> void:
	var cove := _new_cove()
	var group := DummyGroup.new()
	group.position = Vector2(200, 200)
	cove.add_child(group)
	cove._groups[77] = group
	cove._sessions[77] = "binding-test"
	var line := _add_line(cove, [Vector2(250, 200), Vector2(500, 200)])
	line["bind_a"] = "term:binding-test"
	line["bind_a_uv"] = [1.0, 0.5]
	group.position = Vector2(300, 230)
	group.terminal.global_position = Vector2(300, 230)
	var latest := Vector2(350, 230)
	var line_id := str(line["id"])
	cove._bd_sel = [line_id]
	cove._bd_delete_selected()
	_check(not cove._bd_by_id.has(line_id), "the connector should be absent before undo")
	cove._bd_freeze_term_bindings(77)
	cove._groups.erase(77)
	cove._bd_undo()
	line = cove._bd_by_id[line_id]
	_check_vec(cove._bd_pts(line)[0], latest,
		"undoing connector deletion after term loss should use its latest visible fallback")
	cove.free()


func _test_term_loss_during_gesture_keeps_history_semantics() -> void:
	var cove := _new_cove()
	var group := DummyGroup.new()
	group.position = Vector2(200, 200)
	cove.add_child(group)
	cove._groups[77] = group
	cove._sessions[77] = "binding-test"
	var line := _add_line(cove, [Vector2(250, 200), Vector2(500, 200)])
	line["bind_a"] = "term:binding-test"
	line["bind_a_uv"] = [1.0, 0.5]
	group.position = Vector2(300, 230)
	group.terminal.global_position = Vector2(300, 230)
	var latest := Vector2(350, 230)
	cove._bd_sel = [str(line["id"])]
	cove._bd_down = Vector2(400, 230)
	cove._bd_moved = true
	cove._bd_start_move(false)
	cove._bd_do_move(Vector2(420, 230), InputEventMouseMotion.new())
	cove._bd_freeze_term_bindings(77)
	cove._groups.erase(77)
	cove._bd_cancel_gesture()
	line = cove._bd_by_id[str(line["id"])]
	_check_vec(cove._bd_pts(line)[0], latest,
		"cancelling after term loss should restore the endpoint's gesture-start fallback")

	var no_op := _new_cove()
	var no_op_group := DummyGroup.new()
	no_op_group.position = Vector2(200, 200)
	no_op.add_child(no_op_group)
	no_op._groups[77] = no_op_group
	no_op._sessions[77] = "binding-test"
	var no_op_line := _add_line(no_op, [Vector2(250, 200), Vector2(500, 200)])
	no_op_line["bind_a"] = "term:binding-test"
	no_op_line["bind_a_uv"] = [1.0, 0.5]
	no_op._bd_redo_stack = ["keep"]
	no_op._bd_begin()
	no_op_group.position = Vector2(300, 230)
	no_op_group.terminal.global_position = Vector2(300, 230)
	no_op._bd_commit()
	_check(no_op._bd_undo_stack.is_empty() and no_op._bd_redo_stack == ["keep"],
		"term motion during a no-op board gesture should not create history or clear redo")
	no_op.free()
	cove.free()


func _test_term_fallbacks_are_kept_per_target() -> void:
	var cove := _new_cove()
	var group_a := DummyGroup.new()
	group_a.position = Vector2(200, 200)
	cove.add_child(group_a)
	cove._groups[77] = group_a
	cove._sessions[77] = "term-a"
	var group_b := DummyGroup.new()
	group_b.position = Vector2(600, 200)
	cove.add_child(group_b)
	cove._groups[88] = group_b
	cove._sessions[88] = "term-b"
	var line := _add_line(cove, [Vector2(250, 200), Vector2(500, 200)])
	line["bind_a"] = "term:term-a"
	line["bind_a_uv"] = [1.0, 0.5]
	var stale_a: String = cove._bd_snapshot()
	group_a.position = Vector2(300, 230)
	group_a.terminal.global_position = Vector2(300, 230)
	cove._bd_freeze_term_bindings(77)
	cove._groups.erase(77)
	cove._bd_clear_binding(line, "a")
	line["bind_a"] = "term:term-b"
	line["bind_a_uv"] = [0.0, 0.5]
	group_b.position = Vector2(700, 240)
	group_b.terminal.global_position = Vector2(700, 240)
	cove._bd_freeze_term_bindings(88)
	cove._groups.erase(88)
	cove._bd_restore(stale_a)
	line = cove._bd_by_id[str(line["id"])]
	_check_vec(cove._bd_pts(line)[0], Vector2(350, 230),
		"a later target loss should not overwrite an older target's fallback")
	cove.free()


func _test_legacy_unbound_connectors() -> void:
	var cove := _new_cove()
	var legacy := JSON.stringify([
		{"id": "old-arrow", "type": "arrow", "a": [10, 20], "b": [80, 90], "bend": 0,
			"color": "black", "fill": "none", "dash": "solid", "size": "m", "font": "draw", "text": ""},
		{"id": "old-line", "type": "line", "points": [[4, 5], [20, 25], [40, 10]],
			"color": "black", "fill": "none", "dash": "solid", "size": "m", "font": "draw", "text": ""},
	])
	cove._bd_restore(legacy)
	var arrow: Dictionary = cove._bd_by_id["old-arrow"]
	var line: Dictionary = cove._bd_by_id["old-line"]
	var ends: Array = cove._bd_arrow_ends(arrow)
	var points: PackedVector2Array = cove._bd_pts(line)
	_check_vec(ends[0], Vector2(10, 20), "an old unbound arrow should retain its start")
	_check_vec(ends[1], Vector2(80, 90), "an old unbound arrow should retain its end")
	_check_vec(points[0], Vector2(4, 5), "an old unbound line should retain its first point")
	_check_vec(points[points.size() - 1], Vector2(40, 10),
		"an old unbound line should retain its last point")
	cove.free()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_arrow_gap_binding()
	_test_binding_respects_snap_mode_and_nearest_target()
	_test_joint_move_excludes_carried_termlings()
	_test_near_target_beats_containing_background()
	_test_whole_arrow_rebinds_on_release()
	_test_whole_line_rebinds_and_detaches()
	_test_whole_line_uses_last_motion_snap_state()
	_test_line_endpoint_bindings_follow_geometry()
	_test_lines_bind_only_from_explicit_endpoint_gestures()
	_test_moving_target_adopts_touching_connectors()
	_test_all_moved_targets_adopt_touching_connectors()
	_test_target_deletion_freezes_line_endpoint()
	_test_bound_line_clone_and_history()
	_test_bound_connectors_flip_with_targets()
	_test_missing_termling_uses_latest_fallback()
	_test_deleted_connector_history_keeps_latest_term_fallback()
	_test_term_loss_during_gesture_keeps_history_semantics()
	_test_term_fallbacks_are_kept_per_target()
	_test_legacy_unbound_connectors()
	quit(1 if _failures else 0)
