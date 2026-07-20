@tool
class_name AIWebTools
extends RefCounted

## Read-only web research tools (DuckDuckGo HTML search + URL fetch).

const HttpUtil := preload("res://addons/ai_companion/tools/http_util.gd")
const NetGuard := preload("res://addons/ai_companion/tools/net_guard.gd")

const FETCH_MAX_CHARS := 8000
const SEARCH_MAX_RESULTS := 6


static func web_search(args: Dictionary) -> String:
	var query := str(args.get("query", "")).strip_edges()
	if query.is_empty():
		return "Error: missing query"

	var url := "https://html.duckduckgo.com/html/?q=%s" % query.uri_encode()
	var res: Dictionary = await HttpUtil.get_text(url, 25.0)
	if not res.get("ok", false):
		# Fallback host used by some environments.
		url = "https://duckduckgo.com/html/?q=%s" % query.uri_encode()
		res = await HttpUtil.get_text(url, 25.0)
	if not res.get("ok", false):
		return "Search failed: %s" % str(res.get("error", "unknown"))

	var results := _parse_duckduckgo_results(str(res.get("body", "")))
	if results.is_empty():
		return "No results found."

	var lines: PackedStringArray = []
	var n: int = mini(SEARCH_MAX_RESULTS, results.size())
	for i in n:
		var r: Dictionary = results[i]
		lines.append("[%s] %s\n%s\n%s" % [i + 1, r.get("title", ""), r.get("url", ""), r.get("snippet", "")])
	return "\n\n".join(lines)


static func fetch_url(args: Dictionary) -> String:
	var url := str(args.get("url", "")).strip_edges()
	if url.is_empty():
		return "Error: missing url"

	# SSRF guard: model-driven fetch must not hit localhost / private nets / metadata.
	var guard: Dictionary = NetGuard.assert_public_http_url(url)
	if not guard.get("ok", false):
		return "Error: %s" % str(guard.get("error", "blocked URL"))

	var res: Dictionary = await HttpUtil.get_text(url, 30.0, true)
	if not res.get("ok", false):
		return "Fetch failed: %s" % str(res.get("error", "unknown"))

	var body := str(res.get("body", ""))
	var ct := str(res.get("content_type", "")).to_lower()
	if ct.contains("html") or body.strip_edges().begins_with("<!") or body.find("<html") >= 0:
		body = _html_to_text(body)
	if body.length() > FETCH_MAX_CHARS:
		body = body.substr(0, FETCH_MAX_CHARS) + "\n[…truncated]"
	if body.strip_edges().is_empty():
		return "(page had no extractable text)"
	return body


static func _parse_duckduckgo_results(html: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var block_re := RegEx.new()
	# DDG HTML endpoint wraps results in result blocks.
	block_re.compile("(?s)<div class=\"result[^\"]*\"[^>]*>(.*?)<div class=\"clear\"")
	var title_re := RegEx.new()
	title_re.compile("(?s)<a[^>]+class=\"result__a\"[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>")
	var snippet_re := RegEx.new()
	snippet_re.compile("(?s)<a[^>]+class=\"result__snippet\"[^>]*>(.*?)</a>")

	for block_m in block_re.search_all(html):
		var block := block_m.get_string(1)
		var t := title_re.search(block)
		if t == null:
			continue
		var raw_url := _decode_entities(t.get_string(1))
		# Unwrap DDG redirect links.
		if raw_url.find("uddg=") >= 0:
			var uddg_re := RegEx.new()
			uddg_re.compile("uddg=([^&]+)")
			var um := uddg_re.search(raw_url)
			if um:
				raw_url = um.get_string(1).uri_decode()
		elif raw_url.begins_with("//"):
			raw_url = "https:" + raw_url

		var clean_url := raw_url.split("&")[0].strip_edges()
		var title := _strip_tags(t.get_string(2)).strip_edges()
		var snippet := ""
		var s := snippet_re.search(block)
		if s:
			snippet = _strip_tags(s.get_string(1)).strip_edges()

		if not title.is_empty() and clean_url.begins_with("http"):
			results.append({"title": title, "url": clean_url, "snippet": snippet})
		if results.size() >= 10:
			break

	# Fallback: looser result__a scrape if block parser found nothing.
	if results.is_empty():
		var loose := RegEx.new()
		loose.compile("(?s)<a[^>]+class=\"result__a\"[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>")
		for m in loose.search_all(html):
			var href := _decode_entities(m.get_string(1))
			if href.find("uddg=") >= 0:
				var uddg_re2 := RegEx.new()
				uddg_re2.compile("uddg=([^&]+)")
				var um2 := uddg_re2.search(href)
				if um2:
					href = um2.get_string(1).uri_decode()
			href = href.split("&")[0]
			var title2 := _strip_tags(m.get_string(2)).strip_edges()
			if title2.is_empty() or not href.begins_with("http"):
				continue
			results.append({"title": title2, "url": href, "snippet": ""})
			if results.size() >= SEARCH_MAX_RESULTS:
				break

	return results


static func _html_to_text(html: String) -> String:
	var s := html
	var re_script := RegEx.new()
	re_script.compile("(?is)<script\\b.*?</script>")
	s = re_script.sub(s, " ", true)
	var re_style := RegEx.new()
	re_style.compile("(?is)<style\\b.*?</style>")
	s = re_style.sub(s, " ", true)
	var re_noscript := RegEx.new()
	re_noscript.compile("(?is)<noscript\\b.*?</noscript>")
	s = re_noscript.sub(s, " ", true)
	return _strip_tags(s)


static func _strip_tags(s: String) -> String:
	var re := RegEx.new()
	re.compile("<[^>]+>")
	var out := re.sub(s, " ", true)
	out = _decode_entities(out)
	var ws := RegEx.new()
	ws.compile("\\s+")
	out = ws.sub(out, " ", true)
	return out.strip_edges()


static func _decode_entities(s: String) -> String:
	var out := s
	out = out.replace("&" + "nbsp;", " ")
	out = out.replace("&" + "amp;", "&")
	out = out.replace("&" + "quot;", "\"")
	out = out.replace("&#39;", "'")
	out = out.replace("&" + "apos;", "'")
	out = out.replace("&" + "lt;", "<")
	out = out.replace("&" + "gt;", ">")
	return out
