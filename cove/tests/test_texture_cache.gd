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
	_test_board_texture_pruning()
	_test_board_texture_draw_generation()
	_test_thumbnail_bound_and_active_set()
	quit(1 if _failures else 0)


func _test_board_texture_pruning() -> void:
	var cove := Cove.new()
	var marker := ImageTexture.new()
	cove._bd_tex = {
		"board.png": marker,
		"preview.png": marker,
		"favicon.png": marker,
		"deleted.png": marker,
		"failed.png": null,
	}
	cove._bd_shapes = [
		{"id": "image", "type": "image", "src": "board.png"},
		{"id": "bookmark", "type": "bookmark", "url": "", "image": "preview.png", "favicon": "favicon.png"},
	]

	cove._bd_reindex()

	_check(cove._bd_tex.size() == 3, "board cache did not discard unreferenced entries")
	for path in ["board.png", "preview.png", "favicon.png"]:
		_check(cove._bd_tex.get(path) == marker, "board cache discarded active texture %s" % path)
	_check(not cove._bd_tex.has("deleted.png"), "deleted board image stayed cached")
	_check(not cove._bd_tex.has("failed.png"), "unreferenced failed board image stayed cached")

	cove._bd_shapes = [{"id": "image", "type": "image", "src": "replacement.png"}]
	cove._bd_tex["replacement.png"] = marker
	cove._bd_reindex()
	_check(cove._bd_tex.keys() == ["replacement.png"], "reindex did not prune replaced board image sources")
	cove.free()


func _test_board_texture_draw_generation() -> void:
	var cove := Cove.new()
	var marker := ImageTexture.new()
	cove._bd_shapes = [
		{"id": "near", "type": "image", "src": "near.png"},
		{"id": "far", "type": "image", "src": "far.png"},
	]
	cove._bd_tex = {"near.png": marker, "far.png": marker}
	cove._bd_reindex()
	if not cove.has_method("_bd_texture_draw_begin") or not cove.has_method("_bd_texture_draw_end"):
		_check(false, "board texture draw-generation hooks are missing")
		cove.free()
		return

	# The first camera position draws only the near shape. The far shape remains
	# on the board, but its decoded texture should not remain resident.
	cove.call("_bd_texture_draw_begin")
	_check(cove._bd_texture("near.png") == marker, "visible board texture was not available")
	cove.call("_bd_texture_draw_end")
	_check(cove._bd_by_id.has("far"), "offscreen image shape was removed with its texture")
	_check(cove._bd_tex.has("near.png"), "visible board texture was evicted")
	_check(not cove._bd_tex.has("far.png"), "offscreen board texture stayed cached")

	# Simulate panning to the far shape. Its texture is loaded once for this draw;
	# the formerly visible texture is now the eviction candidate.
	cove._bd_tex["far.png"] = marker
	cove.call("_bd_texture_draw_begin")
	_check(cove._bd_texture("far.png") == marker, "newly visible board texture was not available")
	cove.call("_bd_texture_draw_end")
	_check(cove._bd_tex.has("far.png"), "newly visible board texture was evicted")
	_check(not cove._bd_tex.has("near.png"), "old camera region's texture stayed cached")
	cove.free()


func _test_thumbnail_bound_and_active_set() -> void:
	var cove := Cove.new()
	var marker := ImageTexture.new()
	var paths := []
	for i in 140:
		var path := "thumb-%03d.png" % i
		paths.append(path)
		cove._fs_thumbs[path] = marker

	# One unusually large visible folder may exceed the normal bound. Protect
	# everything it used so the next redraw does not reload the same thumbnails.
	cove.call("_fs_thumb_draw_begin")
	for path in paths:
		cove._fs_thumb(path)
	cove.call("_fs_thumb_draw_end")
	_check(cove._fs_thumbs.size() == 140, "visible thumbnails were evicted during their own draw")

	# Once most of that folder is no longer visible, old thumbnails become LRU
	# candidates and the cache returns to its fixed bound.
	cove.call("_fs_thumb_draw_begin")
	for i in 8:
		cove._fs_thumb(paths[i])
	cove.call("_fs_thumb_draw_end")
	_check(cove._fs_thumbs.size() == 128, "thumbnail cache did not return to its 128-entry bound")
	for i in 8:
		_check(cove._fs_thumbs.has(paths[i]), "active thumbnail %s was evicted" % paths[i])
	_check(not cove._fs_thumbs.has(paths[8]), "least-recently-used thumbnail was retained")
	_check(cove._fs_thumbs.has(paths[-1]), "recent thumbnail was evicted before an older one")
	cove.free()
