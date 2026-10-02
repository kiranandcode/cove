extends SceneTree


func _init() -> void:
	var importer = ClassDB.instantiate(&"CoveIOSurface") if ClassDB.class_exists(&"CoveIOSurface") else null
	var available := importer != null
	if not available:
		printerr("CoveIOSurface is unavailable")
	else:
		print("COVE_IOSURFACE_PROBE=1")
	quit(0 if available else 1)
