extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var cove := Cove.new()
	cove._ls_mutex = Mutex.new()
	cove._ls_data = {7: {"session": "cove-123"}}
	cove._ls_gen = 3

	for invalid in ["", "  \n", "not json", "{\"windows\": []}"]:
		var parsed = cove._parse_ls(invalid, {})
		_check(parsed == null, "invalid kitty ls output must be ignored: %s" % invalid)
		_check(not cove._update_ls_data(invalid, {}), "invalid kitty ls output was accepted")
	_check(cove._ls_data.has(7), "invalid kitty ls output replaced the last good snapshot")
	_check(cove._ls_gen == 3, "invalid kitty ls output advanced the snapshot generation")

	var valid := JSON.stringify([{
		"tabs": [{
			"windows": [{
				"id": 42,
				"title": "Parser test",
				"cwd": "/tmp/fallback",
				"foreground_processes": [{
					"cmdline": ["/opt/homebrew/bin/abduco", "-a", "cove-123"],
				}],
			}],
		}],
	}])
	var sess_info := {
		"cove-123": {
			"agent": "codex",
			"busy": true,
			"idle": false,
			"pid": 1234,
			"cwd": "/tmp/current",
		},
	}
	var parsed = cove._parse_ls(valid, sess_info)
	_check(parsed is Dictionary, "valid kitty ls output must produce a snapshot")
	_check(parsed.has(42), "valid kitty ls output lost its pane")
	if parsed.has(42):
		_check(parsed[42]["session"] == "cove-123", "session was not recovered")
		_check(parsed[42]["agent"] == "codex", "session metadata was not merged")
		_check(parsed[42]["cwd"] == "/tmp/current", "live session cwd was not preferred")
	_check(cove._update_ls_data(valid, sess_info), "valid kitty ls output was ignored")
	_check(cove._ls_data.has(42), "valid kitty ls output was not published")
	_check(cove._ls_gen == 4, "valid kitty ls output did not advance the snapshot generation")

	cove.free()
	quit(1 if _failures else 0)
