extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


func _check(ok: bool, label: String) -> void:
	if not ok:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := Cove.new()
	var todo := {
		"id": "shared", "type": "todo", "owner": "owner", "text": "Shared",
		"items": [], "x": 0.0, "y": 0.0, "w": 300.0, "h": 100.0,
		"color": "blue", "fill": "none", "dash": "draw", "size": "m",
		"font": "draw",
	}
	cove._bd_add(todo)
	cove._bd_exec_update({
		"id": "shared", "session": "owner",
		"editors": ["editor-a", "", "editor-a", "editor-b"],
	})
	_check(todo.get("editors", []) == ["editor-a", "editor-b"],
		"todo editor sessions should be normalized and deduplicated")
	var clone_ids: Array = cove._bd_insert([todo.duplicate(true)], Vector2(20, 20))
	var clone: Dictionary = cove._bd_by_id[str(clone_ids[0])]
	_check(not clone.has("editors"), "duplicating a todo should not copy its editor ACL")

	_check(cove._bd_command({
		"op": "update", "id": "shared", "session": "editor-a",
		"add_items": ["Review", "Build"],
	}) == "", "shared editor should add checklist items")
	_check(cove._bd_command({
		"op": "update", "id": "shared", "session": "editor-b", "check": "Review",
	}) == "", "shared editor should check a checklist item")
	_check(todo["items"].size() == 2 and bool(todo["items"][0]["done"]),
		"incremental updates from different editors should compose")

	cove._bd_restore(cove._bd_snapshot())
	todo = cove._bd_by_id["shared"]
	_check(todo.get("editors", []) == ["editor-a", "editor-b"],
		"todo editor sessions should survive board persistence")
	_check(cove._bd_command({
		"op": "update", "id": "shared", "session": "editor-a",
		"add_items": ["allowed"], "color": "red",
	}) != "", "mixed content and layout edits should be rejected atomically")
	_check(cove._bd_command({
		"op": "update", "id": "shared", "session": "editor-a", "items": [],
	}) != "", "shared editors should not replace the full item list")
	_check(cove._bd_command({
		"op": "delete", "ids": ["shared"], "session": "editor-a",
	}) != "", "shared editors should not delete their todo")
	var before_outsider: int = todo["items"].size()
	_check(cove._bd_command({
		"op": "update", "id": "shared", "session": "outsider",
		"add_items": ["forged"],
	}) != "", "outsiders should be rejected by the authoritative board model")
	_check(todo["items"].size() == before_outsider,
		"rejected outsider update should not mutate the todo")

	# A pending ACL change must reject later editor work synchronously; reporting
	# success and silently dropping it at execution would lose work.
	cove._bd_g = "move"
	_check(cove._bd_command({
		"op": "update", "id": "shared", "session": "owner", "editors": [],
	}) == "", "owner revoke should queue during a gesture")
	_check(cove._bd_command({
		"op": "update", "id": "shared", "session": "editor-a", "add_items": ["late"],
	}) != "", "editor update after a queued revoke should ask the caller to retry")
	cove._bd_cmd_queue.append({
		"op": "update", "id": "shared", "session": "editor-a",
		"add_items": ["forged-after-revoke"],
	})
	cove._bd_g = ""
	var queued: Array = cove._bd_cmd_queue
	cove._bd_cmd_queue = []
	for command in queued:
		cove._bd_exec(command)
	_check(todo.get("editors", []) == [], "owner revoke should remove shared editors")
	_check(cove._bd_todo_find(todo["items"], "late") == -1,
		"queued editor update should be rechecked after revocation")
	_check(cove._bd_todo_find(todo["items"], "forged-after-revoke") == -1,
		"execution-time ACL should reject forged queued editor work")
	cove._bd_exec_update({"id": "shared", "session": "owner", "editors": "editor-a"})
	_check(todo.get("editors", []) == [], "malformed editor metadata should grant nobody")

	var note := todo.duplicate(true)
	note["id"] = "note"
	note["type"] = "note"
	note.erase("editors")
	cove._bd_add(note)
	cove._bd_exec_update({"id": "note", "session": "owner", "editors": ["editor-a"]})
	_check(not note.has("editors"), "non-todo shapes must ignore shared editor updates")
	var disposable := todo.duplicate(true)
	disposable["id"] = "owned-delete"
	cove._bd_add(disposable)
	_check(cove._bd_command({
		"op": "delete", "ids": ["owned-delete"], "session": "owner",
	}) == "", "todo owner should retain delete permission")
	_check(not cove._bd_by_id.has("owned-delete"), "owner delete should remove the todo")
	cove.free()
	quit(1 if _failures else 0)
