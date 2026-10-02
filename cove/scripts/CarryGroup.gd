# Two carriers hauling one terminal. Wanders autonomously, but can be commanded
# (move to a point / follow another group) by the control channel, and shows the
# terminal's agent state (claude/codex/muse/opencode) + an attention marker. Grab and
# drag to pick it up; the carriers hang on and it falls to the ground on release.
extends Node2D

const TERM := preload("res://scenes/TermCritter.tscn")
const CarrierScript := preload("res://scripts/Carrier.gd")
const ShadowUtil := preload("res://scripts/ShadowUtil.gd")

const SPEED := 90.0
const GRAVITY := 2800.0
const BOUNCE := 0.30
const LIFT_H := 250.0
# Idle wander stays within this radius of the termling's "home" anchor, so a
# termling keeps to its neighbourhood instead of roaming the whole ground. Home
# is set where it spawns/lands and re-set wherever you drop it (drag = zoning).
const WANDER_RADIUS := 260.0

const AGENT_COLORS := {
	"claude": Color(0.90, 0.58, 0.30),
	"codex": Color(0.30, 0.80, 0.70),
	"muse": Color(0.30, 0.58, 0.95),
	"opencode": Color(0.62, 0.52, 0.92),
	"shell": Color(0.5, 0.5, 0.55),
	"page": Color(1.0, 0.76, 0.40),   # a Vibefox page critter (a browser tab)
}

var term_id := -1
var terminal: Node2D
var bounds := Rect2(0, 0, 1280, 800)

var _rig: Node2D
var _left: Node2D
var _right: Node2D
var _term_shadow: Sprite2D
var _aura: Sprite2D
var _tag: Label
var _bang: Label

var _state := "wander"    # wander | lifted | falling
var _target := Vector2.ZERO
var _wait := 0.0
var _t := 0.0
var _fall_vel := 0.0
var _recover := 0.0

var _agent := "shell"
var _busy := false
var _attention := false
var _goal = null          # Vector2 commanded target, or null = wander
var _dragging := false    # the user is sliding this termling around by the mouse
var _home := Vector2.ZERO  # centre of the idle-wander neighbourhood
var _home_set := false     # anchored once position is final (first _process tick)
var _zone = null           # Rect2 the termling is confined to, or null = free wander
var _shown_agent := ""     # agent the tag/colour were last set for (see _update_indicators)
var _crew_awake := true    # carriers animating (paused while the whole group is off screen)

# Every group's ground point, gathered once per frame for _separation (a method
# call per sibling per group was ~5k GDScript calls a frame with 70 termlings).
static var _sep_frame := -1
static var _sep_pos := PackedVector2Array()
static var _sep_ok := PackedByteArray()   # 1 where the child at that index is a group


func setup(id: int, path: String, world_bounds: Rect2) -> void:
	term_id = id
	bounds = world_bounds

	_aura = ShadowUtil.make(360.0, 1.0, 0.0)  # round soft glow, coloured per agent
	add_child(_aura)
	_term_shadow = ShadowUtil.make(200.0, 0.4, 0.34)
	add_child(_term_shadow)

	_rig = Node2D.new()
	add_child(_rig)
	_left = CarrierScript.new(); _rig.add_child(_left)
	_right = CarrierScript.new(); _rig.add_child(_right)
	terminal = TERM.instantiate()
	terminal.setup(id, path)
	_rig.add_child(terminal)

	_tag = _make_label(13, Color(0.85, 0.88, 0.95))
	_rig.add_child(_tag)
	_bang = _make_label(28, Color(1.0, 0.85, 0.3))
	_bang.text = "!"
	_bang.visible = false
	_rig.add_child(_bang)

	_pick_target()


func _make_label(sz: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 4)
	return l


# --- agent state (from Cove's kitty poll / notifications) ---------------

func set_agent(agent: String, busy: bool) -> void:
	_agent = agent
	_busy = busy


func set_attention(on: bool) -> void:
	_attention = on


func get_ground_pos() -> Vector2:
	return position


