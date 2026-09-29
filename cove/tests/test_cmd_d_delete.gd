extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


class DummyTerminal extends RefCounted:
	var pane_id := 42
	var page := false
	var emacs := false
	var remote := false

	func set_focused(_focused: bool) -> void:
		pass


class DummyGroup extends Node2D:
	var terminal := DummyTerminal.new()


class ShortcutTestCove extends Cove:
	var deleted: Array[int] = []
	var duplicated := 0

	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func _delete_focused_term() -> void:
		deleted.append(_focused_id)

	func _bd_duplicate() -> void:
		duplicated += 1

	func _bd_ui_refresh() -> void:
		pass


class DeleteTestCove extends Cove:
	var terminated: Array[String] = []
	var helpers_running := {}

	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func _terminate_session(sess: String) -> int:
		terminated.append(sess)
		return 999999999

	func _child_process_running(pid: int) -> bool:
		return bool(helpers_running.get(pid, false))


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _key(meta := false, ctrl := false, alt := false, shift := false, echo := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_D
	ev.physical_keycode = KEY_D
	ev.unicode = 100
	ev.meta_pressed = meta
	ev.ctrl_pressed = ctrl
	ev.alt_pressed = alt
	ev.shift_pressed = shift
	ev.echo = echo
	ev.pressed = true
	return ev


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := ShortcutTestCove.new()
	cove.set_process(false)
	root.add_child(cove)
	var group := DummyGroup.new()
	cove.add_child(group)
	cove._groups[42] = group
	cove._focused_id = 42

	cove._input(_key(true))
	_check(cove.deleted == [42], "Cmd+D did not delete the focused terminal")

	for ev in [_key(), _key(true, true), _key(true, false, true),
			_key(true, false, false, true), _key(true, false, false, false, true)]:
		cove._input(ev)
	_check(cove.deleted == [42], "a non-exact or repeated Cmd+D deleted the terminal")

	group.terminal.page = true
	cove._input(_key(true))
	group.terminal.emacs = true
	cove._input(_key(true))
	group.terminal.emacs = false
	group.terminal.page = false
	group.terminal.remote = true
	cove._input(_key(true))
	_check(cove.deleted == [42], "Cmd+D deleted a page, Emacs critter, or remote shadow")

	group.terminal.remote = false
	cove._focused_id = -1
	cove._input(_key(true))
	_check(cove.duplicated == 1 and cove.deleted == [42], "board Cmd+D no longer duplicates")

	root.remove_child(cove)
	cove.free()

	var deletion := DeleteTestCove.new()
	deletion.set_process(false)
	root.add_child(deletion)
	var first := DummyGroup.new()
	var second := DummyGroup.new()
	deletion.add_child(first)
	deletion.add_child(second)
	deletion._groups[42] = first
	deletion._focused_id = 42
	deletion._sessions[42] = "cove-123"
	deletion._delete_focused_term()
	_check(deletion.terminated.is_empty(), "deleting the last local terminal was allowed")

	deletion._groups[43] = second
	deletion._sessions.erase(42)
	deletion._delete_focused_term()
	_check(deletion.terminated.is_empty(), "a terminal with an unknown session was deleted")

	deletion._sessions[42] = "cove-123"
	deletion._name_by_session["cove-123"] = "old"
	deletion._pos_by_session["cove-123"] = [1, 2]
	deletion._zone_by_session["cove-123"] = "frame"
	deletion._names[42] = "old"
	deletion._pos_restored[42] = true
	deletion._zone_saved[42] = "frame"
	deletion._delete_focused_term()
	_check(deletion.terminated == ["cove-123"], "the exact session was not terminated")
	_check(str(deletion._deleting_sessions.get(42, {}).get("session", "")) == "cove-123",
		"deletion was not tracked")
	deletion._delete_focused_term()
	deletion._focused_id = 43
	deletion._sessions[43] = "cove-456"
	deletion._delete_focused_term()
	_check(deletion.terminated == ["cove-123"],
		"rapid deletion launched twice or deleted the last remaining terminal")
	deletion._deleting_sessions[42]["until"] = 0
	deletion.helpers_running[999999999] = true
	deletion._expire_failed_deletions()
	_check(deletion._delete_pending(42), "a running cleanup helper lost its last-terminal reservation")
	deletion.helpers_running.erase(999999999)
	deletion._expire_failed_deletions()
	_check(not deletion._delete_pending(42), "a failed deletion could never be retried")
	deletion._remove_group(42)
	_check(not deletion._sessions.has(42), "a removed kitty id retained its stale session")
	_check(not deletion._name_by_session.has("cove-123") \
			and not deletion._pos_by_session.has("cove-123") \
			and not deletion._zone_by_session.has("cove-123"),
		"deleted session metadata survived reconciliation")
	_check(not deletion._names.has(42) and not deletion._pos_restored.has(42) \
			and not deletion._zone_saved.has(42), "deleted kitty id metadata survived reconciliation")

	root.remove_child(deletion)
	deletion.free()
	quit(1 if _failures else 0)
