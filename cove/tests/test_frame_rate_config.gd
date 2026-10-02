extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var config := ConfigFile.new()
	var err := config.load(ProjectSettings.globalize_path("res://project.godot"))
	if err != OK:
		push_error("could not load project.godot: %s" % error_string(err))
		quit(1)
		return
	var fps := int(config.get_value("application", "run/max_fps", 0))
	if fps != 60:
		push_error("application/run/max_fps: expected 60, got %d" % fps)
		quit(1)
		return
	var vsync := int(config.get_value("display", "window/vsync/vsync_mode", -1))
	if vsync != 3:
		push_error("display/window/vsync/vsync_mode: expected 3, got %d" % vsync)
		quit(1)
		return
	quit(0)
