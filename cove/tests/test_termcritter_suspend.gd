extends SceneTree

const TermCritterScript := preload("res://scripts/TermCritter.gd")
const CoveScript := preload("res://scripts/Cove.gd")

var _failures := 0


class TestTermCritter extends TermCritterScript:
	var near_screen := false

	func _near_screen() -> bool:
		return near_screen


class RecordingSink extends RefCounted:
	var calls: Array[bool] = []
	var succeeds := true

	func send(on: bool) -> bool:
		calls.append(on)
		return succeeds


class FakeSocket extends RefCounted:
	var connected := true
	var send_result := true
	var messages: Array[PackedByteArray] = []

	@warning_ignore("native_method_override")
	func is_connected(_signal: StringName = &"", _callable: Callable = Callable()) -> bool:
		return connected

	func send_raw(message: PackedByteArray) -> bool:
		messages.append(message.duplicate())
		return send_result


func _check(condition: bool, label: String) -> void:
	if not condition:
		push_error(label)
		_failures += 1


func _new_term(sink: RecordingSink) -> TestTermCritter:
	var term := TestTermCritter.new()
	term.iosurface_id = 0
	term.page = false
	term.frame_path = "/path/that/does/not/exist"
	term.suspend_sink = sink.send
	return term


func _age_far_timer(term: TestTermCritter) -> void:
	term._far_since = Time.get_ticks_msec() - TermCritterScript.SUSPEND_AFTER_MS - 1


func _test_fallback_suspend_resume_and_dedup() -> void:
	var sink := RecordingSink.new()
	var term := _new_term(sink)

	term.poll()
	_check(sink.calls == [false], "fallback termling did not synchronize its initial active state")
	_check(term._suspend_synced, "successful initial sync was not recorded")

	_age_far_timer(term)
	term.poll()
	_check(sink.calls == [false, true], "fallback termling did not suspend when far off screen")
	_check(term._suspended, "successful suspend was not recorded")

	term.poll()
	_check(sink.calls == [false, true], "suspended termling sent a duplicate suspend")

	term.near_screen = true
	term.poll()
	_check(sink.calls == [false, true, false], "near-screen termling did not resume")
	_check(not term._suspended, "successful resume did not clear suspended state")

	term.poll()
	_check(sink.calls == [false, true, false], "active termling sent a duplicate resume")
	term.free()


func _test_failed_initial_sync_retries() -> void:
	var sink := RecordingSink.new()
	sink.succeeds = false
	var term := _new_term(sink)

	term.poll()
	term.poll()
	_check(sink.calls == [false, false], "failed initial sync was not retried")
	_check(not term._suspend_synced, "failed initial sync was recorded as successful")

	sink.succeeds = true
	term.poll()
	_check(sink.calls == [false, false, false], "successful initial sync was not retried")
	_check(term._suspend_synced, "successful retry did not record initial sync")
	term.free()


func _test_failed_suspend_and_resume_retry() -> void:
	var sink := RecordingSink.new()
	var term := _new_term(sink)
	term.poll()
	_age_far_timer(term)

	sink.succeeds = false
	term.poll()
	term.poll()
	_check(sink.calls == [false, true, true], "failed suspend was not retried")
	_check(not term._suspended, "failed suspend was recorded as successful")

	sink.succeeds = true
	term.poll()
	_check(term._suspended, "successful suspend retry was not recorded")
	term.poll()
	_check(sink.calls == [false, true, true, true], "successful suspend was sent more than once")

	term.near_screen = true
	sink.succeeds = false
	term.poll()
	term.poll()
	_check(sink.calls == [false, true, true, true, false, false], "failed resume was not retried")
	_check(term._suspended, "failed resume cleared suspended state")

	sink.succeeds = true
	term.poll()
	_check(not term._suspended, "successful resume retry did not clear suspended state")
	term.poll()
	_check(sink.calls == [false, true, true, true, false, false, false], "successful resume was sent more than once")
	term.free()


func _test_page_does_not_suspend() -> void:
	var sink := RecordingSink.new()
	var term := _new_term(sink)
	term.page = true
	term.poll()
	_check(sink.calls.is_empty(), "page critter sent a kitty suspend message")
	term.free()


func _test_cove_propagates_send_result() -> void:
	var cove := CoveScript.new()
	var socket := FakeSocket.new()
	cove._sock = socket

	socket.connected = false
	_check(cove.call("_send_suspend", false, 42) == false, "disconnected suspend send did not fail")
	_check(socket.messages.is_empty(), "disconnected suspend send wrote a message")

	socket.connected = true
	socket.send_result = false
	_check(cove.call("_send_suspend", true, 42) == false, "native send failure was not propagated")

	socket.send_result = true
	_check(cove.call("_send_suspend", true, 42) == true, "native send success was not propagated")
	_check(socket.messages.size() == 2, "connected suspend sends did not reach the socket")
	cove.free()


func _init() -> void:
	_test_fallback_suspend_resume_and_dedup()
	_test_failed_initial_sync_retries()
	_test_failed_suspend_and_resume_retry()
	_test_page_does_not_suspend()
	_test_cove_propagates_send_result()
	quit(1 if _failures else 0)
