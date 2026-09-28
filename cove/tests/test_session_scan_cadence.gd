extends SceneTree

const Cove := preload("res://scripts/Cove.gd")

var _failures := 0


func _expect(value: bool, label: String) -> void:
	if not value:
		push_error(label)
		_failures += 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(Cove._cwd_scan_due(0, -1), "the first cwd lookup must run")
	_expect(not Cove._cwd_scan_due(4999, 0), "a cwd lookup before five seconds is too early")
	_expect(Cove._cwd_scan_due(5000, 0), "five elapsed seconds must refresh cwd data")
	_expect(not Cove._cwd_scan_due(10_000, 5001), "cadence is measured from the last lookup")

	var cove := Cove.new()
	var idle_ps := "100 1 /usr/local/bin/abduco -A cove-123 zsh\n101 100 zsh\n"
	var idle := cove._scan_sessions(idle_ps, {"cove-123": "/old"})
	_expect(bool(idle["cove-123"]["idle"]), "a bare shell must remain freshly idle")
	_expect(idle["cove-123"]["cwd"] == "/old", "cached cwd was not applied by session")

	var busy_ps := idle_ps + "102 101 codex\n"
	var busy := cove._scan_sessions(busy_ps, {"cove-123": "/old"})
	_expect(not bool(busy["cove-123"]["idle"]), "cached cwd must not cache idle state")
	_expect(busy["cove-123"]["agent"] == "codex", "agent state was not refreshed")
	_expect(busy["cove-123"]["cwd"] == "/old", "cwd was lost when the source pid changed")
	cove.free()
	quit(1 if _failures else 0)