# --- commands ---------------------------------------------------------------

func command_move(world_pos: Vector2) -> void:
	_goal = world_pos


func command_stop() -> void:
	# Wander around wherever it is now, not back across the whole map.
	_goal = null
	_home = position
	_home_set = true
	_pick_target()


# --- drag-to-move: the mouse slides the termling along the ground ------------

func begin_drag_move() -> void:
	_dragging = true
	_goal = null


# Press-and-hold picked us up: a little hop so the lift is visible before the
# mouse moves (the wander branch eases the rig back down).
func pickup_hop() -> void:
	_rig.position.y = -16.0


func set_drag_pos(world_pos: Vector2) -> void:
	# No clamp: drag a termling anywhere. It holds where dropped (end_drag_move
	# sets _goal), the ground grid follows the camera, and Cmd+K finds strays.
	# Only idle wander stays within `bounds`.
	position = world_pos


func end_drag_move() -> void:
	# Dropping a termling relocates its neighbourhood: it holds here, then wanders
	# only around this spot. This is the "zoning" gesture — drag a team together.
	_dragging = false
	_home = position
	_home_set = true
	_goal = position   # hold where it was dropped rather than wandering straight off


func _pick_target() -> void:
	if _zone != null:
		# Confined to a zone: pick a ground point that keeps the whole termling
		# inside it (the screen rides above its crew), clear of the border. A zone
		# too small for that just gets the middle.
		var z: Rect2 = _zone
		var sz: Vector2 = terminal.onscreen_size() if terminal else Vector2.ZERO
		var lift := sz.y * 0.85   # ground point -> screen centre, when standing
		if terminal and _state != "lifted" and _state != "falling":
			lift = maxf(0.0, position.y - terminal.global_position.y)
		var lo := z.position + Vector2(sz.x * 0.5 + 60.0, lift + sz.y * 0.5 + 30.0)
		var hi := z.end - Vector2(sz.x * 0.5 + 60.0, 50.0)
		var t := Vector2(randf(), randf())
		_target = Vector2(
			lerpf(lo.x, hi.x, t.x) if hi.x > lo.x else z.get_center().x,
			lerpf(lo.y, hi.y, t.y) if hi.y > lo.y else clampf(lo.y, z.position.y, z.end.y))
		return
	var c := _home if _home_set else position
	var ang := randf() * TAU
	var r := sqrt(randf()) * WANDER_RADIUS   # sqrt = uniform over the disc
	_target = c + Vector2(cos(ang), sin(ang)) * r
	# Keep the pick on the ground even when home sits near the world edge.
	_target.x = clampf(_target.x, bounds.position.x + 160, bounds.end.x - 160)
	_target.y = clampf(_target.y, bounds.position.y + 160, bounds.end.y - 120)


# --- zones: confine idle wander to a named region on the ground --------------

# Confine to a zone. Recentres home there and, if it's idling, sends it inside
# now rather than waiting for the next re-pick. A following/lifted termling keeps
# its motion; the zone just takes effect once it's wandering again.
func assign_zone(rect: Rect2) -> void:
	_zone = rect
	_home = rect.get_center()
	_home_set = true
	if _state != "lifted" and _state != "falling" and not _dragging and _goal == null:
		_pick_target()


func clear_zone() -> void:
	_zone = null


# Its zone (a frame/box on the board) moved: carry the termling along, keeping
# its home, wander target and any commanded goal in step.
func translate_by(delta: Vector2) -> void:
	position += delta
	_home += delta
	_target += delta
	if _goal != null:
		_goal += delta
	if _zone != null:
		_zone = Rect2(_zone.position + delta, _zone.size)


func zone_rect():
	return _zone


func _carry_h() -> float:
	return terminal.onscreen_size().y * 0.5 + 58.0


