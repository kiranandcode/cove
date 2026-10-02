# One live terminal as a scene you can decorate in the editor. The terminal
# pixels land on the $Screen sprite; add sibling nodes (glow, border, particles,
# an AnimationPlayer) in scenes/TermCritter.tscn and they ride along with every
# terminal. See godot/DESIGN.md.
extends Node2D
class_name TermCritter

# Shared-file header layout (see kitty/cove.c).
const MAGIC := 0x4B4D454E
const HEADER := 64
const FLAG_BOTTOM_UP := 0x1
const FLAG_PAGE := 0x10000  # a Vibefox page critter (a browser tab), not a kitty pane
const FLAG_EMACS := 0x20000  # a Vibemacs frame; header [60] = backing scale * 100
const FLAG_GODOT := 0x80000  # a Godot editor panel (godot-cove, with FLAG_PAGE); header [60] = editor scale * 100
# World units per editor pixel at editor scale 1: editor text reads about as big as a termling's.
const GODOT_ZOOM := 0.32

# On-screen pixels per native terminal pixel. Resizing (changing cols/rows)
# grows/shrinks the whole window rather than rescaling the text. kitty renders at
# its window's backing scale (1x or 2x Retina, depending on which screen its
# hidden window lands on), so poll() divides BASE_ZOOM by the detected render
# scale: world size stays put, and a 2x render gives Retina-sharp glyphs.
const BASE_ZOOM := 0.30
# Page critters arrive at half the tab's viewport (Vibefox scale 0.5); this puts
# them on the board at about a termling's size.
const PAGE_ZOOM := 0.45
const BASE_CELL_H := 19.0   # cell height in px at font_size=16 rendered at 1x
var zoom := BASE_ZOOM

@onready var screen: Sprite2D = $Screen
@onready var _nameplate: Label = get_node_or_null("Nameplate")
@onready var _border: Panel = get_node_or_null("Border")

var term_id := -1        # kitty OS-window id (from the file name)
var pane_id := 0         # kitty window/pane id (for `@ --match id:`)
var force_read := false  # read frames even off-screen (a board screenshot is looking)
var frame_path := ""
var custom_name := ""    # user/agent-assigned name shown on the nameplate
var remote := false      # a read-only shadow of a termling on another device
var remote_peer := ""    # which device it lives on (shown on the nameplate)
var link_host := ""      # a live cove-remote session: the Mac it runs on
var link_up := true      # whether that link is connected right now
var link_state := ""     # why it's down, when it's not just reconnecting ("asleep, type to wake")
var page := false        # a Vibefox page critter: input goes to the browser, not kitty
var emacs := false       # a Vibemacs frame (also page: input goes to Vibemacs, not kitty)
var emacs_scale := 1.0   # its backing scale (2.0 on Retina)
var godot := false       # a Godot editor panel (also page: input goes to the godot_cove plugin)
var godot_scale := 1.0   # the editor's display scale (pixels per editor unit)
var page_title := ""     # the tab's title (from the term-<N>.json sidecar), nameplate fallback
var _srgb_mat: ShaderMaterial = null  # linear->sRGB encode for kitty frames (not pages)
var _emacs_mat: ShaderMaterial = null  # opaque, for Vibemacs frames
var _focused := false     # last focus state, so set_remote can re-tint
var _default_border_sb: StyleBox = null  # the local (blue) border style
var _remote_border_sb: StyleBox = null   # a red variant for remote shadows
var _backdrop: ColorRect = null          # red background mat, remote only
var _link_border_sb: StyleBox = null     # violet: a live cove-remote termling
const LINK_COLOR := Color(0.56, 0.38, 0.96)       # link up
const LINK_DOWN_COLOR := Color(0.95, 0.62, 0.22)  # reconnecting
var cols := 0
var rows := 0
var mouse_mode := 0      # 0 none, 1 button, 2 motion, 3 any
var mouse_proto := 0     # 2 = SGR, 4 = SGR-pixel
var iosurface_id := 0

