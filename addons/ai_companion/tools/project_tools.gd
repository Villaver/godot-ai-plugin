@tool
class_name AIProjectTools
extends RefCounted

## Read-only project introspection tools. Never writes or mutates files.

const Paths := preload("res://addons/ai_companion/tools/project_paths.gd")
const Secrets := preload("res://addons/ai_companion/core/secrets.gd")

const DEFAULT_LIST_MAX := 400
const DEFAULT_READ_MAX_CHARS := 12000
const DEFAULT_FIND_MAX_MATCHES := 40
const DEFAULT_FIND_MAX_FILES := 800


static func list_project_files(args: Dictionary) -> String:
	var root_arg := str(args.get("path", "res://")).strip_edges()
	if root_arg.is_empty():
		root_arg = "res://"
	var resolved := Paths.resolve(root_arg)
	if not resolved["ok"]:
		return "Error: %s" % resolved["error"]

	var max_entries := int(args.get("max_entries", DEFAULT_LIST_MAX))
	max_entries = clampi(max_entries, 1, 2000)
	var recursive := true
	if args.has("recursive"):
		recursive = bool(args["recursive"])

	var root_res: String = resolved["res_path"]
	var root_abs: String = resolved["abs_path"]
	if not DirAccess.dir_exists_absolute(root_abs) and not FileAccess.file_exists(root_abs):
		return "Error: path does not exist: %s" % root_res
	if FileAccess.file_exists(root_abs) and not DirAccess.dir_exists_absolute(root_abs):
		return "File: %s" % root_res

	var out: PackedStringArray = []
	var truncated := false
	_walk_list(root_abs, root_res, recursive, out, max_entries, func(): truncated = true)

	if out.is_empty():
		return "No files found under %s (ignored .godot/.git)." % root_res

	var header := "Project files under %s (%s listed%s):" % [
		root_res,
		out.size(),
		"; truncated" if truncated else "",
	]
	return header + "\n" + "\n".join(out)


static func read_project_file(args: Dictionary) -> String:
	var path_arg := str(args.get("path", "")).strip_edges()
	if path_arg.is_empty():
		return "Error: path is required."

	var resolved := Paths.resolve(path_arg)
	if not resolved["ok"]:
		return "Error: %s" % resolved["error"]

	var res_path: String = resolved["res_path"]
	var abs_path: String = resolved["abs_path"]
	if DirAccess.dir_exists_absolute(abs_path):
		return "Error: %s is a directory. Use list_project_files." % res_path
	if not FileAccess.file_exists(abs_path):
		return "Error: file not found: %s" % res_path

	# Never feed likely secrets (API keys, env files, private keys) to the model.
	if Secrets.looks_like_secret_filename(res_path) or Secrets.looks_like_secret_filename(abs_path):
		return (
			"Error: refusing to read likely secret/credential file: %s. "
			+ "API keys and secrets must stay out of model context."
		) % res_path

	var max_chars := int(args.get("max_chars", DEFAULT_READ_MAX_CHARS))
	max_chars = clampi(max_chars, 500, 50000)

	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return "Error: could not open %s (%s)" % [res_path, FileAccess.get_open_error()]

	var size := f.get_length()
	# Soft binary guard: skip huge files and obvious binary extensions.
	var ext := res_path.get_extension().to_lower()
	if ext in ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "wav", "ogg", "mp3", "mp4",
			"bin", "exe", "dll", "dylib", "so", "zip", "pck", "import"]:
		if ext != "import" and ext != "svg":
			return "Error: refusing to read binary/media file: %s (%s bytes). Describe it instead or use a text source." % [
				res_path, size
			]

	var text := f.get_as_text()
	f.close()

	# Detect NUL-ish binary
	if text.contains(char(0)):
		return "Error: file looks binary: %s" % res_path

	# If the file body looks like it contains the configured API key, refuse.
	var Config := preload("res://addons/ai_companion/core/config.gd")
	if Config.text_contains_api_key(text):
		return (
			"Error: refusing to read %s — content appears to include the configured API key."
		) % res_path

	var truncated := false
	if text.length() > max_chars:
		text = text.substr(0, max_chars)
		truncated = true

	var header := "File: %s (%s bytes%s)" % [
		res_path,
		size,
		"; truncated to %s chars" % max_chars if truncated else "",
	]
	# Redact any accidental key-shaped tokens before they reach the model.
	return header + "\n\n" + Secrets.redact(text)