func _process(delta: float) -> void:
	_t += delta
	terminal.poll()
	_layout(delta)
	_update_indicators(delta)
	# Off screen, the carriers' walk cycle is invisible: pause it. Movement and
	# state still run here, so nothing jumps when the group comes back into view.
	var awake := _group_on_screen()
	if awake != _crew_awake:
		_crew_awake = awake
		_left.set_process(awake)
		_right.set_process(awake)

	match _state:
		"lifted":
			_left.set_state("panic"); _right.set_state("panic")
		"falling":
			_left.set_state("panic"); _right.set_state("panic")
			_fall_vel += GRAVITY * delta
			_rig.position.y += _fall_vel * delta
			if _rig.position.y >= 0.0:
				if _fall_vel > 700.0:
					_rig.position.y = 0.0
					_fall_vel = -_fall_vel * BOUNCE
				else:
					_rig.position.y = 0.0
					_fall_vel = 0.0
					_state = "wander"
					_recover = 0.9
					_left.set_airborne(false); _right.set_airborne(false)
			_restore_shadow(delta)
		_:  # wander / commanded / dragged
			# Anchor the wander neighbourhood once Cove has placed us (position is
			# still default during setup(), so we can't do this there).
			if not _home_set:
				_home = position
				_home_set = true
				_pick_target()
			_rig.position.y = lerp(_rig.position.y, 0.0, 12.0 * delta)
			if _dragging:
				# The mouse owns the position; carriers just hustle to keep up.
				_left.set_state("walk"); _right.set_state("walk")
			else:
				if _recover > 0.0:
					_recover -= delta
					_left.set_state("surprised"); _right.set_state("surprised")
				else:
					_navigate(delta)
				position += _separation() * delta
			_restore_shadow(delta)


func _navigate(delta: float) -> void:
	var tgt: Vector2 = _goal if _goal != null else _target
	var to := tgt - position
	var dist := to.length()
	var stop_d := 8.0 if _goal != null else 6.0
	if dist > stop_d:
		var dir := to / dist
		# agents that are busy scurry a little faster
		var spd := SPEED * (1.25 if _busy else 1.0)
		position += dir * spd * delta
		_left.set_state("walk"); _right.set_state("walk")
		_left.set_facing(dir.x); _right.set_facing(dir.x)
	else:
		_left.set_state("idle"); _right.set_state("idle")
		if _goal == null:
			_wait -= delta
			if _wait <= 0.0:
				_pick_target()
				_wait = randf_range(1.2, 3.5)


# Push away from nearby groups so the roster doesn't clump, but keep the personal
# space modest so termlings still drift close enough to occlude now and then (a
# little depth overlap reads as a living crowd). Firm push, not a big radius.
func _separation() -> Vector2:
	var push := Vector2.ZERO
	var parent := get_parent()
	if parent == null:
		return push
	var min_d: float = terminal.onscreen_size().x * 0.55 + 180.0
	var frame := Engine.get_process_frames()
	if _sep_frame != frame or _sep_pos.size() != parent.get_child_count():
		_sep_frame = frame
		var kids := parent.get_children()
		_sep_pos.resize(kids.size())
		_sep_ok.resize(kids.size())
		for i in kids.size():
			var ok: bool = kids[i].has_method("get_ground_pos")
			_sep_ok[i] = 1 if ok else 0
			_sep_pos[i] = kids[i].get_ground_pos() if ok else Vector2.ZERO
	var me := get_index()
	var min_d2 := min_d * min_d
	for i in _sep_pos.size():
		if i == me or _sep_ok[i] == 0:
			continue
		var d: Vector2 = position - _sep_pos[i]
		var d2 := d.length_squared()
		if d2 > 0.25 and d2 < min_d2:
			var dist := sqrt(d2)
			push += (d / dist) * (min_d - dist) * 2.8
	return push.limit_length(SPEED * 2.5)


# The whole group (terminal, carriers, tag, "!") against the viewport, with a
# margin, in screen space.
func _group_on_screen() -> bool:
	var ts: Vector2 = terminal.onscreen_size()
	if ts.x <= 0:
		return true
	var sep := ts.x * 0.5 + 24.0 + 80.0
	var top := -_carry_h() - ts.y * 0.5 - 80.0
	var local := Rect2(-sep, top, sep * 2.0, -top + 60.0)
	var r: Rect2 = get_global_transform_with_canvas() * local
	return get_viewport_rect().grow(64.0).intersects(r)