var _tex: ImageTexture
var _size := Vector2i.ZERO
var _last_seq := -1
var _last_read_ms := 0   # when the rgba path last read a frame (see UNFOCUSED_READ_MS)
var _last_head_ms := 0   # when poll() last read the header (see OFFSCREEN_HEAD_MS)
const OFFSCREEN_HEAD_MS := 250
# Suspension (kitty MSG_SUSPEND): a termling well off screen for SUSPEND_AFTER_MS
# asks kitty to stop rendering it and, with IOSurface, free its spare frame
# buffer; it resumes the moment it's within half a view of the screen, focused,
# or screenshotted, so a fresh frame is there before it's visible.
# suspend_sink(on) sends the message and reports whether kitty received it.
const SUSPEND_AFTER_MS := 10000
var suspend_sink: Callable
var _suspended := false
var _suspend_synced := false   # told kitty "not suspended" once (a new Cove can't know)
var _far_since := 0
# An unfocused termling's rgba frames are read at most this often. Each 2x frame
# is ~10 MB read + copied + uploaded on the main thread, so a handful of busy
# agents at full rate starved the focused termling and made typing lag.
const UNFOCUSED_READ_MS := 160
var _file: FileAccess      # kept open: kitty rewrites the frame in place (mmap)
var _renamed_frames := false  # ...but a page critter's are published by rename (see poll)
# Zero-copy path: two importers/textures (double-buffered), swapped per frame.
var _importers: Array = []          # [CoveIOSurface, CoveIOSurface]
var _rd_tex: Array = [null, null]   # [Texture2DRD, Texture2DRD]
var _io_ids := Vector2i.ZERO        # (id_a, id_b) currently imported


func setup(id: int, path: String) -> void:
	term_id = id
	frame_path = path
	# kitty's frames are linear light; encode to sRGB so colours match the desktop.
	# ($Screen, not `screen`: setup() runs before add_child, so @onready is unset.)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/term_srgb.gdshader")
	_srgb_mat = mat
	$Screen.material = mat
	if ClassDB.class_exists("CoveIOSurface"):
		_importers = [ClassDB.instantiate("CoveIOSurface"), ClassDB.instantiate("CoveIOSurface")]


