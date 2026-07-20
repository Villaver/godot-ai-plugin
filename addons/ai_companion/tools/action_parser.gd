@tool
class_name AIActionParser
extends RefCounted

## Parse gemma-chat-style XML tool actions from model output.
##
## <action name="web_search">
## <query>...</query>
## </action>


## Returns:
## - Dictionary { name, args, raw, start, end } when a complete action is found
## - String "incomplete" when an open tag exists without </action>
## - null when no action is present from `from`
static func find_next_action(text: String, from: int = 0) -> Variant:
	if from < 0:
		from = 0
	if from >= text.length():
		return null

	var open_re := RegEx.new()
	open_re.compile("(?i)<action\\s+name\\s*=\\s*[\"']?([a-zA-Z_][\\w]*)[\"']?\\s*>")
	var open_m := open_re.search(text, from)
	if open_m == null:
		return null

	# Normalize early; host still allowlists. Reject path-like junk names here.
	var name := open_m.get_string(1).strip_edges().to_lower()
	var body_start := open_m.get_end()
	var close_re := RegEx.new()
	close_re.compile("(?i)</action\\s*>")
	var close_m := close_re.search(text, body_start)
	if close_m == null:
		return "incomplete"

	var body := text.substr(body_start, close_m.get_start() - body_start)
	var end := close_m.get_end()
	return {
		"name": name,
		"args": parse_action_body(body),
		"raw": text.substr(open_m.get_start(), end - open_m.get_start()),
		"start": open_m.get_start(),
		"end": end,
	}


static func parse_action_body(body: String) -> Dictionary:
	var args := {}
	var outside := body

	# Special-case <content>…</content> using last close tag (nested-safe enough).
	var content_open := body.find("<content>")
	if content_open >= 0:
		var content_close := body.rfind("</content>")
		if content_close > content_open:
			var content := body.substr(
				content_open + "<content>".length(),
				content_close - content_open - "<content>".length()
			)
			content = content.trim_prefix("\n")
			content = _trim_trailing_ws_line(content)
			args["content"] = content
			outside = body.substr(0, content_open) + body.substr(content_close + "</content>".length())

	var tag_re := RegEx.new()
	tag_re.compile("(?s)<([a-zA-Z_][\\w-]*)>(.*?)</\\1>")
	for m in tag_re.search_all(outside):
		var key := m.get_string(1)
		if key == "content":
			continue
		var raw := m.get_string(2)
		var trimmed := raw.strip_edges()
		if trimmed == "true":
			args[key] = true
		elif trimmed == "false":
			args[key] = false
		elif trimmed.is_valid_int():
			args[key] = int(trimmed)
		else:
			var val := raw.trim_prefix("\n")
			val = _trim_trailing_ws_line(val)
			args[key] = val
	return args


## Largest index such that [from, idx) cannot be the start of a forming <action> tag.
static func emit_safe_boundary(buffer: String, from: int) -> int:
	var n := buffer.length()
	if from >= n:
		return from
	var i := n - 1
	while i >= from:
		if buffer[i] != "<":
			i -= 1
			continue
		var tail := buffer.substr(i).to_lower()
		if tail.length() < 8:
			# Incomplete prefix of "<action"?
			if "<action".begins_with(tail):
				return i
			i -= 1
			continue
		if tail.begins_with("<action"):
			var ch7 := tail[7]
			if ch7 == " " or ch7 == "\t" or ch7 == "\n" or ch7 == "\r" or ch7 == ">":
				return i
		i -= 1
	return n


static func action_target(name: String, args: Dictionary) -> String:
	match name:
		"web_search":
			return str(args.get("query", "")).strip_edges()
		"fetch_url":
			return str(args.get("url", "")).strip_edges()
		"list_project_files", "read_project_file":
			var p := str(args.get("path", "res://")).strip_edges()
			return p if not p.is_empty() else "res://"
		"find_in_project":
			var q := str(args.get("query", "")).strip_edges()
			var fp := str(args.get("path", "")).strip_edges()
			if fp.is_empty():
				return q
			return "%s in %s" % [q, fp]
		"get_editor_context":
			return "editor snapshot"
		"describe_scene":
			var sp := str(args.get("path", "")).strip_edges()
			return sp if not sp.is_empty() else "(edited/open scene)"
		"find_signal_usage":
			var sig := str(args.get("signal", args.get("name", args.get("query", "")))).strip_edges()
			return sig
		"capture_editor_screenshot":
			var t := str(args.get("target", "editor")).strip_edges()
			return t if not t.is_empty() else "editor"
		_:
			if args.has("path"):
				return str(args["path"])
			if args.has("query"):
				return str(args["query"])
			if args.has("url"):
				return str(args["url"])
			return ""

static func _trim_trailing_ws_line(s: String) -> String:
	# Trim trailing newline + spaces/tabs only (keep internal content).
	var i := s.length() - 1
	while i >= 0 and s[i] in [" ", "\t"]:
		i -= 1
	if i >= 0 and s[i] == "\n":
		return s.substr(0, i)
	return s
