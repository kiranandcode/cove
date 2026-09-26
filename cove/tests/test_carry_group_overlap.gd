extends SceneTree

const CarryGroup := preload("res://scripts/CarryGroup.gd")

const STEP := 1.0 / 60.0
const STEPS := 240
const TAIL_STEPS := 60

var _failures := 0


class DummyTerminal extends Node2D:
	var display_size: Vector2

	func _init(size: Vector2) -> void:
		display_size = size

	func poll() -> void:
		pass

	func onscreen_size() -> Vector2:
		return display_size


class DummyCarrier extends Node2D:
	var state := "idle"

	func set_state(next: String) -> void:
		state = next

	func set_facing(_direction: float) -> void:
		pass


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _finite(v: Vector2) -> bool:
	return is_finite(v.x) and is_finite(v.y)


func _make_group(parent: Node2D, id: int, at: Vector2,
		display_size := Vector2(400.0, 240.0)) -> Node2D:
	var g = CarryGroup.new()
	g.set_process(false)
	g.term_id = id
	g.position = at
	g._aura = Sprite2D.new()
	g.add_child(g._aura)
	g._term_shadow = Sprite2D.new()
	g.add_child(g._term_shadow)
	g._rig = Node2D.new()
	g.add_child(g._rig)
	g.terminal = DummyTerminal.new(display_size)
	g._rig.add_child(g.terminal)
	g._left = DummyCarrier.new()
	g._right = DummyCarrier.new()
	g._rig.add_child(g._left)
	g._rig.add_child(g._right)
	g._tag = Label.new()
	g._rig.add_child(g._tag)
	g._bang = Label.new()
	g._rig.add_child(g._bang)
	parent.add_child(g)
	return g


# Both calls must see one frozen set of positions, as they do within a rendered
# frame. Resetting the cache lets this headless test simulate many fixed steps
# without waiting for the engine's frame counter.
func _pair_push(a: Node2D, b: Node2D) -> Array:
	CarryGroup._sep_frame = -1
	var pa: Vector2 = a._separation()
	var pb: Vector2 = b._separation()
	return [pa, pb]


func _step_pair(a: Node2D, b: Node2D, delta: float) -> void:
	CarryGroup._sep_frame = -1
	a._process(delta)
	b._process(delta)


