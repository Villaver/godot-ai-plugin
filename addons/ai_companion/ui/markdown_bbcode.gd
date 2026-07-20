@tool
class_name AIMarkdownBBCode
extends RefCounted

## Converts a useful subset of Markdown into Godot RichTextLabel BBCode.
##
## Pass [param base_font_size] from the RichTextLabel theme so heading
## [code]font_size[/code] tags stay larger than body text under editor UI scale.


static func to_bbcode(markdown: String, base_font_size: int = 16) -> String:
	if markdown.is_empty():
		return ""

	var base := maxi(base_font_size, 12)

	# Protect fenced code blocks first so inner markdown is not rewritten.
	var fences: Array[String] = []
	var text := _extract_fenced_code(markdown, fences)

	var lines := text.split("\n", true)
	var out: PackedStringArray = []

	for i in lines.size():
		var line: String = lines[i]
		var trimmed := line.strip_edges()

		# Setext-style headings: Title\n==== or Title\n----
		if i + 1 < lines.size():
			var next_trim := str(lines[i + 1]).strip_edges()
			if not trimmed.is_empty() and _is_setext_underline(next_trim):
				var level := 1 if next_trim.begins_with("=") else 2
				_append_heading_block(out, level, trimmed, base)
				# Skip the underline line on the next iteration by blanking it.
				lines[i + 1] = ""
				continue

		# Horizontal rule
		if _is_hr(trimmed):
			out.append("[color=#666666]────────────────[/color]")
			continue

		# ATX headings (# …) — sized relative to body font, always larger.
		var heading := _match_heading(line)
		if not heading.is_empty():
			_append_heading_block(out, int(heading["level"]), str(heading["text"]), base)
			continue

		# Standalone bold line used as a section title: **Advantages**
		var bold_title := _match_bold_only_line(trimmed)
		if not bold_title.is_empty():
			_append_heading_block(out, 3, bold_title, base)
			continue

		# Blockquote
		if trimmed.begins_with(">"):
			var q := trimmed.substr(1).strip_edges()
			while q.begins_with(">"):
				q = q.substr(1).strip_edges()
			out.append("[color=#9aa0a6]│[/color] [i]%s[/i]" % _inline(q))
			continue

		# Unordered list
		var ul := _match_ul(line)
		if not ul.is_empty():
			out.append("• %s" % _inline(ul))
			continue

		# Ordered list
		var ol := _match_ol(line)
		if not ol.is_empty():
			out.append("%s. %s" % [str(ol["n"]), _inline(ol["text"])])
			continue

		# Blank line
		if trimmed.is_empty():
			out.append("")
			continue

		out.append(_inline(line))

	var joined := "\n".join(out)
	for idx in fences.size():
		joined = joined.replace("@@CODEBLOCK_%d@@" % idx, fences[idx])
	return joined


static func _extract_fenced_code(src: String, fences: Array[String]) -> String:
	var re := RegEx.new()
	# Non-greedy fenced blocks. Allow missing trailing newline before close fence.
	re.compile("(?s)```([a-zA-Z0-9_+-]*)\\r?\\n(.*?)\\r?\\n?```|~~~([a-zA-Z0-9_+-]*)\\r?\\n(.*?)\\r?\\n?~~~")
	var rebuilt := ""
	var last_end := 0
	var result := re.search(src)
	while result != null:
		rebuilt += src.substr(last_end, result.get_start() - last_end)
		var lang := result.get_string(1)
		var code := result.get_string(2)
		if lang.is_empty() and code.is_empty():
			lang = result.get_string(3)
			code = result.get_string(4)
		var block := _format_code_block(code, lang)
		var token := "@@CODEBLOCK_%d@@" % fences.size()
		fences.append(block)
		rebuilt += token
		last_end = result.get_end()
		result = re.search(src, last_end)
	rebuilt += src.substr(last_end)
	return rebuilt


static func _format_code_block(code: String, _lang: String) -> String:
	var escaped := _escape_bbcode(code)
	return "[color=#c8d0d8][code]%s[/code][/color]" % escaped