func poll() -> void:
	# Opening the file every frame for every termling was ~0.1 ms each, the
	# Cove's biggest main-thread cost at idle. One handle stays open instead.
	# Seeking far away first drops stdio's read buffer; a seek straight back to 0
	# would reuse it and read a stale header.
	#
	# Page critters are the exception: Vibefox publishes each frame by rename
	# (write .tmp, move it into place), so every frame is a NEW inode and a handle
	# we hold stays bound to the old, unlinked one -- the sprite freezes on the
	# frame that was current when we opened it, while its input goes on working.
	# There are only ever a handful of them, so they pay the reopen.
	# Well off screen (not even within half a view of it), re-read the header only
	# every OFFSCREEN_HEAD_MS: each read is two seeks and a read syscall, ~70
	# termlings x 60 fps, and nothing it carries is visible out there. Near or on
	# screen (and when focused) it's still read every frame.
	if not page and suspend_sink.is_valid():
		_update_suspend()
	if _last_seq != -1 and not force_read and not _focused:   # (IOSurface termlings never set _tex)
		var now_ms := Time.get_ticks_msec()
		if now_ms - _last_head_ms < OFFSCREEN_HEAD_MS and not _near_screen():
			return
		_last_head_ms = now_ms
	if _renamed_frames:
		_file = null
	if _file == null:
		if not FileAccess.file_exists(frame_path):
			return
		_file = FileAccess.open(frame_path, FileAccess.READ)
		if _file == null:
			return
	var f := _file
	f.seek(1 << 40)
	f.seek(0)
	var head := f.get_buffer(HEADER)
	if head.size() < HEADER or head.decode_u32(0) != MAGIC:
		return
	var w := int(head.decode_u32(4))
	var h := int(head.decode_u32(8))
	var seq := int(head.decode_u32(12))
	var flags := int(head.decode_u32(20))
	var was_page := page
	page = (flags & (FLAG_PAGE | FLAG_EMACS)) != 0
	_renamed_frames = (flags & FLAG_PAGE) != 0
	emacs = (flags & FLAG_EMACS) != 0
	if emacs:
		emacs_scale = maxf(1.0, float(head.decode_u32(60)) / 100.0)
	godot = (flags & FLAG_GODOT) != 0 and not emacs
	if godot:
		page = true   # a page in every way but where its input goes
		var gs := float(head.decode_u32(60)) / 100.0
		godot_scale = clampf(gs, 0.5, 4.0) if gs > 0.0 else 1.0
	if page != was_page:
		# Vibefox snapshots are already sRGB; kitty's frames are linear light. Only
		# the latter want the encode shader, or a page comes out washed-out white.
		screen.material = _emacs_opaque() if emacs else (null if page else _srgb_mat)
		_update_nameplate()
	pane_id = int(head.decode_u32(24)) | (int(head.decode_u32(28)) << 32)
	cols = int(head.decode_u32(32))
	rows = int(head.decode_u32(36))
	mouse_mode = int(head.decode_u32(40))
	mouse_proto = int(head.decode_u32(44))
	var iosurface_id_a := int(head.decode_u32(48))
	var iosurface_id_b := int(head.decode_u32(52))
	# Non-zero = zero-copy. Either buffer's id can be 0: a suspended termling keeps
	# only the buffer holding its last frame (kitty frees the other).
	iosurface_id = iosurface_id_a if iosurface_id_a != 0 else iosurface_id_b
	var ready_index := int(head.decode_u32(56))
	if w <= 0 or h <= 0 or seq == _last_seq:
		return
	# An off-screen termling's frames aren't worth reading (at 2x each is 10-27 MB
	# through the rgba file). Leaving _last_seq alone means it catches up the
	# moment it's back in view.
	if iosurface_id == 0 and _tex != null and _size == Vector2i(w, h) and not force_read and not _on_screen():
		return
	var now := Time.get_ticks_msec()
	if iosurface_id == 0 and _tex != null and _size == Vector2i(w, h) and not _focused and not force_read \
			and now - _last_read_ms < UNFOCUSED_READ_MS:
		return
	_last_read_ms = now
	_last_seq = seq
	# Normalise for kitty's render scale (1x vs 2x Retina) so world size is
	# stable and a 2x render shows as sharper glyphs, not a bigger window.
	var render_scale := maxf(1.0, roundf(float(h) / float(maxi(rows, 1)) / BASE_CELL_H))
	var z := BASE_ZOOM / emacs_scale if emacs else (PAGE_ZOOM if page else BASE_ZOOM / render_scale)
	if godot:
		z = GODOT_ZOOM / godot_scale
	if not is_equal_approx(z, zoom):
		zoom = z
		screen.scale = Vector2.ONE * zoom
		_layout_decorations()

	if iosurface_id != 0 and not _importers.is_empty():
		_apply_iosurface(w, h, iosurface_id_a, iosurface_id_b, ready_index)
	else:
		f.seek(HEADER)
		var px := f.get_buffer(w * h * 4)
		if px.size() < w * h * 4:
			return
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, px)
		# Bottom-up frames are flipped by the sprite on the GPU: a CPU flip_y of a
		# 2x frame was the single biggest cost on the main thread.
		screen.flip_v = (flags & FLAG_BOTTOM_UP) != 0
		if _tex == null or _size != Vector2i(w, h):
			_tex = ImageTexture.create_from_image(img)
			_size = Vector2i(w, h)
			screen.texture = _tex
			screen.scale = Vector2.ONE * zoom
			_layout_decorations()
		else:
			_tex.update(img)


# Is any of the terminal inside the window (with a margin)?
# How long this termling has been well off screen (0 = it's near or on screen).
func far_for_ms() -> int:
	return 0 if _far_since == 0 else Time.get_ticks_msec() - _far_since


func _update_suspend() -> void:
	if not _suspend_synced:
		if not _request_suspend(false):
			return
		_suspend_synced = true
	var far := not _focused and not force_read and not _near_screen()
	if not far:
		_far_since = 0
		if _suspended and _request_suspend(false):
			_suspended = false
		return
	var now_ms := Time.get_ticks_msec()
	if _far_since == 0:
		_far_since = now_ms
	elif not _suspended and now_ms - _far_since > SUSPEND_AFTER_MS and _request_suspend(true):
		_suspended = true


func _request_suspend(on: bool) -> bool:
	return suspend_sink.call(on) == true


# The viewport grown by half its size each way: termlings about to scroll into
# view keep full-rate header reads, so they never show up stale.
func _near_screen() -> bool:
	if screen == null or screen.texture == null:
		return true
	var r: Rect2 = screen.get_global_transform_with_canvas() * screen.get_rect()
	var vr := get_viewport_rect()
	return vr.grow_individual(vr.size.x * 0.5, vr.size.y * 0.5, vr.size.x * 0.5, vr.size.y * 0.5).intersects(r)


