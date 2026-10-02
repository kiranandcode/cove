extends SceneTree

const Cove := preload("res://scripts/Cove.gd")


func _init() -> void:
	call_deferred("_run")


func _semicolon_msdf_safe(font: Font) -> bool:
	if not font.multichannel_signed_distance_field:
		return true
	font.get_string_size(";", HORIZONTAL_ALIGNMENT_LEFT, -1, 48)
	var text_server := TextServerManager.get_primary_interface()
	for rid in font.get_rids():
		var glyph := text_server.font_get_glyph_index(rid, 48, 59, 0)
		if glyph == 0:
			continue
		var outline := text_server.font_get_glyph_contours(rid, 48, glyph)
		var points: PackedVector3Array = outline.get("points", PackedVector3Array())
		var ends: PackedInt32Array = outline.get("contours", PackedInt32Array())
		var first_winding := 0.0
		var start := 0
		for contour_end in ends:
			var twice_area := 0.0
			for i in range(start, contour_end + 1):
				var a := points[i]
				var b := points[start] if i == contour_end else points[i + 1]
				twice_area += a.x * b.y - b.x * a.y
			start = contour_end + 1
			if absf(twice_area) <= 0.001:
				continue
			var winding := signf(twice_area)
			if first_winding == 0.0:
				first_winding = winding
			elif winding != first_winding:
				return false
		return first_winding != 0.0
	return false


func _run() -> void:
	var cove := Cove.new()
	if not _semicolon_msdf_safe(cove._bd_font("draw")):
		push_error("the default draw font must render semicolons without MSDF contour artifacts")
		cove.free()
		quit(1)
		return
	cove.free()
	quit()
