extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


class DummyTerminal extends RefCounted:
	var pane_id := 42
	var emacs := false
	var page := false


class DummyGroup extends Node2D:
	var terminal := DummyTerminal.new()


class RoutingTestCove extends Cove:
	var writes: Array[Dictionary] = []

	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func _pty(pane: int, data: PackedByteArray) -> void:
		writes.append({"pane": pane, "data": data})


func _check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failures += 1


func _escape(shift := false, meta := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.physical_keycode = KEY_ESCAPE
	event.shift_pressed = shift
	event.meta_pressed = meta
	event.pressed = true
	return event


func _dispatch(event: InputEventKey) -> void:
	root.push_input(event)
	await process_frame


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := RoutingTestCove.new()
	var group := DummyGroup.new()
	cove._groups[42] = group
	cove._focused_id = 42
	cove._present_id = 42
	root.add_child(cove)

	await _dispatch(_escape())
	_check(cove._present_id == 42, "plain Escape must keep the focused termling presented")
	_check(cove.writes.size() == 1, "plain Escape must reach the focused terminal exactly once")
	if cove.writes.size() == 1:
		_check(cove.writes[0]["pane"] == 42, "plain Escape was sent to the wrong pane")
		_check(cove.writes[0]["data"] == PackedByteArray([27]), "plain Escape must send byte 0x1b")

	cove.writes.clear()
	cove._present_id = 42
	await _dispatch(_escape(true))
	_check(cove._present_id == -1, "Shift+Escape must leave presentation mode")
	_check(cove.writes.is_empty(), "Shift+Escape must not reach the focused terminal")

	cove._present_id = 42
	await _dispatch(_escape(true, true))
	_check(cove._present_id == 42, "only exact Shift+Escape may leave presentation mode")
	_check(cove.writes.size() == 1, "modified Escape must otherwise reach the focused terminal")

	root.remove_child(cove)
	cove.free()
	group.free()
	quit(1 if _failures else 0)