func _on_screen() -> bool:
	if screen == null or screen.texture == null:
		return true
	var r: Rect2 = screen.get_global_transform_with_canvas() * screen.get_rect()
	return get_viewport_rect().grow(64.0).intersects(r)


func _emacs_opaque() -> ShaderMaterial:
	if _emacs_mat == null:
		_emacs_mat = ShaderMaterial.new()
		_emacs_mat.shader = preload("res://shaders/emacs_opaque.gdshader")
	return _emacs_mat


func _apply_iosurface(w: int, h: int, id_a: int, id_b: int, ready: int) -> void:
	# Import both buffers once (ids are stable); then each frame just point the
	# sprite at whichever buffer kitty says holds the latest complete frame.
	if _io_ids != Vector2i(id_a, id_b) or _size != Vector2i(w, h):
		_rd_tex[0] = _importers[0].call("import_surface", id_a, w, h)
		_rd_tex[1] = _importers[1].call("import_surface", id_b, w, h)
		_io_ids = Vector2i(id_a, id_b)
		_size = Vector2i(w, h)
		screen.flip_v = not emacs  # kitty's IOSurface holds GL bottom-up pixels; Emacs's is top-down
		screen.scale = Vector2.ONE * zoom
		_layout_decorations()
	var t = _rd_tex[ready] if ready >= 0 and ready < 2 else null
	if t != null:
		screen.texture = t


# Padding of the red backdrop mat beyond the terminal edge, on-screen px. Kept
# to ~the blue focus border's width so the red frame reads at the same weight.
const REMOTE_PAD := 4.0

func _layout_decorations() -> void:
	var half := onscreen_size() * 0.5
	if _border:
		# A StyleBox draws its border *inside* its rect, so grow the panel by
		# the border width: the frame sits just outside the terminal and never
		# covers the edge cells.
		var bw := _border_width()
		_border.position = -half - bw
		_border.size = onscreen_size() + bw * 2.0
	if _backdrop:
		# A red mat that extends past the terminal so the red reads as the
		# termling's background, framing the (opaque) terminal content.
		var pad := Vector2(REMOTE_PAD, REMOTE_PAD)
		_backdrop.position = -half - pad
		_backdrop.size = onscreen_size() + pad * 2.0
	if _nameplate:
		_nameplate.position = Vector2(-half.x, -half.y - 22.0)
		_update_nameplate()


func _border_width() -> Vector2:
	var sb = _border.get_theme_stylebox("panel") if _border else null
	if sb is StyleBoxFlat:
		var f := sb as StyleBoxFlat
		return Vector2(f.border_width_left, f.border_width_top)
	return Vector2.ZERO


func _update_nameplate() -> void:
	if _nameplate == null:
		return
	var base := custom_name if custom_name != "" else "termling %d" % term_id
	if godot:
		# A Godot editor panel: "◆", named after its scene/panel unless renamed.
		if custom_name == "":
			base = page_title if page_title != "" else "godot"
		_nameplate.text = "◆ %s  (godot)" % base
		_nameplate.add_theme_color_override("font_color", Color(0.55, 0.75, 0.95))
		return
	if emacs:
		# A Vibemacs frame: "✎", named after its buffer unless renamed.
		if custom_name == "":
			base = page_title if page_title != "" else "emacs"
		_nameplate.text = "✎ %s  (emacs)" % base
		_nameplate.add_theme_color_override("font_color", Color(0.96, 0.66, 0.72))
		return
	if page:
		# A browser tab on the board: "▣" marks it a page (as ◈ marks a remote),
		# named after the tab unless the user renamed it.
		if custom_name == "":
			base = page_title if page_title != "" else "page"
		_nameplate.text = "▣ %s  (page)" % base
		_nameplate.add_theme_color_override("font_color", Color(1.0, 0.86, 0.60))
		return
	if remote:
		var who := (" @ " + remote_peer) if remote_peer != "" else ""
		_nameplate.text = "◈ %s%s  (%d×%d)" % [base, who, cols, rows]
		_nameplate.add_theme_color_override("font_color", Color(0.66, 0.78, 1.0))
	elif link_host != "":
		var state := "" if link_up else (", " + (link_state if link_state != "" else "reconnecting"))
		_nameplate.text = "%s  @ %s%s  (%d×%d)" % [base, link_host, state, cols, rows]
		_nameplate.add_theme_color_override("font_color",
			LINK_COLOR.lightened(0.35) if link_up else LINK_DOWN_COLOR.lightened(0.2))
	else:
		_nameplate.text = "%s  (%d×%d)" % [base, cols, rows]
		_nameplate.remove_theme_color_override("font_color")