static func find_in_project(args: Dictionary) -> String:
	var query := str(args.get("query", "")).strip_edges()
	if query.is_empty():
		return "Error: query is required."

	var root_arg := str(args.get("path", "res://")).strip_edges()
	if root_arg.is_empty():
		root_arg = "res://"
	var resolved := Paths.resolve(root_arg)
	if not resolved["ok"]:
		return "Error: %s" % resolved["error"]

	var case_sensitive := false
	if args.has("case_sensitive"):
		case_sensitive = bool(args["case_sensitive"])
	var max_matches := clampi(int(args.get("max_matches", DEFAULT_FIND_MAX_MATCHES)), 1, 200)
	var max_files := clampi(int(args.get("max_files", DEFAULT_FIND_MAX_FILES)), 1, 5000)

	var root_res: String = resolved["res_path"]
	var root_abs: String = resolved["abs_path"]
	var needle := query if case_sensitive else query.to_lower()

	var matches: PackedStringArray = []
	var files_scanned := 0
	var files_truncated := false
	var matches_truncated := false

	var files: PackedStringArray = []
	_collect_text_files(root_abs, root_res, files, max_files, func(): files_truncated = true)

	for res_file in files:
		if matches.size() >= max_matches:
			matches_truncated = true
			break
		# Never open/search likely secret files (keys, .env, certs).
		if Secrets.looks_like_secret_filename(str(res_file)):
			continue
		files_scanned += 1
		var abs_file := ProjectSettings.globalize_path(res_file)
		var f := FileAccess.open(abs_file, FileAccess.READ)
		if f == null:
			continue
		# Cap per-file read for search
		var content := f.get_as_text()
		f.close()
		if content.contains(char(0)):
			continue
		if content.length() > 400_000:
			content = content.substr(0, 400_000)

		var lines := content.split("\n")
		for i in lines.size():
			if matches.size() >= max_matches:
				matches_truncated = true
				break
			var line: String = lines[i]
			var hay := line if case_sensitive else line.to_lower()
			if hay.find(needle) >= 0:
				var shown := Secrets.redact(line.strip_edges())
				if shown.length() > 200:
					shown = shown.substr(0, 200) + "…"
				matches.append("%s:%s: %s" % [res_file, i + 1, shown])

	if matches.is_empty():
		return "No matches for %s under %s (%s text files scanned%s)." % [
			JSON.stringify(query),
			root_res,
			files_scanned,
			"; file scan truncated" if files_truncated else "",
		]

	var header := "Matches for %s under %s (%s shown%s, %s files scanned%s):" % [
		JSON.stringify(query),
		root_res,
		matches.size(),
		"; match list truncated" if matches_truncated else "",
		files_scanned,
		"; file scan truncated" if files_truncated else "",
	]
	return header + "\n" + "\n".join(matches)


static func _walk_list(
	abs_dir: String,
	res_dir: String,
	recursive: bool,
	out: PackedStringArray,
	max_entries: int,
	on_trunc: Callable
) -> void:
	var da := DirAccess.open(abs_dir)
	if da == null:
		return
	da.list_dir_begin()
	var entry := da.get_next()
	var dirs: PackedStringArray = []
	var files: PackedStringArray = []
	while entry != "":
		if entry == "." or entry == "..":
			entry = da.get_next()
			continue
		if Paths.is_ignored_dir_name(entry):
			entry = da.get_next()
			continue
		if da.current_is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
		entry = da.get_next()
	da.list_dir_end()

	dirs.sort()
	files.sort()

	for d in dirs:
		if out.size() >= max_entries:
			on_trunc.call()
			return
		var child_res_d := ("res://" + d) if res_dir == "res://" else res_dir.rstrip("/") + "/" + d
		out.append(child_res_d + "/")
		if recursive:
			_walk_list(abs_dir.path_join(d), child_res_d, true, out, max_entries, on_trunc)
			if out.size() >= max_entries:
				return

	for f in files:
		if out.size() >= max_entries:
			on_trunc.call()
			return
		var child_res_f := ("res://" + f) if res_dir == "res://" else res_dir.rstrip("/") + "/" + f
		out.append(child_res_f)


static func _collect_text_files(
	abs_dir: String,
	res_dir: String,
	out: PackedStringArray,
	max_files: int,
	on_trunc: Callable
) -> void:
	var da := DirAccess.open(abs_dir)
	if da == null:
		return
	da.list_dir_begin()
	var entry := da.get_next()
	var dirs: PackedStringArray = []
	var files: PackedStringArray = []
	while entry != "":
		if entry == "." or entry == "..":
			entry = da.get_next()
			continue
		if Paths.is_ignored_dir_name(entry):
			entry = da.get_next()
			continue
		if da.current_is_dir():
			dirs.append(entry)
		else:
			files.append(entry)
		entry = da.get_next()
	da.list_dir_end()
	dirs.sort()
	files.sort()

	for f in files:
		if out.size() >= max_files:
			on_trunc.call()
			return
		var ext := f.get_extension()
		if not Paths.is_textish_extension(ext):
			continue
		# Skip heavy/generated import sidecars for search noise
		if ext.to_lower() == "import":
			continue
		var child_res := ("res://" + f) if res_dir == "res://" else res_dir.rstrip("/") + "/" + f
		# Do not search secret/credential files.
		if Secrets.looks_like_secret_filename(child_res):
			continue
		out.append(child_res)

	for d in dirs:
		if out.size() >= max_files:
			on_trunc.call()
			return
		var child_res_d := ("res://" + d) if res_dir == "res://" else res_dir.rstrip("/") + "/" + d
		_collect_text_files(abs_dir.path_join(d), child_res_d, out, max_files, on_trunc)
