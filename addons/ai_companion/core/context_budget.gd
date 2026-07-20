@tool
class_name AIContextBudget
extends RefCounted

## Shrink conversation payloads before sending to the model.
## Keeps recent turns intact; compresses older tool results; drops old images.

## Soft budget for history content (chars). System prompt is separate.
const DEFAULT_HISTORY_CHAR_BUDGET := 28000
## Always keep at least this many trailing history messages.
const MIN_KEEP_MESSAGES := 8
## Older tool-result bodies longer than this get truncated in-place for the request.
const TOOL_RESULT_SOFT_CAP := 2500


static func prepare_history_for_request(history: Array, char_budget: int = DEFAULT_HISTORY_CHAR_BUDGET) -> Array:
	if history.is_empty():
		return []

	# Work on a shallow-copied list with content copies we can mutate.
	var msgs: Array = []
	for m in history:
		msgs.append({
			"role": m.get("role", "user"),
			"content": _clone_content(m.get("content", "")),
		})

	# 1) Drop image parts from all but the last few messages (images are huge).
	var img_keep_tail := mini(4, msgs.size())
	for i in msgs.size() - img_keep_tail:
		msgs[i]["content"] = _strip_images(msgs[i]["content"], true)

	# 2) Compress older tool-result user messages.
	var compress_until := maxi(0, msgs.size() - MIN_KEEP_MESSAGES)
	for i in compress_until:
		var role := str(msgs[i].get("role", ""))
		var content = msgs[i].get("content", "")
		if role == "user" and _is_tool_result_content(content):
			msgs[i]["content"] = _compress_tool_result(content, TOOL_RESULT_SOFT_CAP)
		elif role == "assistant":
			msgs[i]["content"] = _compress_assistant(content, 4000)

	# 3) If still over budget, drop oldest messages (never drop the latest user msg).
	var guard := 0
	while _total_chars(msgs) > char_budget and msgs.size() > MIN_KEEP_MESSAGES and guard < 500:
		guard += 1
		# Prefer dropping old tool results first.
		var dropped := false
		for i in range(0, msgs.size() - 2):
			if _is_tool_result_content(msgs[i].get("content", "")):
				msgs.remove_at(i)
				dropped = true
				break
		if dropped:
			continue
		# Drop oldest non-final message.
		msgs.remove_at(0)

	# 4) Final emergency trim on remaining large tool blobs.
	if _total_chars(msgs) > char_budget:
		for i in msgs.size():
			if _is_tool_result_content(msgs[i].get("content", "")):
				msgs[i]["content"] = _compress_tool_result(msgs[i]["content"], 1200)

	return msgs


static func _clone_content(content) -> Variant:
	if typeof(content) == TYPE_ARRAY:
		var out: Array = []
		for part in content:
			if typeof(part) == TYPE_DICTIONARY:
				out.append((part as Dictionary).duplicate(true))
			else:
				out.append(part)
		return out
	return content


static func _strip_images(content, replace_with_note: bool) -> Variant:
	if typeof(content) != TYPE_ARRAY:
		return content
	var out: Array = []
	var removed := 0
	for part in content:
		if typeof(part) == TYPE_DICTIONARY and str(part.get("type", "")) == "image_url":
			removed += 1
			continue
		out.append(part)
	if removed > 0 and replace_with_note:
		out.append({
			"type": "text",
			"text": "[%s earlier screenshot(s) omitted from context to save tokens]" % removed,
		})
	# Flatten single text part arrays back to string for smaller payloads.
	if out.size() == 1 and typeof(out[0]) == TYPE_DICTIONARY \
			and str(out[0].get("type", "")) == "text":
		return str(out[0].get("text", ""))
	return out


static func _is_tool_result_content(content) -> bool:
	var text := _content_as_text(content)
	return text.begins_with("[Tool result —")


static func _compress_tool_result(content, max_chars: int) -> Variant:
	var text := _content_as_text(content)
	if text.length() <= max_chars:
		return _strip_images(content, true)
	var head := text.substr(0, max_chars)
	# Keep the tool name header line if present.
	var nl := head.find("\n")
	var header := head if nl < 0 else head.substr(0, nl)
	var body := text.substr(header.length()).strip_edges()
	var keep_body := maxi(200, max_chars - header.length() - 80)
	if body.length() > keep_body:
		body = body.substr(0, keep_body) + "\n[…older tool result truncated for context budget]"
	return header + "\n" + body


static func _compress_assistant(content, max_chars: int) -> Variant:
	var text := _content_as_text(content)
	# Drop raw action XML from older assistant turns if very long.
	var action_idx := text.find("<action")
	if action_idx > 0 and text.length() > max_chars:
		text = text.substr(0, action_idx).strip_edges() + "\n[…tool call omitted]"
	if text.length() > max_chars:
		text = text.substr(0, max_chars) + "\n[…older assistant message truncated]"
	return text


static func _content_as_text(content) -> String:
	if typeof(content) == TYPE_STRING:
		return content
	if typeof(content) == TYPE_ARRAY:
		var parts: PackedStringArray = []
		for part in content:
			if typeof(part) == TYPE_DICTIONARY:
				if str(part.get("type", "")) == "text":
					parts.append(str(part.get("text", "")))
				elif str(part.get("type", "")) == "image_url":
					parts.append("[image]")
			else:
				parts.append(str(part))
		return "\n".join(parts)
	return str(content)


static func _total_chars(msgs: Array) -> int:
	var total := 0
	for m in msgs:
		total += _content_as_text(m.get("content", "")).length()
	return total