# A live terminal running on another Mac through cove-remote (not a shadow):
# the nameplate says where, and whether the link is up.
func set_remote_link(host: String, up: bool, state: String = "") -> void:
	if link_host == host and link_up == up and link_state == state:
		return
	var restyle := link_host != host or link_up != up
	link_host = host
	link_up = up
	link_state = state
	if not restyle:
		_update_nameplate()
		return
	if remote:
		_update_nameplate()   # a read-only shadow keeps its red look
		return
	# A violet mat + border (amber while reconnecting), always on, so it never
	# passes for a local termling. Red stays reserved for read-only shadows.
	_ensure_border_styles()
	_ensure_backdrop()
	var on := host != ""
	if _border:
		if on and _link_border_sb is StyleBoxFlat:
			(_link_border_sb as StyleBoxFlat).border_color = LINK_COLOR if up else LINK_DOWN_COLOR
			_border.add_theme_stylebox_override("panel", _link_border_sb)
		elif _default_border_sb:
			_border.add_theme_stylebox_override("panel", _default_border_sb)
	if _backdrop:
		_backdrop.visible = on
		var c := LINK_COLOR if up else LINK_DOWN_COLOR
		_backdrop.color = Color(c.r * 0.7, c.g * 0.7, c.b * 0.7, 0.92) if on else Color(0.72, 0.09, 0.09, 0.92)
	_layout_decorations()
	_update_nameplate()
	set_focused(_focused)


func set_custom_name(n: String) -> void:
	custom_name = n
	_update_nameplate()


# The tab title a page critter shows when it has no custom name.
func set_page_title(t: String) -> void:
	if page_title == t:
		return
	page_title = t
	_update_nameplate()


# Map a world position to native frame pixels (0..w, 0..h), clamped. Page
# critters send these to the browser as "critter pixels".
func pixel_at(world_pos: Vector2) -> Vector2:
	var local := screen.to_local(world_pos) + Vector2(_size) * 0.5
	return Vector2(clampf(local.x, 0.0, maxf(0.0, float(_size.x - 1))),
		clampf(local.y, 0.0, maxf(0.0, float(_size.y - 1))))


# The inverse of pixel_at: native frame pixels (clamped to the frame) to world.
func world_at(px: Vector2) -> Vector2:
	var p := Vector2(clampf(px.x, 0.0, float(_size.x)), clampf(px.y, 0.0, float(_size.y)))
	return screen.to_global(p - Vector2(_size) * 0.5)


# Save the current terminal frame to a PNG. Used as the drag-out image when the
# native drag code can't read the live IOSurface (e.g. the rgba-file transport,
# where iosurface_id is 0). Returns the path, or "" if there's no frame to save.
func snapshot_png(path: String) -> String:
	if screen == null or screen.texture == null:
		return ""
	var img: Image = screen.texture.get_image()
	if img == null:
		return ""
	if screen.flip_v:
		img.flip_y()   # IOSurface path holds GL bottom-up pixels
	if img.save_png(path) != OK:
		return ""
	return path


# Mark this termling a remote shadow (or clear it). Remote termlings get a red
# border (always on), a cool-blue screen tint, and a "◈" nameplate so they're
# never mistaken for a local one.
func set_remote(on: bool, peer: String = "") -> void:
	if remote == on and remote_peer == peer:
		return
	remote = on
	remote_peer = peer
	_ensure_border_styles()
	_ensure_backdrop()
	if _border:
		if on and _remote_border_sb:
			_border.add_theme_stylebox_override("panel", _remote_border_sb)
		elif _default_border_sb:
			_border.add_theme_stylebox_override("panel", _default_border_sb)
	if _backdrop:
		_backdrop.visible = on
		_backdrop.color = Color(0.72, 0.09, 0.09, 0.92)
	_layout_decorations()  # size the backdrop mat
	_update_nameplate()
	set_focused(_focused)  # re-apply tint + border visibility for current focus


