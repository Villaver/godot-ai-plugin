@tool
class_name AISceneTools
extends RefCounted

## Read-only Godot scene (.tscn) introspection: node tree, scripts, connections.

const Paths := preload("res://addons/ai_companion/tools/project_paths.gd")

const MAX_NODES_LISTED := 250
const MAX_CONNECTIONS := 200
const MAX_EXT_RESOURCES := 80


static func describe_scene(args: Dictionary) -> String:
	var path_arg := str(args.get("path", "")).strip_edges()
	if path_arg.is_empty():
		path_arg = _default_scene_path()
	if path_arg.is_empty():
		return (
			"Error: no scene path given and no edited/open scene in the editor. "
			+ "Pass <path>res://something.tscn</path>."
		)

	var resolved := Paths.resolve(path_arg)
	if not resolved["ok"]:
		return "Error: %s" % resolved["error"]

	var res_path: String = resolved["res_path"]
	var abs_path: String = resolved["abs_path"]
	var ext := res_path.get_extension().to_lower()
	if ext == "scn":
		return "Error: binary .scn is not supported. Use a text .tscn scene."
	if ext != "tscn":
		return "Error: describe_scene expects a .tscn path, got: %s" % res_path

	if not FileAccess.file_exists(abs_path):
		return "Error: scene not found: %s" % res_path

	var text := FileAccess.get_file_as_string(abs_path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return "Error: could not read %s" % res_path

	var parsed := parse_tscn(text, res_path)
	return format_scene_report(parsed, args)


static func find_signal_usage(args: Dictionary) -> String:
	var signal_name := str(args.get("signal", args.get("name", args.get("query", "")))).strip_edges()
	if signal_name.is_empty():
		return "Error: signal name is required (param <signal>)."

	# Strip quotes if model wrapped them.
	signal_name = signal_name.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")

	var root_arg := str(args.get("path", "res://")).strip_edges()
	if root_arg.is_empty():
		root_arg = "res://"
	var resolved := Paths.resolve(root_arg)
	if not resolved["ok"]:
		return "Error: %s" % resolved["error"]

	var max_hits := clampi(int(args.get("max_matches", 60)), 1, 200)
	var root_res: String = resolved["res_path"]
	var root_abs: String = resolved["abs_path"]

	var scene_hits: PackedStringArray = []
	var script_hits: PackedStringArray = []
	var files_scanned := 0
	var truncated := false

	var files: PackedStringArray = []
	_collect_scene_and_script_files(root_abs, root_res, files, 2000)

	var conn_re := RegEx.new()
	# [connection signal="foo" from="A" to="B" method="bar" ...]
	conn_re.compile("(?m)^\\[connection\\s+([^\\]]*)\\]")

	var gd_patterns: Array[RegEx] = []
	for pat in [
		# signal declaration
		"(?m)^\\s*signal\\s+%s\\b" % _re_escape(signal_name),
		# emit_signal("name"
		"emit_signal\\s*\\(\\s*[\"']%s[\"']" % _re_escape(signal_name),
		# .name.emit(
		"\\.%s\\s*\\.\\s*emit\\s*\\(" % _re_escape(signal_name),
		# connect("name"
		"connect\\s*\\(\\s*[\"']%s[\"']" % _re_escape(signal_name),
		# .name.connect(
		"\\.%s\\s*\\.\\s*connect\\s*\\(" % _re_escape(signal_name),
		# disconnect variants
		"disconnect\\s*\\(\\s*[\"']%s[\"']" % _re_escape(signal_name),
		"\\.%s\\s*\\.\\s*disconnect\\s*\\(" % _re_escape(signal_name),
		# await signal
		"await\\s+[^\\n]*%s\\b" % _re_escape(signal_name),
	]:
		var r := RegEx.new()
		if r.compile(pat) == OK:
			gd_patterns.append(r)

	for res_file in files:
		if scene_hits.size() + script_hits.size() >= max_hits:
			truncated = true
			break
		files_scanned += 1
		var abs_file := ProjectSettings.globalize_path(res_file)
		var content := FileAccess.get_file_as_string(abs_file)
		if content.is_empty():
			continue
		var ext := res_file.get_extension().to_lower()
		if ext == "tscn":
			for m in conn_re.search_all(content):
				if scene_hits.size() + script_hits.size() >= max_hits:
					truncated = true
					break
				var attrs := _parse_connection_attrs(m.get_string(1))
				if str(attrs.get("signal", "")) != signal_name:
					continue
				var binds_bit := ""
				if attrs.has("binds") and not str(attrs.get("binds", "")).is_empty():
					binds_bit = " binds=%s" % attrs.get("binds", "")
				scene_hits.append(
					"%s: connection signal=%s from=%s to=%s method=%s%s" % [
						res_file,
						signal_name,
						attrs.get("from", "?"),
						attrs.get("to", "?"),
						attrs.get("method", "?"),
						binds_bit,
					]
				)
			# Also note nodes that declare the signal via script — covered in scripts.
		elif ext == "gd" or ext == "cs":
			var lines := content.split("\n")
			for i in lines.size():
				if scene_hits.size() + script_hits.size() >= max_hits:
					truncated = true
					break
				var line: String = lines[i]
				var matched := false
				for r in gd_patterns:
					if r.search(line) != null:
						matched = true
						break
				# Fallback plain contains for unusual formatting
				if not matched and line.find(signal_name) >= 0:
					var lower := line.strip_edges()
					if lower.begins_with("#"):
						continue
					# Avoid huge false positives on short names by requiring word-ish context
					if signal_name.length() < 4 and not lower.contains("signal") \
							and not lower.contains("connect") and not lower.contains("emit"):
						continue
					matched = lower.contains(signal_name)
				if matched:
					var shown := line.strip_edges()
					if shown.length() > 180:
						shown = shown.substr(0, 180) + "…"
					script_hits.append("%s:%s: %s" % [res_file, i + 1, shown])

	if scene_hits.is_empty() and script_hits.is_empty():
		return (
			"No usages found for signal \"%s\" under %s (%s scene/script files scanned).\n"
			+ "Tip: confirm the exact signal name (case-sensitive) or try find_in_project."
		) % [signal_name, root_res, files_scanned]

	var parts: PackedStringArray = []
	parts.append("Signal usage for \"%s\" under %s (%s files scanned%s):" % [
		signal_name,
		root_res,
		files_scanned,
		"; truncated" if truncated else "",
	])
	if not scene_hits.is_empty():
		parts.append("\n## Scene connections (%s)" % scene_hits.size())
		parts.append("\n".join(scene_hits))
	if not script_hits.is_empty():
		parts.append("\n## Script references (%s)" % script_hits.size())
		parts.append("\n".join(script_hits))
	return "\n".join(parts)


## Parse tscn text into a structured dictionary.
static func parse_tscn(text: String, res_path: String = "") -> Dictionary:
	var ext_resources: Array[Dictionary] = []
	var sub_resources: Array[Dictionary] = []
	var nodes: Array[Dictionary] = []
	var connections: Array[Dictionary] = []
	var header := {}
	var load_steps := 0
	var format_ver := 0

	var header_re := RegEx.new()
	header_re.compile("(?m)^\\[gd_scene([^\\]]*)\\]")
	var hm := header_re.search(text)
	if hm:
		header = _parse_attr_blob(hm.get_string(1))
		load_steps = int(header.get("load_steps", 0))
		format_ver = int(header.get("format", 0))

	var ext_re := RegEx.new()
	ext_re.compile("(?m)^\\[ext_resource\\s+([^\\]]*)\\]")
	for m in ext_re.search_all(text):
		var attrs := _parse_attr_blob(m.get_string(1))
		ext_resources.append(attrs)

	var sub_re := RegEx.new()
	sub_re.compile("(?m)^\\[sub_resource\\s+([^\\]]*)\\]")
	for m in sub_re.search_all(text):
		var attrs := _parse_attr_blob(m.get_string(1))
		sub_resources.append(attrs)

	# Node blocks: [node ...] followed by property lines until next section
	var node_re := RegEx.new()
	node_re.compile("(?ms)^\\[node\\s+([^\\]]*)\\]\\n(.*?)(?=^\\[|\\z)")
	var root_name := ""

	for m in node_re.search_all(text):
		var attrs := _parse_attr_blob(m.get_string(1))
		var body := m.get_string(2)
		var name := str(attrs.get("name", ""))
		var ntype := str(attrs.get("type", ""))
		var parent := str(attrs.get("parent", ""))
		var instance_ref := str(attrs.get("instance", ""))
		var groups := str(attrs.get("groups", ""))

		var node_path := ""
		if parent.is_empty():
			# Root node
			root_name = name
			node_path = name
		elif parent == ".":
			node_path = "%s/%s" % [root_name, name] if not root_name.is_empty() else name
		else:
			# parent is path relative to root (without root name prefix in file)
			if not root_name.is_empty():
				node_path = "%s/%s/%s" % [root_name, parent, name]
			else:
				node_path = "%s/%s" % [parent, name]

		var script_path := _extract_script_path(body, ext_resources)
		var unique_name := body.find("unique_name_in_owner = true") >= 0
		var props := _extract_interesting_props(body)

		nodes.append({
			"name": name,
			"type": ntype,
			"parent": parent,
			"path": node_path,
			"instance": instance_ref,
			"instance_path": _resolve_ext_path(instance_ref, ext_resources),
			"script": script_path,
			"groups": groups,
			"unique_name": unique_name,
			"props": props,
		})

	var conn_re := RegEx.new()
	conn_re.compile("(?m)^\\[connection\\s+([^\\]]*)\\]")
	for m in conn_re.search_all(text):
		var attrs := _parse_connection_attrs(m.get_string(1))
		# Normalize from/to display paths with root name when using "."
		attrs["from_display"] = _connection_endpoint(str(attrs.get("from", "")), root_name)
		attrs["to_display"] = _connection_endpoint(str(attrs.get("to", "")), root_name)
		connections.append(attrs)

	return {
		"path": res_path,
		"format": format_ver,
		"load_steps": load_steps,
		"root_name": root_name,
		"ext_resources": ext_resources,
		"sub_resource_count": sub_resources.size(),
		"nodes": nodes,
		"connections": connections,
	}


static func format_scene_report(parsed: Dictionary, args: Dictionary = {}) -> String:
	var res_path := str(parsed.get("path", ""))
	var nodes: Array = parsed.get("nodes", [])
	var connections: Array = parsed.get("connections", [])
	var ext_resources: Array = parsed.get("ext_resources", [])
	var include_props := true
	if args.has("include_props"):
		include_props = bool(args["include_props"])

	var lines: PackedStringArray = []
	lines.append("# Scene: %s" % res_path)
	lines.append("Format: %s | nodes: %s | connections: %s | ext_resources: %s | sub_resources: %s" % [
		parsed.get("format", "?"),
		nodes.size(),
		connections.size(),
		ext_resources.size(),
		parsed.get("sub_resource_count", 0),
	])
	if not str(parsed.get("root_name", "")).is_empty():
		lines.append("Root: %s" % parsed.get("root_name"))

	# Ext resources (scripts + packed scenes mainly)
	if not ext_resources.is_empty():
		lines.append("\n## External resources")
		var shown := 0
		for er in ext_resources:
			if shown >= MAX_EXT_RESOURCES:
				lines.append("… (%s more ext_resources)" % (ext_resources.size() - shown))
				break
			var t := str(er.get("type", ""))
			var p := str(er.get("path", er.get("id", "")))
			var id := str(er.get("id", ""))
			lines.append("- [%s] %s (%s)" % [id, p, t])
			shown += 1

	lines.append("\n## Node tree")
	var n_shown := 0
	for n in nodes:
		if n_shown >= MAX_NODES_LISTED:
			lines.append("… (%s more nodes)" % (nodes.size() - n_shown))
			break
		var bit := "- %s" % n.get("path", n.get("name", "?"))
		var t := str(n.get("type", ""))
		if t.is_empty() and not str(n.get("instance_path", "")).is_empty():
			bit += "  [instance %s]" % n.get("instance_path")
		elif t.is_empty() and not str(n.get("instance", "")).is_empty():
			bit += "  [instance %s]" % n.get("instance")
		else:
			bit += "  (%s)" % t
		if not str(n.get("script", "")).is_empty():
			bit += "  script=%s" % n.get("script")
		if bool(n.get("unique_name", false)):
			bit += "  unique_name"
		var groups := str(n.get("groups", ""))
		if not groups.is_empty():
			bit += "  groups=%s" % groups
		lines.append(bit)
		if include_props:
			var props: Dictionary = n.get("props", {})
			for pk in props.keys():
				lines.append("    %s = %s" % [pk, props[pk]])
		n_shown += 1

	lines.append("\n## Signal connections")
	if connections.is_empty():
		lines.append("(none in this scene file)")
	else:
		var c_shown := 0
		for c in connections:
			if c_shown >= MAX_CONNECTIONS:
				lines.append("… (%s more connections)" % (connections.size() - c_shown))
				break
			lines.append("- %s.%s → %s.%s" % [
				c.get("from_display", c.get("from", "?")),
				c.get("signal", "?"),
				c.get("to_display", c.get("to", "?")),
				c.get("method", "?"),
			])
			c_shown += 1

	# Scripts overview
	var scripts: PackedStringArray = []
	for n in nodes:
		var sp := str(n.get("script", ""))
		if not sp.is_empty() and sp not in scripts:
			scripts.append(sp)
	if not scripts.is_empty():
		lines.append("\n## Scripts attached")
		for sp in scripts:
			lines.append("- %s" % sp)

	return "\n".join(lines)


static func _default_scene_path() -> String:
	if not Engine.is_editor_hint():
		return ""
	var edited := EditorInterface.get_edited_scene_root()
	if edited and not edited.scene_file_path.is_empty():
		return edited.scene_file_path
	var open_scenes: PackedStringArray = EditorInterface.get_open_scenes()
	if not open_scenes.is_empty():
		return open_scenes[0]
	var main := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	return main


static func _parse_attr_blob(blob: String) -> Dictionary:
	var attrs := {}
	# key=value pairs; values may be "strings", numbers, ExtResource("id"), etc.
	var re := RegEx.new()
	re.compile("([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(\"(?:\\\\.|[^\"\\\\])*\"|[^\\s\\]]+)")
	for m in re.search_all(blob):
		var key := m.get_string(1)
		var raw := m.get_string(2).strip_edges()
		attrs[key] = _unquote(raw)
	return attrs


static func _parse_connection_attrs(blob: String) -> Dictionary:
	return _parse_attr_blob(blob)


static func _unquote(raw: String) -> String:
	if raw.length() >= 2 and raw.begins_with("\"") and raw.ends_with("\""):
		var inner := raw.substr(1, raw.length() - 2)
		return inner.replace("\\\"", "\"").replace("\\\\", "\\")
	return raw


static func _extract_script_path(body: String, ext_resources: Array) -> String:
	var re := RegEx.new()
	re.compile("(?m)^script\\s*=\\s*ExtResource\\(\\\"?([^\\\"\\)]+)\\\"?\\)")
	var m := re.search(body)
	if m == null:
		return ""
	var id := m.get_string(1)
	return _resolve_ext_path_by_id(id, ext_resources)


static func _resolve_ext_path(instance_ref: String, ext_resources: Array) -> String:
	# instance=ExtResource("2_abc")
	if instance_ref.is_empty():
		return ""
	var re := RegEx.new()
	re.compile("ExtResource\\(\\\"?([^\\\"\\)]+)\\\"?\\)")
	var m := re.search(instance_ref)
	if m == null:
		return ""
	return _resolve_ext_path_by_id(m.get_string(1), ext_resources)


static func _resolve_ext_path_by_id(id: String, ext_resources: Array) -> String:
	var want := id.strip_edges()
	for er in ext_resources:
		if str(er.get("id", "")) == want:
			return str(er.get("path", ""))
	return ""


static func _extract_interesting_props(body: String) -> Dictionary:
	var props := {}
	var interesting := [
		"text", "title", "placeholder_text", "collision_layer", "collision_mask",
		"monitorable", "monitoring", "max_value", "value", "min_value",
		"animation", "autoplay", "stream", "bus", "layout_mode",
		"anchors_preset", "visible", "modulate", "z_index", "process_mode",
	]
	for key in interesting:
		var re := RegEx.new()
		re.compile("(?m)^%s\\s*=\\s*(.+)$" % key)
		var m := re.search(body)
		if m:
			var val := m.get_string(1).strip_edges()
			if val.length() > 80:
				val = val.substr(0, 80) + "…"
			props[key] = val
	return props


static func _connection_endpoint(endpoint: String, root_name: String) -> String:
	if endpoint.is_empty():
		return "?"
	if endpoint == ".":
		return root_name if not root_name.is_empty() else "."
	if not root_name.is_empty():
		return "%s/%s" % [root_name, endpoint]
	return endpoint


static func _re_escape(s: String) -> String:
	var out := s
	for ch in ["\\", ".", "+", "*", "?", "^", "$", "(", ")", "[", "]", "{", "}", "|"]:
		out = out.replace(ch, "\\" + ch)
	return out


static func _collect_scene_and_script_files(
	abs_dir: String,
	res_dir: String,
	out: PackedStringArray,
	max_files: int
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
			return
		var ext := f.get_extension().to_lower()
		if ext != "tscn" and ext != "gd" and ext != "cs":
			continue
		var child_res := ("res://" + f) if res_dir == "res://" else res_dir.rstrip("/") + "/" + f
		out.append(child_res)
	for d in dirs:
		if out.size() >= max_files:
			return
		var child_res_d := ("res://" + d) if res_dir == "res://" else res_dir.rstrip("/") + "/" + d
		_collect_scene_and_script_files(abs_dir.path_join(d), child_res_d, out, max_files)
