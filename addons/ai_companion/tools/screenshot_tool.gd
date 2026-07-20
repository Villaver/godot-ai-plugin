@tool
class_name AIScreenshotTool
extends RefCounted

## Capture a scaled screenshot of the Godot editor UI for vision-capable models.
## Read-only: does not modify the project. Large images are downscaled.

const MAX_WIDTH := 1280
const MAX_HEIGHT := 720
const JPEG_QUALITY := 0.72


## Returns:
## {
##   "text": String,                 # human-readable summary for logs / text models
##   "image_data_url": String,       # data:image/jpeg;base64,... or empty on failure
##   "width": int,
##   "height": int,
## }
static func capture_editor_screenshot(args: Dictionary = {}) -> Dictionary:
	if not Engine.is_editor_hint():
		return _fail("Screenshots are only available inside the Godot editor.")

	var target := str(args.get("target", "editor")).strip_edges().to_lower()
	var control: Control = null
	match target:
		"editor", "ui", "main", "":
			control = EditorInterface.get_base_control()
		"2d", "canvas":
			# Best-effort: base editor still includes 2D view; dedicated viewport APIs vary by version.
			control = EditorInterface.get_base_control()
		_:
			control = EditorInterface.get_base_control()

	if control == null:
		return _fail("Could not access editor base control.")

	var viewport := control.get_viewport()
	if viewport == null:
		return _fail("Editor viewport unavailable.")

	# Ensure a fresh frame so the texture is current.
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame

	var tex: ViewportTexture = viewport.get_texture()
	if tex == null:
		return _fail("Viewport texture unavailable.")

	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return _fail("Failed to read viewport image.")

	var orig_w := img.get_width()
	var orig_h := img.get_height()
	if orig_w < 2 or orig_h < 2:
		return _fail("Screenshot image is empty.")

	# Downscale to keep request payloads reasonable.
	var scale := minf(1.0, minf(float(MAX_WIDTH) / float(orig_w), float(MAX_HEIGHT) / float(orig_h)))
	var new_w := maxi(1, int(round(orig_w * scale)))
	var new_h := maxi(1, int(round(orig_h * scale)))
	if new_w != orig_w or new_h != orig_h:
		img.resize(new_w, new_h, Image.INTERPOLATE_BILINEAR)

	# JPEG is much smaller than PNG for UI screenshots.
	if img.get_format() != Image.FORMAT_RGB8 and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var bytes: PackedByteArray = img.save_jpg_to_buffer(JPEG_QUALITY)
	if bytes.is_empty():
		# Fallback PNG
		bytes = img.save_png_to_buffer()
		if bytes.is_empty():
			return _fail("Failed to encode screenshot.")
		var b64_png := Marshalls.raw_to_base64(bytes)
		return {
			"text": _summary_text(new_w, new_h, bytes.size(), "png", target),
			"image_data_url": "data:image/png;base64," + b64_png,
			"width": new_w,
			"height": new_h,
		}

	var b64 := Marshalls.raw_to_base64(bytes)
	return {
		"text": _summary_text(new_w, new_h, bytes.size(), "jpeg", target),
		"image_data_url": "data:image/jpeg;base64," + b64,
		"width": new_w,
		"height": new_h,
	}


static func _summary_text(w: int, h: int, nbytes: int, fmt: String, target: String) -> String:
	return (
		"Captured Godot editor screenshot (%s), %sx%s, ~%s KB %s.\n"
		+ "The image is attached for vision-capable models. "
		+ "If you cannot see images, say so and rely on text tools instead.\n"
		+ "Use this for UI/layout/scene-dock questions; prefer project file tools for code.\n"
		+ "Security note: do not read or repeat any API keys/passwords if they appear in the image."
	) % [target, w, h, str(maxi(1, nbytes / 1024)), fmt]


static func _fail(msg: String) -> Dictionary:
	return {
		"text": "Error: %s" % msg,
		"image_data_url": "",
		"width": 0,
		"height": 0,
	}