# Build the red border style once, from the default blue one, so remote shadows
# read red without disturbing the local border.
func _ensure_border_styles() -> void:
	if _border == null or _default_border_sb != null:
		return
	_default_border_sb = _border.get_theme_stylebox("panel")
	if _default_border_sb is StyleBoxFlat:
		var red: StyleBoxFlat = (_default_border_sb as StyleBoxFlat).duplicate()
		red.border_color = Color(0.95, 0.25, 0.25, 0.95)
		_remote_border_sb = red
		var violet: StyleBoxFlat = (_default_border_sb as StyleBoxFlat).duplicate()
		violet.border_color = LINK_COLOR
		_link_border_sb = violet


# The red background mat, created lazily and placed BEHIND the terminal (child 0
# draws first) so the terminal content stays on top and legible.
func _ensure_backdrop() -> void:
	if _backdrop != null:
		return
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0.72, 0.09, 0.09, 0.92)  # remote red
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.visible = false
	add_child(_backdrop)
	move_child(_backdrop, 0)  # behind $Screen


# On-screen size of the terminal quad (native px * zoom).
func onscreen_size() -> Vector2:
	return Vector2(_size) * zoom


func native_size() -> Vector2i:
	return _size


# Hit test in world space (accounts for position/scale/rotation).
func contains_point(world_pos: Vector2) -> bool:
	if screen.texture == null:
		return false
	return screen.get_rect().has_point(screen.to_local(world_pos))


# Is world_pos over the resize handle (bottom-right corner)?
func over_resize_handle(world_pos: Vector2) -> bool:
	if screen.texture == null:
		return false
	var corner := position + onscreen_size() * 0.5
	return world_pos.distance_to(corner) < 22.0


func set_focused(focused: bool) -> void:
	# Focus is shown by brightness + border only. Don't touch z_index -- it would
	# override the world's y-sorting and make the focused terminal ignore depth.
	# Preserve any active search-preview transparency (alpha) across focus changes.
	_focused = focused
	var a := screen.modulate.a
	if remote:
		# Keep remote content legible (near-neutral); the red mat + red border,
		# not a screen tint, carry the "remote" signal. Dim slightly unfocused.
		screen.modulate = Color.WHITE if focused else Color(0.82, 0.78, 0.78)
	else:
		screen.modulate = Color.WHITE if focused else Color(0.62, 0.62, 0.68)
	screen.modulate.a = a
	if _border:
		# A remote shadow keeps its red border on even when unfocused.
		_border.visible = focused or remote or link_host != ""


# Temporary transparency used while previewing a search hit: an occluding
# termling fades so you can see the one behind it. 1.0 = fully opaque.
func set_dimmed(alpha: float) -> void:
	screen.modulate.a = alpha


# Like set_dimmed but eased over time — used for the tracked-termling occluder
# fade so a termling wandering in front of the camera target doesn't pop.
func ease_dim(alpha: float, delta: float) -> void:
	screen.modulate.a = lerp(screen.modulate.a, alpha, 12.0 * delta)


# Map a world position to a terminal cell (col,row), clamped. Used for mouse.
func cell_at(world_pos: Vector2) -> Vector2i:
	var local := screen.to_local(world_pos) + Vector2(_size) * 0.5  # 0..native
	var c := int(clampf(local.x / max(1.0, float(_size.x)) * cols, 0, cols - 1))
	var r := int(clampf(local.y / max(1.0, float(_size.y)) * rows, 0, rows - 1))
	return Vector2i(c, r)


# Cell (col,row) plus which half of the cell the point falls in -- kitty uses the
# half to place the selection edge precisely. Used for drag-to-select.
func cell_and_half(world_pos: Vector2) -> Dictionary:
	var local := screen.to_local(world_pos) + Vector2(_size) * 0.5  # 0..native
	var fx: float = local.x / maxf(1.0, float(_size.x)) * cols
	var fy: float = local.y / maxf(1.0, float(_size.y)) * rows
	var c := int(clampf(fx, 0, cols - 1))
	var r := int(clampf(fy, 0, rows - 1))
	return {"cell": Vector2i(c, r), "left": (fx - floorf(fx)) <= 0.5}