func _layout(_delta: float) -> void:
	var ts: Vector2 = terminal.onscreen_size()
	if ts.x <= 0:
		return
	var sep := ts.x * 0.5 + 24.0
	var carry_h := _carry_h()
	# (Each position write pushes a transform to the renderer even when unchanged,
	# so only write what moved.)
	_set_pos(_left, Vector2(-sep, 0))
	_set_pos(_right, Vector2(sep, 0))
	var bob := 0.0
	if _state == "wander" and _recover <= 0.0 and (_target - position).length() > 6.0 and _goal == null:
		bob = sin(_t * 9.0) * 3.0
	_set_pos(terminal, Vector2(0, -carry_h + bob))
	# tag under the terminal, bang above it
	_set_pos(_tag, Vector2(-ts.x * 0.5, 6.0))
	_set_pos(_bang, Vector2(-8, -carry_h - ts.y * 0.5 - 40.0))


static func _set_pos(n, p: Vector2) -> void:   # a Node2D or a Control (the tag)
	if n.position != p:
		n.position = p


func _update_indicators(delta: float) -> void:
	var col: Color = AGENT_COLORS.get(_agent, AGENT_COLORS["shell"])
	# label text + colour, only when the agent changes: a theme override re-sets
	# (and redraws) the label every time, even with the same colour.
	if _agent != _shown_agent:
		_shown_agent = _agent
		_tag.text = _agent if _agent != "shell" else ""
		_tag.add_theme_color_override("font_color", col.lightened(0.3))
	# aura: coloured glow behind the terminal, pulsing while busy. Only tint the
	# RGB — keep the lerped alpha so it fully fades out when the agent isn't busy
	# (otherwise it reads as a permanent grey shadow behind every terminal).
	var pulse := 0.5 + 0.35 * sin(_t * 4.0)
	var target_a := (pulse if _busy else 0.0)
	var a: float = lerp(_aura.modulate.a, target_a * 0.5, 6.0 * delta)
	if target_a == 0.0 and a < 0.002:
		a = 0.0   # settle, instead of creeping toward 0 (and redrawing) forever
	var m := Color(col.r, col.g, col.b, a)
	if _aura.modulate != m:
		_aura.modulate = m
	var ay := -_carry_h()
	if _aura.position.y != ay:
		_aura.position.y = ay
	# attention: bouncing "!" + we let Cove pulse the border via focus
	_bang.visible = _attention
	if _attention:
		_bang.position.y += -absf(sin(_t * 8.0)) * 8.0


func _restore_shadow(delta: float) -> void:
	if not _term_shadow:
		return
	var ts: Vector2 = terminal.onscreen_size()
	var base := maxf(ts.x, 40.0) * 0.95 / 128.0
	_term_shadow.scale = _term_shadow.scale.lerp(Vector2(base, base * 0.4), 8.0 * delta)
	_term_shadow.modulate.a = lerp(_term_shadow.modulate.a, 0.34, 8.0 * delta)


# --- lift / drop ------------------------------------------------------------

func lift() -> void:
	_state = "lifted"
	_left.set_airborne(true); _right.set_airborne(true)


func drop() -> void:
	if _state != "lifted":
		return
	_state = "falling"
	_fall_vel = 0.0


func set_lift_target(world_pos: Vector2) -> void:
	if _state != "lifted":
		return
	position = world_pos + Vector2(0, LIFT_H)
	_rig.position.y = _carry_h() - LIFT_H
	var ts: Vector2 = terminal.onscreen_size()
	var base := maxf(ts.x, 40.0) * 0.95 / 128.0
	_term_shadow.scale = Vector2(base * 0.5, base * 0.5 * 0.4)
	_term_shadow.modulate.a = 0.2
