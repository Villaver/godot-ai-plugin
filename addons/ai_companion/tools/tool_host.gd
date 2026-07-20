@tool
class_name AIToolHost
extends RefCounted

## Registry of read-only tools. Write/mutation tools are intentionally absent.
## All execution goes through the allowlist + injection guard.

const WebTools := preload("res://addons/ai_companion/tools/web_tools.gd")
const ProjectTools := preload("res://addons/ai_companion/tools/project_tools.gd")
const SceneTools := preload("res://addons/ai_companion/tools/scene_tools.gd")
const ScreenshotTool := preload("res://addons/ai_companion/tools/screenshot_tool.gd")
const EditorContext := preload("res://addons/ai_companion/core/editor_context.gd")
const ActionParser := preload("res://addons/ai_companion/tools/action_parser.gd")
const InjectionGuard := preload("res://addons/ai_companion/tools/injection_guard.gd")

const MAX_RESULT_CHARS := 14000


static func tool_specs() -> Array[Dictionary]:
	return [
		{
			"name": "web_search",
			"description": "Search the web via DuckDuckGo. Returns a numbered list of titles, URLs, and snippets.",
			"params": [{"name": "query", "description": "what to search for", "required": true}],
			"example": "<action name=\"web_search\">\n<query>Godot 4 CharacterBody2D move_and_slide</query>\n</action>",
		},
		{
			"name": "fetch_url",
			"description": "Fetch a web page and return extracted text (truncated). Prefer official docs URLs. Public http(s) only.",
			"params": [{"name": "url", "description": "absolute http(s) URL", "required": true}],
			"example": "<action name=\"fetch_url\">\n<url>https://docs.godotengine.org/en/stable/classes/class_characterbody2d.html</url>\n</action>",
		},
		{
			"name": "get_editor_context",
			"description": "Return the current editor/project snapshot: Godot version, open scene, focused script, selection, autoloads.",
			"params": [],
			"example": "<action name=\"get_editor_context\">\n</action>",
		},
		{
			"name": "list_project_files",
			"description": "List files and folders under a project path (res://). Skips .godot and .git. Read-only.",
			"params": [
				{"name": "path", "description": "res:// path to list (default res://)", "required": false},
				{"name": "max_entries", "description": "max entries (default 400)", "required": false},
			],
			"example": "<action name=\"list_project_files\">\n<path>res://scripts</path>\n</action>",
		},
		{
			"name": "read_project_file",
			"description": "Read a text file under res:// (size-capped). Never writes. Refuse binary/media and secret-like files.",
			"params": [
				{"name": "path", "description": "res:// path to a file", "required": true},
			],
			"example": "<action name=\"read_project_file\">\n<path>res://scripts/player.gd</path>\n</action>",
		},
		{
			"name": "find_in_project",
			"description": "Search text across project scripts/scenes/config (read-only). Good for class names, TODOs, general symbols.",
			"params": [
				{"name": "query", "description": "substring to find", "required": true},
				{"name": "path", "description": "res:// subtree to search (default res://)", "required": false},
				{"name": "case_sensitive", "description": "true/false (default false)", "required": false},
			],
			"example": "<action name=\"find_in_project\">\n<query>health_changed</query>\n</action>",
		},
		{
			"name": "describe_scene",
			"description": "Parse a .tscn scene: node tree, attached scripts, instanced scenes, and signal connections. If path omitted, uses the currently edited/open scene.",
			"params": [
				{"name": "path", "description": "res:// path to .tscn (optional if a scene is open)", "required": false},
				{"name": "include_props", "description": "include selected node properties (default true)", "required": false},
			],
			"example": "<action name=\"describe_scene\">\n<path>res://scenes/player.tscn</path>\n</action>",
		},
		{
			"name": "find_signal_usage",
			"description": "Find where a signal is connected (in .tscn) and referenced in scripts (declare/emit/connect/await). Prefer this over find_in_project for signal questions.",
			"params": [
				{"name": "signal", "description": "exact signal name (case-sensitive)", "required": true},
				{"name": "path", "description": "res:// subtree (default res://)", "required": false},
			],
			"example": "<action name=\"find_signal_usage\">\n<signal>health_changed</signal>\n</action>",
		},
		{
			"name": "capture_editor_screenshot",
			"description": "Capture a screenshot of the Godot editor UI. Use for layout/scene-dock/inspector visual questions. Requires a vision-capable model to see the image; otherwise say you cannot see it. Does not modify the project.",
			"params": [
				{"name": "target", "description": "optional: editor (default)", "required": false},
			],
			"example": "<action name=\"capture_editor_screenshot\">\n</action>",
		},
	]


