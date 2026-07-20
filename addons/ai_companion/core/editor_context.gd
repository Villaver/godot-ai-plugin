@tool
class_name AIEditorContext
extends RefCounted

## Lightweight, read-only snapshot of the Godot editor + project for the system prompt.


static func build_summary(max_chars: int = 3500) -> String:
	var parts: PackedStringArray = []

	var ver := Engine.get_version_info()
	parts.append("Godot %s.%s.%s (%s)" % [
		ver.get("major", "?"),
		ver.get("minor", "?"),
		ver.get("patch", 0),
		ver.get("status", ""),
	])

	var project_name := str(ProjectSettings.get_setting("application/config/name", ""))
	if project_name.strip_edges().is_empty():
		project_name = "(unnamed project)"
	parts.append("Project: %s" % project_name)

	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if not main_scene.is_empty():
		parts.append("Main scene: %s" % main_scene)

	var features: Variant = ProjectSettings.get_setting("application/config/features", PackedStringArray())
	if features is PackedStringArray and not (features as PackedStringArray).is_empty():
		parts.append("Features: %s" % ", ".join(features))
	elif features is Array and not (features as Array).is_empty():
		var fs: PackedStringArray = []
		for f in features:
			fs.append(str(f))
		parts.append("Features: %s" % ", ".join(fs))

	# Autoloads
	var autoloads: PackedStringArray = []
	for key in ProjectSettings.get_property_list():
		var pname := str(key.get("name", ""))
		if pname.begins_with("autoload/"):
			var aname := pname.substr("autoload/".length())
			var aval := str(ProjectSettings.get_setting(pname, ""))
			autoloads.append("%s → %s" % [aname, aval])
	if not autoloads.is_empty():
		parts.append("Autoloads (%s): %s" % [autoloads.size(), _join_limited(autoloads, 20)])

	# Editor-only details
	if Engine.is_editor_hint():
		_append_editor_details(parts)

	var text := "\n".join(parts)
	if text.length() > max_chars:
		text = text.substr(0, max_chars) + "\n[…editor context truncated]"
	return text


static func _append_editor_details(parts: PackedStringArray) -> void:
	var edited_root := EditorInterface.get_edited_scene_root()
	if edited_root:
		var scene_path := edited_root.scene_file_path
		if scene_path.is_empty():
			scene_path = "(unsaved scene)"
		parts.append("Edited scene: %s (root: %s : %s)" % [
			scene_path,
			edited_root.name,
			edited_root.get_class(),
		])
	else:
		parts.append("Edited scene: (none)")

	var open_scenes: PackedStringArray = EditorInterface.get_open_scenes()
	if not open_scenes.is_empty():
		parts.append("Open scenes (%s): %s" % [
			open_scenes.size(),
			_join_limited(open_scenes, 12),
		])

	var selected: PackedStringArray = EditorInterface.get_selected_paths()
	if not selected.is_empty():
		parts.append("FileSystem selection (%s): %s" % [
			selected.size(),
			_join_limited(selected, 8),
		])

	var se := EditorInterface.get_script_editor()
	if se == null:
		return
	var current := se.get_current_editor()
	var cur_script: Script = se.get_current_script()
	if cur_script:
		var spath := cur_script.resource_path
		parts.append("Focused script: %s" % (spath if not spath.is_empty() else "(unsaved script)"))
	else:
		parts.append("Focused script: (none)")

	if current != null:
		var base: Control = current.get_base_editor()
		if base is TextEdit:
			var te := base as TextEdit
			var selected_text := te.get_selected_text()
			if not selected_text.strip_edges().is_empty():
				var sel := selected_text
				if sel.length() > 1200:
					sel = sel.substr(0, 1200) + "\n…[selection truncated]"
				parts.append("Current selection in script:\n```\n%s\n```" % sel)
			else:
				var line := te.get_caret_line()
				var col := te.get_caret_column()
				parts.append("Script caret: line %s, column %s" % [line + 1, col])
				var from_l := maxi(0, line - 3)
				var to_l := mini(te.get_line_count() - 1, line + 3)
				var snippet: PackedStringArray = []
				for li in range(from_l, to_l + 1):
					var mark := ">" if li == line else " "
					snippet.append("%s%4d | %s" % [mark, li + 1, te.get_line(li)])
				parts.append("Nearby lines:\n```\n%s\n```" % "\n".join(snippet))


static func build_tool_report() -> String:
	return "Editor / project context:\n" + build_summary(8000)


static func _join_limited(items: PackedStringArray, limit: int) -> String:
	var n := mini(limit, items.size())
	var parts: PackedStringArray = []
	for i in n:
		parts.append(items[i])
	var joined := ", ".join(parts)
	if items.size() > limit:
		joined += " …"
	return joined