func _inside_inclusive(rect: Rect2, point: Vector2) -> bool:
	return point.x >= rect.position.x and point.x <= rect.end.x \
		and point.y >= rect.position.y and point.y <= rect.end.y


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := Node2D.new()
	root.add_child(world)

	# A restored layout or a teleport can put two ground points on precisely the
	# same pixel. Separation needs a stable tie-break there; normalizing a zero
	# delta is invalid, while silently ignoring it leaves the stack permanent.
	var a = _make_group(world, 101, Vector2(100.0, 120.0))
	var b = _make_group(world, 202, Vector2(100.0, 120.0))
	var exact := _pair_push(a, b)
	var pa: Vector2 = exact[0]
	var pb: Vector2 = exact[1]
	_check(_finite(pa) and _finite(pb), "exact overlap produced a non-finite separation")
	_check(pa.length() > 0.001 and pb.length() > 0.001,
		"exactly overlapping termlings received no separation")
	_check((pa + pb).length() < 0.001,
		"exact-overlap separation was not equal and opposite")

	# Pair clearance is the sum of each terminal's personal-space radius. Unequal
	# widths must still produce one equal-and-opposite response, while equal widths
	# retain the old threshold: width * 0.55 + 180.
	var unequal_world := Node2D.new()
	root.add_child(unequal_world)
	var narrow = _make_group(unequal_world, 301, Vector2.ZERO, Vector2(200.0, 160.0))
	var wide = _make_group(unequal_world, 302, Vector2(350.0, 0.0), Vector2(600.0, 260.0))
	var unequal := _pair_push(narrow, wide)
	var narrow_push: Vector2 = unequal[0]
	var wide_push: Vector2 = unequal[1]
	var pair_min_distance := 200.0 * 0.275 + 90.0 + 600.0 * 0.275 + 90.0
	var expected_push := minf((pair_min_distance - 350.0) * 2.8, CarryGroup.SPEED * 2.5)
	_check(narrow_push.length() > 0.001 and wide_push.length() > 0.001,
		"unequal-width overlap produced no separation")
	_check((narrow_push + wide_push).length() < 0.001,
		"unequal-width separation was not equal and opposite")
	_check(absf(narrow_push.length() - expected_push) < 0.001,
		"unequal-width separation ignored the sum of pair radii")
	_check(is_equal_approx(2.0 * (400.0 * 0.275 + 90.0), 400.0 * 0.55 + 180.0),
		"pair radii changed the prior equal-width threshold")

	# Two termlings dropped on the same point each pin their commanded goal there.
	# Drive the real CarryGroup process loop: collision response must move those
	# resting anchors apart as well as their current positions. Otherwise navigation
	# pulls them back together forever and leaves the carriers' walk cycle thrashing.
	var pinned := Vector2(600.0, 300.0)
	a.position = pinned
	b.position = pinned
	a.end_drag_move()
	b.end_drag_move()

	var tail_min := INF
	var tail_max := 0.0
	var first_direction := Vector2.ZERO
	var max_step := 0.0
	var non_idle_tail_frames := 0
	for step in STEPS:
		var old_a: Vector2 = a.position
		var old_b: Vector2 = b.position
		_step_pair(a, b, STEP)
		max_step = maxf(max_step, maxf(a.position.distance_to(old_a), b.position.distance_to(old_b)))
		_check(_finite(a.position) and _finite(b.position),
			"pinned-overlap motion became non-finite at step %d" % step)
		var apart: Vector2 = b.position - a.position
		if apart.length() > 0.001:
			var direction: Vector2 = apart.normalized()
			if first_direction == Vector2.ZERO:
				first_direction = direction
			elif step >= STEPS - TAIL_STEPS:
				_check(direction.dot(first_direction) > 0.99,
					"overlapping termlings swapped sides during settled animation")
		if step >= STEPS - TAIL_STEPS:
			var distance: float = apart.length()
			tail_min = minf(tail_min, distance)
			tail_max = maxf(tail_max, distance)
			if a._left.state != "idle" or a._right.state != "idle" \
					or b._left.state != "idle" or b._right.state != "idle":
				non_idle_tail_frames += 1

	var min_distance: float = a.terminal.onscreen_size().x * 0.55 + 180.0
	_check(a.position.distance_to(b.position) > min_distance * 0.5,
		"pinned termlings remained materially overlapped")
	_check(tail_max - tail_min < 10.0,
		"pinned separation did not settle: tail range %f" % (tail_max - tail_min))
	_check(((a.position + b.position) * 0.5).distance_to(pinned) < 1.0,
		"equal separation drifted the pair away from its pinned target")
	_check(Vector2(a._goal).distance_to(pinned) > min_distance * 0.25 \
			and Vector2(b._goal).distance_to(pinned) > min_distance * 0.25,
		"collision response did not move the pinned resting anchors")
	_check(a.position.distance_to(Vector2(a._goal)) < 0.1 \
			and b.position.distance_to(Vector2(b._goal)) < 0.1,
		"settled termlings kept fighting their pinned goals")
	_check(non_idle_tail_frames == 0,
		"settled pinned termlings kept animating for %d tail frames" % non_idle_tail_frames)
	_check(max_step <= (CarryGroup.SPEED + CarryGroup.SPEED * 2.5) * STEP + 0.001,
		"separation produced an unbounded animation step: %f" % max_step)

	# A user-pinned termling owns its resting point. Ordinary traffic must take the
	# full avoidance step while the pinned position and goal stay bit-for-bit put.
	var yield_world := Node2D.new()
	root.add_child(yield_world)
	var yield_at := Vector2(300.0, 700.0)
	var fixed = _make_group(yield_world, 401, yield_at)
	var free = _make_group(yield_world, 402, yield_at)
	fixed.end_drag_move()
	free.command_move(yield_at)
	for _step in 60:
		_step_pair(fixed, free, STEP)
	_check(fixed.position == yield_at and Vector2(fixed._goal) == yield_at,
		"an unpinned peer moved a pinned termling or its goal")
	_check(free.position.distance_to(yield_at) > 1.0,
		"the unpinned peer did not yield to the pinned termling")

	# Even when a zone is too small to provide full personal space, pinned peers
	# must never escape it. Once each reaches its available edge, no hidden goal
	# fight should keep their carriers walking.
	var zone_world := Node2D.new()
	root.add_child(zone_world)
	var tiny_zone := Rect2(1000.0, 200.0, 40.0, 30.0)
	var zone_at := tiny_zone.get_center()
	var zone_a = _make_group(zone_world, 501, zone_at)
	var zone_b = _make_group(zone_world, 502, zone_at)
	zone_a.assign_zone(tiny_zone)
	zone_b.assign_zone(tiny_zone)
	zone_a.position = zone_at
	zone_b.position = zone_at
	zone_a.end_drag_move()
	zone_b.end_drag_move()
	var zone_stayed_inside := true
	var zone_non_idle_tail := 0
	for step in STEPS:
		_step_pair(zone_a, zone_b, STEP)
		zone_stayed_inside = zone_stayed_inside \
			and _inside_inclusive(tiny_zone, zone_a.position) \
			and _inside_inclusive(tiny_zone, zone_b.position) \
			and _inside_inclusive(tiny_zone, Vector2(zone_a._goal)) \
			and _inside_inclusive(tiny_zone, Vector2(zone_b._goal))
		if step >= STEPS - TAIL_STEPS and (zone_a._left.state != "idle" \
				or zone_a._right.state != "idle" or zone_b._left.state != "idle" \
				or zone_b._right.state != "idle"):
			zone_non_idle_tail += 1
	_check(zone_stayed_inside, "pinned overlap escaped its assigned small zone")
	_check(zone_a.position.distance_to(zone_b.position) > 1.0,
		"pinned peers did not use the small zone's available space")
	_check(zone_non_idle_tail == 0,
		"small-zone pinned peers kept animating for %d tail frames" % zone_non_idle_tail)

	# Restored and teleported frame members wander without pinned goals. Exact
	# overlap in a cramped frame must not let separation eject either ground point.
	var wander_zone_world := Node2D.new()
	root.add_child(wander_zone_world)
	var wander_zone := Rect2(1100.0, 600.0, 40.0, 30.0)
	var wander_at := wander_zone.get_center()
	var wander_a = _make_group(wander_zone_world, 551, wander_at)
	var wander_b = _make_group(wander_zone_world, 552, wander_at)
	wander_a.command_stop()
	wander_b.command_stop()
	wander_a.assign_zone(wander_zone)
	wander_b.assign_zone(wander_zone)
	var wander_stayed_inside := true
	for _step in STEPS:
		_step_pair(wander_a, wander_b, STEP)
		wander_stayed_inside = wander_stayed_inside \
			and _inside_inclusive(wander_zone, wander_a.position) \
			and _inside_inclusive(wander_zone, wander_b.position)
	_check(wander_stayed_inside, "wandering overlap escaped its assigned small zone")
	_check(wander_a.position.distance_to(wander_b.position) > 1.0,
		"wandering peers did not use the small zone's available space")

	# A later command transfers ownership of the target back to navigation. It may
	# move the termling, but collision avoidance must not drag that command target.
	var command_world := Node2D.new()
	root.add_child(command_world)
	var command_at := Vector2(1400.0, 400.0)
	var obstacle = _make_group(command_world, 601, command_at)
	var commanded = _make_group(command_world, 602, command_at)
	obstacle.end_drag_move()
	commanded.end_drag_move()
	var command_goal := command_at + Vector2(500.0, 0.0)
	commanded.command_move(command_goal)
	for _step in 10:
		_step_pair(obstacle, commanded, STEP)
	_check(Vector2(commanded._goal) == command_goal,
		"collision response translated an explicit command target")
	_check(commanded.position.distance_to(command_at) > 1.0,
		"commanded unpinned termling did not move or yield")
	_check(obstacle.position == command_at and Vector2(obstacle._goal) == command_at,
		"commanded traffic displaced its pinned obstacle")

	# A delayed frame must not step through a nearby command target and reverse
	# direction on the next frame. This is independent of pair separation and
	# protects the navigation integrator itself.
	var mover = _make_group(world, 701, Vector2.ZERO)
	mover.command_move(Vector2(10.0, 0.0))
	mover._navigate(0.25)
	_check(_finite(mover.position), "slow-frame navigation became non-finite")
	_check(mover.position.x >= 0.0 and mover.position.x <= 10.0,
		"slow-frame navigation overshot its goal: x=%f" % mover.position.x)

	root.remove_child(world)
	world.free()
	root.remove_child(unequal_world)
	unequal_world.free()
	root.remove_child(yield_world)
	yield_world.free()
	root.remove_child(zone_world)
	zone_world.free()
	root.remove_child(wander_zone_world)
	wander_zone_world.free()
	root.remove_child(command_world)
	command_world.free()
	quit(1 if _failures else 0)
