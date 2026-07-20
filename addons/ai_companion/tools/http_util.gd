@tool
class_name AIHttpUtil
extends RefCounted

## Minimal HTTP GET via HTTPClient for editor tool use.

const NetGuard := preload("res://addons/ai_companion/tools/net_guard.gd")

const DEFAULT_UA := (
	"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
	+ "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)

const MAX_REDIRECTS := 5


## Returns { "ok": bool, "code": int, "body": String, "content_type": String, "error": String }
## If enforce_public is true, blocks localhost / private / metadata targets (and on redirects).
static func get_text(url: String, timeout_sec: float = 30.0, enforce_public: bool = false) -> Dictionary:
	return await _get_text_inner(url, timeout_sec, enforce_public, 0)


static func _get_text_inner(
	url: String, timeout_sec: float, enforce_public: bool, redirect_count: int
) -> Dictionary:
	if enforce_public:
		var guard: Dictionary = NetGuard.assert_public_http_url(url)
		if not guard.get("ok", false):
			return _err(str(guard.get("error", "blocked URL")))

	var parsed := _parse_url(url)
	if parsed.is_empty():
		return _err("Invalid URL")

	var http := HTTPClient.new()
	var tls: TLSOptions = TLSOptions.client() if parsed["tls"] else null
	var err := http.connect_to_host(parsed["host"], parsed["port"], tls)
	if err != OK:
		return _err("Connect failed: %s" % error_string(err))

	var start_ms := Time.get_ticks_msec()
	while http.get_status() == HTTPClient.STATUS_CONNECTING \
			or http.get_status() == HTTPClient.STATUS_RESOLVING:
		if _timed_out(start_ms, timeout_sec):
			http.close()
			return _err("Connect timed out")
		http.poll()
		await _await_frame()

	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		var st := http.get_status()
		http.close()
		return _err("Could not connect (status %s)" % st)

	var headers := PackedStringArray([
		"User-Agent: %s" % DEFAULT_UA,
		"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
		"Accept-Language: en-US,en;q=0.9",
	])
	err = http.request(HTTPClient.METHOD_GET, parsed["path"], headers)
	if err != OK:
		http.close()
		return _err("Request failed: %s" % error_string(err))

	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if _timed_out(start_ms, timeout_sec):
			http.close()
			return _err("Request timed out")
		http.poll()
		await _await_frame()

	var status := http.get_status()
	if status != HTTPClient.STATUS_BODY and status != HTTPClient.STATUS_CONNECTED:
		http.close()
		return _err("Unexpected status after request: %s" % status)

	var code := http.get_response_code()
	var content_type := ""
	for h in http.get_response_headers():
		if str(h).to_lower().begins_with("content-type:"):
			content_type = str(h).substr(str(h).find(":") + 1).strip_edges()

	# Follow redirects manually so each hop can be re-checked by NetGuard.
	if code in [301, 302, 303, 307, 308]:
		var location := ""
		for h in http.get_response_headers():
			if str(h).to_lower().begins_with("location:"):
				location = str(h).substr(str(h).find(":") + 1).strip_edges()
				break
		http.close()
		if location.is_empty():
			return _err("Redirect without Location (HTTP %s)" % code)
		if redirect_count >= MAX_REDIRECTS:
			return _err("Too many redirects")
		if location.begins_with("/"):
			var scheme := "https" if parsed["tls"] else "http"
			location = "%s://%s:%s%s" % [scheme, parsed["host"], parsed["port"], location]
		elif not location.begins_with("http"):
			return _err("Unsupported redirect target")
		return await _get_text_inner(location, timeout_sec, enforce_public, redirect_count + 1)

	var body := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		if _timed_out(start_ms, timeout_sec):
			http.close()
			return _err("Body read timed out")
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() == 0:
			await _await_frame()
			continue
		body.append_array(chunk)
		# Hard cap ~2MB to avoid runaway pages.
		if body.size() > 2_000_000:
			break

	http.close()
	var text := body.get_string_from_utf8()
	if code < 200 or code >= 300:
		return {
			"ok": false,
			"code": code,
			"body": text,
			"content_type": content_type,
			"error": "HTTP %s" % code,
		}
	return {
		"ok": true,
		"code": code,
		"body": text,
		"content_type": content_type,
		"error": "",
	}


static func _await_frame() -> void:
	var tree := _scene_tree()
	if tree != null:
		await tree.process_frame
	else:
		OS.delay_msec(16)


static func _scene_tree() -> SceneTree:
	var ml := Engine.get_main_loop()
	if ml is SceneTree:
		return ml as SceneTree
	if Engine.is_editor_hint():
		var base := EditorInterface.get_base_control()
		if base != null:
			return base.get_tree()
	return null


static func _timed_out(start_ms: int, timeout_sec: float) -> bool:
	return (Time.get_ticks_msec() - start_ms) > int(timeout_sec * 1000.0)


static func _err(msg: String) -> Dictionary:
	return {"ok": false, "code": 0, "body": "", "content_type": "", "error": msg}


static func _parse_url(url: String) -> Dictionary:
	var u := url.strip_edges()
	var tls := false
	if u.begins_with("https://"):
		tls = true
		u = u.substr(8)
	elif u.begins_with("http://"):
		tls = false
		u = u.substr(7)
	else:
		return {}

	var path := "/"
	var slash := u.find("/")
	var hostport := u
	if slash >= 0:
		hostport = u.substr(0, slash)
		path = u.substr(slash)
	if path.is_empty():
		path = "/"

	var host := hostport
	var port := 443 if tls else 80
	var colon := hostport.rfind(":")
	if colon > 0:
		host = hostport.substr(0, colon)
		var ps := hostport.substr(colon + 1)
		if ps.is_valid_int():
			port = int(ps)
		else:
			return {}
	if host.is_empty():
		return {}
	return {"host": host, "port": port, "tls": tls, "path": path}