static func known_names() -> PackedStringArray:
	var names: PackedStringArray = []
	for s in tool_specs():
		names.append(str(s["name"]))
	return names


static func is_allowed(name: String) -> bool:
	return InjectionGuard.is_allowed_name(name, known_names())


static func render_tool_help() -> String:
	var lines: PackedStringArray = []
	lines.append("Only these tools exist. There is no skill system, no shell, and no write tools.")
	lines.append("")
	for t in tool_specs():
		lines.append("### %s" % t["name"])
		lines.append(str(t["description"]))
		if (t["params"] as Array).is_empty():
			lines.append("Parameters: (none)")
		else:
			lines.append("Parameters:")
			for p in t["params"]:
				var req := " (required)" if p.get("required", false) else ""
				lines.append("  <%s>: %s%s" % [p["name"], p["description"], req])
		lines.append("Example:")
		lines.append(str(t["example"]))
		lines.append("")
	return "\n".join(lines)


## Returns { "text": String, "image_data_url": String, "refused": bool }
static func run(name: String, args: Dictionary) -> Dictionary:
	var tool_name := InjectionGuard.normalize_tool_name(name)
	if tool_name.is_empty() or InjectionGuard.is_denied_name(tool_name):
		return {
			"text": InjectionGuard.refused_message(
				name,
				"Denied or invalid tool name. This companion cannot run write/shell/skill tools."
			),
			"image_data_url": "",
			"refused": true,
		}
	if not is_allowed(tool_name):
		return {
			"text": InjectionGuard.refused_message(
				tool_name,
				"Not on the read-only allowlist. Available: %s" % ", ".join(known_names())
			),
			"image_data_url": "",
			"refused": true,
		}

	# Drop unknown / injected parameters before any tool sees them.
	var safe_args := InjectionGuard.filter_args(tool_name, args)

	var text := ""
	var image_data_url := ""

	match tool_name:
		"web_search":
			text = await WebTools.web_search(safe_args)
		"fetch_url":
			text = await WebTools.fetch_url(safe_args)
		"get_editor_context":
			text = EditorContext.build_tool_report()
		"list_project_files":
			text = ProjectTools.list_project_files(safe_args)
		"read_project_file":
			text = ProjectTools.read_project_file(safe_args)
		"find_in_project":
			text = ProjectTools.find_in_project(safe_args)
		"describe_scene":
			text = SceneTools.describe_scene(safe_args)
		"find_signal_usage":
			text = SceneTools.find_signal_usage(safe_args)
		"capture_editor_screenshot":
			var cap: Dictionary = await ScreenshotTool.capture_editor_screenshot(safe_args)
			text = str(cap.get("text", ""))
			image_data_url = str(cap.get("image_data_url", ""))
		_:
			# Should be unreachable after is_allowed — belt and braces.
			return {
				"text": InjectionGuard.refused_message(tool_name, "Dispatcher has no handler."),
				"image_data_url": "",
				"refused": true,
			}

	if text.length() > MAX_RESULT_CHARS:
		text = text.substr(0, MAX_RESULT_CHARS) + "\n[…truncated]"

	return {
		"text": InjectionGuard.wrap_tool_result(tool_name, text),
		"image_data_url": image_data_url,
		"refused": false,
	}


static func summarize_args(name: String, args: Dictionary) -> String:
	var n := InjectionGuard.normalize_tool_name(name)
	var safe := InjectionGuard.filter_args(n, args)
	return ActionParser.action_target(n if not n.is_empty() else name, safe)