static func _inline(text: String) -> String:
	# 1) Protect inline code
	var codes: Array[String] = []
	var re_code := RegEx.new()
	re_code.compile("`([^`\\n]+)`")
	var work := text
	var rebuilt := ""
	var last := 0
	var m := re_code.search(work)
	while m != null:
		rebuilt += work.substr(last, m.get_start() - last)
		var token := "@@CODE_%d@@" % codes.size()
		codes.append("[code]%s[/code]" % _escape_bbcode(m.get_string(1)))
		rebuilt += token
		last = m.get_end()
		m = re_code.search(work, last)
	rebuilt += work.substr(last)
	work = rebuilt

	# 2) Protect links before escaping '['
	var links: Array[String] = []
	var re_link := RegEx.new()
	re_link.compile("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
	rebuilt = ""
	last = 0
	m = re_link.search(work)
	while m != null:
		rebuilt += work.substr(last, m.get_start() - last)
		var label := _escape_bbcode(m.get_string(1))
		var url := m.get_string(2)
		var token := "@@LINK_%d@@" % links.size()
		links.append("[url=%s]%s[/url]" % [url, label])
		rebuilt += token
		last = m.get_end()
		m = re_link.search(work, last)
	rebuilt += work.substr(last)
	work = rebuilt

	# 3) Escape remaining BBCode brackets
	work = _escape_bbcode(work)

	# 4) Emphasis / strike
	work = _wrap_delimited(work, "***", "[b][i]", "[/i][/b]")
	work = _wrap_delimited(work, "**", "[b]", "[/b]")
	work = _wrap_delimited(work, "__", "[b]", "[/b]")
	work = _wrap_single_asterisk_italic(work)
	work = _wrap_delimited(work, "~~", "[s]", "[/s]")

	# 5) Restore protected segments
	for idx in links.size():
		work = work.replace("@@LINK_%d@@" % idx, links[idx])
	for idx in codes.size():
		work = work.replace("@@CODE_%d@@" % idx, codes[idx])

	return work


static func _wrap_delimited(text: String, delim: String, open_tag: String, close_tag: String) -> String:
	if delim.is_empty():
		return text
	var parts := text.split(delim)
	# Need paired delimiters: even count => odd number of parts.
	if parts.size() < 3 or (parts.size() - 1) % 2 != 0:
		return text
	var out := ""
	for i in parts.size():
		if i % 2 == 0:
			out += parts[i]
		else:
			if parts[i].is_empty():
				out += delim + delim
			else:
				out += open_tag + parts[i] + close_tag
	return out


static func _wrap_single_asterisk_italic(text: String) -> String:
	var re := RegEx.new()
	re.compile("(?<!\\*)\\*(?!\\*)([^\\*\\n]+?)(?<!\\*)\\*(?!\\*)")
	var out := ""
	var last := 0
	var m := re.search(text)
	while m != null:
		out += text.substr(last, m.get_start() - last)
		out += "[i]%s[/i]" % m.get_string(1)
		last = m.get_end()
		m = re.search(text, last)
	out += text.substr(last)
	return out


static func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


static func _is_hr(trimmed: String) -> bool:
	if trimmed.length() < 3:
		return false
	var re := RegEx.new()
	re.compile("^(-{3,}|\\*{3,}|_{3,})$")
	return re.search(trimmed) != null


static func _match_heading(line: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("^(#{1,6})\\s+(.*)$")
	var m := re.search(line.strip_edges())
	if m == null:
		return {}
	return {"level": m.get_string(1).length(), "text": m.get_string(2).strip_edges()}


## Push a heading with breathing room so section topics are easy to spot.
static func _append_heading_block(
	out: PackedStringArray, level: int, body: String, base_font_size: int
) -> void:
	# Gap before heading (unless this is the first content).
	if not out.is_empty() and not str(out[out.size() - 1]).is_empty():
		out.append("")
	out.append(_format_heading(level, body, base_font_size))
	# Rule under major titles reinforces the section break.
	var lvl := clampi(level, 1, 6)
	if lvl <= 2:
		out.append("[color=#6a7a90]━━━━━━━━━━━━━━━━[/color]")
	elif lvl == 3:
		out.append("[color=#4e5a6c]────────────[/color]")
	out.append("")


## Heading size is always derived from the label body size so editor UI scale
## cannot leave titles smaller than the paragraph under them.
static func _heading_font_size(level: int, base_font_size: int) -> int:
	var base := maxi(base_font_size, 12)
	var lvl := clampi(level, 1, 6)
	# Multipliers chosen so even h6 is clearly above body text.
	var mult := 1.25
	match lvl:
		1:
			mult = 1.85
		2:
			mult = 1.65
		3:
			mult = 1.45
		4:
			mult = 1.35
		5:
			mult = 1.28
		_:
			mult = 1.25
	var sized := int(round(float(base) * mult))
	# Hard floor: at least +4px over body (h1/h2 even more).
	var min_bump := 8 if lvl <= 2 else (6 if lvl == 3 else 4)
	return maxi(sized, base + min_bump)


static func _format_heading(level: int, body: String, base_font_size: int) -> String:
	var lvl := clampi(level, 1, 6)
	var size := _heading_font_size(lvl, base_font_size)
	var color := "#e8eef7"
	match lvl:
		1:
			color = "#ffffff"
		2:
			color = "#eef3fb"
		3:
			color = "#dce6f5"
		_:
			color = "#d0dae8"
	# Strip markdown emphasis already present; we bold the whole title.
	var plain := body.strip_edges()
	plain = plain.trim_prefix("**").trim_suffix("**")
	plain = plain.trim_prefix("__").trim_suffix("__")
	var title := _escape_bbcode(plain)
	# Leading marker makes the section topic scannable even before size registers.
	var marker := "▸ " if lvl >= 3 else ""
	return "[font_size=%d][b][color=%s]%s%s[/color][/b][/font_size]" % [size, color, marker, title]


static func _match_bold_only_line(trimmed: String) -> String:
	# **Title** or __Title__ alone on a line (common model section style).
	var re := RegEx.new()
	re.compile("^(\\*\\*|__)(.+?)\\1$")
	var m := re.search(trimmed)
	if m == null:
		return ""
	var inner := m.get_string(2).strip_edges()
	# Avoid treating long bold paragraphs as titles.
	if inner.is_empty() or inner.length() > 80 or inner.find("\n") >= 0:
		return ""
	return inner


static func _is_setext_underline(trimmed: String) -> bool:
	if trimmed.length() < 3:
		return false
	var re := RegEx.new()
	re.compile("^(={3,}|-{3,})$")
	return re.search(trimmed) != null


static func _match_ul(line: String) -> String:
	var re := RegEx.new()
	re.compile("^\\s*[-*+]\\s+(.*)$")
	var m := re.search(line)
	if m == null:
		return ""
	return m.get_string(1)


static func _match_ol(line: String) -> Dictionary:
	var re := RegEx.new()
	re.compile("^\\s*(\\d+)\\.\\s+(.*)$")
	var m := re.search(line)
	if m == null:
		return {}
	return {"n": int(m.get_string(1)), "text": m.get_string(2)}
