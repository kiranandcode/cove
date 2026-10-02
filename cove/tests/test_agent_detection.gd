extends SceneTree

const Cove := preload("res://scripts/Cove.gd")
const CarryGroup := preload("res://scripts/CarryGroup.gd")

var _failures := 0


class ScanTestCove extends Cove:
	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func _cwds_of(_pids: Array) -> Dictionary:
		return {}


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var processes := """\
100 1 /opt/homebrew/bin/abduco -A cove-100 /bin/zsh
101 100 /bin/zsh
102 101 /opt/facebook/bin/muse exec prompt mentioning codex claude opencode
103 102 /usr/local/bin/muse_code/muse.real exec prompt mentioning codex claude opencode
104 103 /usr/local/bin/muse_code/bin/fast_mux /tmp/config.md
200 1 /opt/homebrew/bin/abduco -A cove-200 /bin/zsh
201 200 /bin/zsh
202 201 /usr/local/bin/muse_code/muse.real exec task
300 1 /opt/homebrew/bin/abduco -A cove-300 /bin/zsh
301 300 /bin/zsh
302 301 codex --model muse-spark-1.3-internal
303 302 /usr/local/bin/codex_cli/codex.real
304 303 /opt/facebook/bin/muse exec prompt mentioning codex and claude
305 304 /usr/local/bin/muse_code/muse.real exec prompt mentioning opencode
400 1 /opt/homebrew/bin/abduco -A cove-400 /bin/zsh
401 400 /bin/zsh
402 401 rg muse README.md
403 401 python /tmp/muse_helper.py
404 401 /usr/local/bin/muse_code/bin/fast_mux /tmp/config.md
500 1 /opt/homebrew/bin/abduco -A cove-500 /bin/zsh
501 500 /bin/zsh
502 501 /usr/local/bin/claude_code/claude
503 502 /opt/facebook/bin/muse exec review task
"""
	var cove := ScanTestCove.new()
	var sessions := cove._scan_sessions(processes)

	_check(sessions["cove-100"]["agent"] == "muse", "muse wrapper was not recognized")
	_check(sessions["cove-100"]["pid"] == 102, "muse wrapper was not used as the agent pid")
	_check(sessions["cove-100"]["busy"], "muse session was not marked busy")
	_check(sessions["cove-200"]["agent"] == "muse", "muse.real was not recognized")
	_check(sessions["cove-200"]["pid"] == 202, "muse.real was not used as the agent pid")
	_check(sessions["cove-300"]["agent"] == "codex", "nested Muse relabeled its Codex parent")
	_check(sessions["cove-300"]["pid"] == 302, "nested Muse replaced the Codex agent pid")
	_check(sessions["cove-400"]["agent"] == "shell", "a Muse substring was mistaken for the executable")
	_check(sessions["cove-500"]["agent"] == "claude", "nested Muse relabeled its Claude parent")
	_check(CarryGroup.AGENT_COLORS.has("muse"), "Muse has no distinct indicator color")

	cove.free()
	quit(1 if _failures else 0)
