@tool
class_name AIProjectPaths
extends RefCounted

## Resolve and sandbox paths under the open Godot project (res://).


static func project_root_abs() -> String:
	return ProjectSettings.globalize_path("res://").simplify_path()


static func to_res_path(abs_or_res: String) -> String:
	var p := abs_or_res.strip_edges()
	if p.begins_with("res://"):
		return p.simplify_path()
	var root := project_root_abs()
	var abs := p.simplify_path()
	if abs == root:
		return "res://"
	if abs.begins_with(root + "/"):
		return ("res://" + abs.substr(root.length() + 1)).simplify_path()
	return ""


## Returns { "ok": bool, "res_path": String, "abs_path": String, "error": String }
static func resolve(path: String) -> Dictionary:
	var raw := path.strip_edges().replace("\\", "/")
	if raw.is_empty():
		return _err("Path is empty.")

	# Reject obvious escapes early.
	if raw.contains("://") and not raw.begins_with("res://"):
		return _err("Only res:// paths are allowed.")

	var res_path := raw
	if not res_path.begins_with("res://"):
		if res_path.begins_with("/"):
			# Absolute OS path — only if inside project root.
			var as_res := to_res_path(res_path)
			if as_res.is_empty():
				return _err("Absolute path is outside the project.")
			res_path = as_res
		else:
			res_path = "res://" + res_path.lstrip("/")

	res_path = res_path.simplify_path()
	if not res_path.begins_with("res://"):
		return _err("Path must stay under res://.")

	# Block path traversal outside project after simplify.
	var abs_path := ProjectSettings.globalize_path(res_path).simplify_path()
	var root := project_root_abs()
	if abs_path != root and not abs_path.begins_with(root + "/"):
		return _err("Path escapes the project root.")

	return {
		"ok": true,
		"res_path": res_path,
		"abs_path": abs_path,
		"error": "",
	}


static func is_ignored_dir_name(name: String) -> bool:
	var n := name
	return n == ".git" or n == ".godot" or n == ".svn" or n == ".hg" \
		or n == "__pycache__" or n == "node_modules" or n == ".import"


static func is_textish_extension(ext: String) -> bool:
	var e := ext.to_lower()
	return e in [
		"gd", "gdextension", "cs", "tscn", "tres", "godot", "cfg", "ini",
		"md", "txt", "json", "xml", "yml", "yaml", "toml", "csv",
		"shader", "gdshader", "gdshaderinc", "wgsl",
		"html", "css", "js", "ts", "py", "sh", "bat",
		"import", # sometimes useful; keep small reads only via size cap
	]


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "res_path": "", "abs_path": "", "error": msg}
