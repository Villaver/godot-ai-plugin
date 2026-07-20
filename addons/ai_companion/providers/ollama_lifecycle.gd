@tool
class_name AIOllamaLifecycle
extends RefCounted

## Ollama local lifecycle: detect install, probe server, list models, pull (download).
## Prefer Ollama over MLX-LM — cross-platform (macOS + Windows), no Python venv.

const Config := preload("res://addons/ai_companion/core/config.gd")
const HttpUtil := preload("res://addons/ai_companion/tools/http_util.gd")

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 11434
const OLLAMA_DOWNLOAD_URL := "https://ollama.com/download"

## Suggested Gemma 4 tags (https://ollama.com/library/gemma4).
const GEMMA4_PRESETS: Array[Dictionary] = [
	{"id": "gemma4:e2b", "label": "Gemma 4 E2B (~7 GB)"},
	{"id": "gemma4:e4b", "label": "Gemma 4 E4B (~10 GB, recommended)"},
	{"id": "gemma4:12b", "label": "Gemma 4 12B (~8 GB)"},
	{"id": "gemma4:26b", "label": "Gemma 4 26B MoE (~18 GB)"},
	{"id": "gemma4:31b", "label": "Gemma 4 31B (~20 GB)"},
]


static func download_page_url() -> String:
	return OLLAMA_DOWNLOAD_URL


## Resolve host/port from configured OpenAI-compatible base URL.
static func host_port_from_base_url(base_url: String = "") -> Dictionary:
	var url := base_url.strip_edges()
	if url.is_empty():
		url = Config.get_local_base_url()
	var u := url
	if not u.begins_with("http://") and not u.begins_with("https://"):
		u = "http://" + u
	var stripped := u.trim_prefix("https://").trim_prefix("http://")
	var slash := stripped.find("/")
	var hostport := stripped if slash < 0 else stripped.substr(0, slash)
	var host := hostport
	var port := DEFAULT_PORT
	var colon := hostport.rfind(":")
	if colon > 0:
		host = hostport.substr(0, colon)
		port = int(hostport.substr(colon + 1))
	if host.is_empty():
		host = DEFAULT_HOST
	if port <= 0:
		port = DEFAULT_PORT
	var use_tls := u.begins_with("https://")
	return {"host": host, "port": port, "use_tls": use_tls}


static func _tags_url(base_url: String = "") -> String:
	var hp := host_port_from_base_url(base_url)
	var scheme := "https" if bool(hp["use_tls"]) else "http"
	return "%s://%s:%s/api/tags" % [scheme, hp["host"], hp["port"]]


static func find_ollama_binary() -> String:
	var candidates: PackedStringArray = []
	var path_env := OS.get_environment("PATH")
	var sep := ";" if OS.get_name() == "Windows" else ":"
	var exe := "ollama.exe" if OS.get_name() == "Windows" else "ollama"
	for part in path_env.split(sep):
		if part.is_empty():
			continue
		candidates.append(part.path_join(exe))
	if OS.get_name() == "Windows":
		var local := OS.get_environment("LOCALAPPDATA")
		if not local.is_empty():
			candidates.append(local.path_join("Programs/Ollama/ollama.exe"))
		candidates.append("C:/Program Files/Ollama/ollama.exe")
	else:
		candidates.append_array(PackedStringArray([
			"/usr/local/bin/ollama",
			"/opt/homebrew/bin/ollama",
			"/Applications/Ollama.app/Contents/Resources/ollama",
			OS.get_environment("HOME").path_join(".local/bin/ollama"),
		]))
	for c in candidates:
		if c.is_empty():
			continue
		if FileAccess.file_exists(c):
			return c
	return exe if _can_run_version(exe) else ""


static func _can_run_version(bin: String) -> bool:
	var out: Array = []
	var code := OS.execute(bin, ["--version"], out, true, false)
	return code == 0


static func get_version(bin: String = "") -> String:
	var path := bin if not bin.is_empty() else find_ollama_binary()
	if path.is_empty():
		return ""
	var out: Array = []
	var code := OS.execute(path, ["--version"], out, true, false)
	if code != 0:
		return ""
	return "\n".join(PackedStringArray(out)).strip_edges()


static func is_server_reachable(base_url: String = "") -> bool:
	var res: Dictionary = await HttpUtil.get_text(_tags_url(base_url), 8.0)
	return bool(res.get("ok", false)) and int(res.get("code", 0)) == 200


static func list_local_models(base_url: String = "") -> Dictionary:
	## Returns { ok, models: PackedStringArray, error, raw }
	var hp := host_port_from_base_url(base_url)
	var res: Dictionary = await HttpUtil.get_text(_tags_url(base_url), 12.0)
	if not bool(res.get("ok", false)) or int(res.get("code", 0)) != 200:
		return {
			"ok": false,
			"models": PackedStringArray(),
			"error": "Ollama not reachable at %s:%s — is it running? (%s)" % [
				hp["host"], hp["port"], res.get("error", res.get("code", "?"))
			],
			"raw": str(res.get("body", "")),
		}
	var body := str(res.get("body", ""))
	var parsed: Variant = JSON.parse_string(body)
	var names: PackedStringArray = []
	if typeof(parsed) == TYPE_DICTIONARY:
		var arr: Variant = parsed.get("models", [])
		if typeof(arr) == TYPE_ARRAY:
			for m in arr:
				if typeof(m) == TYPE_DICTIONARY:
					var n := str(m.get("name", m.get("model", ""))).strip_edges()
					if not n.is_empty():
						names.append(n)
	return {"ok": true, "models": names, "error": "", "raw": body}


static func has_model(model: String, base_url: String = "") -> bool:
	var listed: Dictionary = await list_local_models(base_url)
	if not bool(listed.get("ok", false)):
		return false
	var want := model.strip_edges()
	for n in listed.get("models", PackedStringArray()):
		if _model_ids_match(want, str(n)):
			return true
	return false


static func _model_ids_match(want: String, have: String) -> bool:
	if want == have:
		return true
	if want.find(":") < 0 and (have == want or have.begins_with(want + ":")):
		return true
	# Ollama library aliases: gemma4 / gemma4:latest currently point at e4b.
	var aliases := {
		"gemma4:e4b": ["gemma4:latest", "gemma4"],
		"gemma4:latest": ["gemma4:e4b", "gemma4"],
		"gemma4": ["gemma4:latest", "gemma4:e4b"],
	}
	if aliases.has(want):
		for a in aliases[want]:
			if have == str(a):
				return true
	return false


## Start Ollama daemon if CLI exists and server is down. Best-effort.
static func ensure_server_running(base_url: String = "") -> Dictionary:
	if await is_server_reachable(base_url):
		return {"ok": true, "started": false, "message": "Ollama is already running."}

	var bin := find_ollama_binary()
	if bin.is_empty():
		return {
			"ok": false,
			"started": false,
			"message": (
				"Ollama is not installed (or not on PATH).\n"
				+ "Install from %s then reopen Godot." % OLLAMA_DOWNLOAD_URL
			),
		}

	var pid := OS.create_process(bin, ["serve"], false)
	if pid <= 0:
		if OS.get_name() == "macOS" and FileAccess.file_exists("/Applications/Ollama.app"):
			OS.create_process("/usr/bin/open", ["-a", "Ollama"], false)
		elif OS.get_name() == "Windows":
			var local := OS.get_environment("LOCALAPPDATA")
			var app := local.path_join("Programs/Ollama/Ollama.exe")
			if FileAccess.file_exists(app):
				OS.create_process(app, [], false)

	for _i in 20:
		await Engine.get_main_loop().create_timer(1.0).timeout
		if await is_server_reachable(base_url):
			return {"ok": true, "started": true, "message": "Ollama server started."}

	return {
		"ok": false,
		"started": false,
		"message": (
			"Started Ollama but it did not become ready in time.\n"
			+ "Try launching the Ollama app manually, then press Refresh."
		),
	}


## Pull/download a model. on_progress(message, fraction 0..1 or -1).
static func pull_model(model: String, on_progress: Callable = Callable(), base_url: String = "") -> Dictionary:
	var name := model.strip_edges()
	if name.is_empty():
		return {"ok": false, "message": "Model name is empty."}

	var ens: Dictionary = await ensure_server_running(base_url)
	if not bool(ens.get("ok", false)):
		return {"ok": false, "message": str(ens.get("message", "Ollama not available."))}

	var hp := host_port_from_base_url(base_url)
	var payload := JSON.stringify({"name": name, "stream": true})

	if on_progress.is_valid():
		on_progress.call("Starting download of %s…" % name, 0.0)

	return await _pull_stream(
		str(hp["host"]),
		int(hp["port"]),
		bool(hp["use_tls"]),
		payload,
		on_progress
	)


static func _pull_stream(
	host: String,
	port: int,
	use_tls: bool,
	json_body: String,
	on_progress: Callable
) -> Dictionary:
	var http := HTTPClient.new()
	var err := http.connect_to_host(host, port, TLSOptions.client() if use_tls else null)
	if err != OK:
		return {"ok": false, "message": "Could not connect to Ollama at %s:%s (%s)" % [host, port, err]}

	var deadline := Time.get_ticks_msec() + 15000
	while http.get_status() == HTTPClient.STATUS_CONNECTING \
			or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
		if Time.get_ticks_msec() > deadline:
			return {"ok": false, "message": "Timed out connecting to Ollama."}
		await Engine.get_main_loop().process_frame

	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false, "message": "Ollama connection failed (status %s)." % http.get_status()}

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: application/x-ndjson, application/json",
	])
	err = http.request(HTTPClient.METHOD_POST, "/api/pull", headers, json_body)
	if err != OK:
		return {"ok": false, "message": "Failed to start model pull request (%s)." % err}

	deadline = Time.get_ticks_msec() + 30000
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		if Time.get_ticks_msec() > deadline:
			return {"ok": false, "message": "Timed out waiting for pull response."}
		await Engine.get_main_loop().process_frame

	if http.get_status() != HTTPClient.STATUS_BODY \
			and http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"ok": false, "message": "Unexpected HTTP status after pull request: %s" % http.get_status()}

	var code := http.get_response_code()
	var buf := ""
	var last_status := ""
	var last_error := ""
	var saw_success := false

	var idle_deadline := Time.get_ticks_msec() + 120000
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			idle_deadline = Time.get_ticks_msec() + 120000
			buf += chunk.get_string_from_utf8()
			while true:
				var nl := buf.find("\n")
				if nl < 0:
					break
				var line := buf.substr(0, nl).strip_edges()
				buf = buf.substr(nl + 1)
				if line.is_empty():
					continue
				var ev: Variant = JSON.parse_string(line)
				if typeof(ev) != TYPE_DICTIONARY:
					continue
				var d: Dictionary = ev
				if d.has("error"):
					last_error = str(d.get("error", "unknown error"))
				var st := str(d.get("status", ""))
				if st == "success":
					saw_success = true
				var frac := -1.0
				if d.has("total") and d.has("completed"):
					var total := float(d.get("total", 0))
					var done := float(d.get("completed", 0))
					if total > 0.0:
						frac = clampf(done / total, 0.0, 1.0)
				if on_progress.is_valid() and (st != last_status or frac >= 0.0):
					last_status = st
					var msg := st if not st.is_empty() else "Downloading…"
					if frac >= 0.0:
						msg = "%s (%.0f%%)" % [st if not st.is_empty() else "downloading", frac * 100.0]
					on_progress.call(msg, frac)
		else:
			if Time.get_ticks_msec() > idle_deadline:
				return {
					"ok": false,
					"message": "Pull stalled (no data for 120s). Check network / disk space.",
				}
			await Engine.get_main_loop().process_frame

	if not buf.strip_edges().is_empty():
		var ev2: Variant = JSON.parse_string(buf.strip_edges())
		if typeof(ev2) == TYPE_DICTIONARY:
			if ev2.has("error"):
				last_error = str(ev2.get("error"))
			if str(ev2.get("status", "")) == "success":
				saw_success = true

	if code != 200 and code != 0:
		return {
			"ok": false,
			"message": "Pull failed (HTTP %s)%s" % [
				code,
				(": " + last_error) if not last_error.is_empty() else "",
			],
		}
	if not last_error.is_empty() and not saw_success:
		return {"ok": false, "message": "Pull failed: %s" % last_error}
	if on_progress.is_valid():
		on_progress.call("Download complete.", 1.0)
	return {"ok": true, "message": "Model ready."}


static func probe(base_url: String = "") -> Dictionary:
	var bin := find_ollama_binary()
	var version := get_version(bin) if not bin.is_empty() else ""
	var reachable := await is_server_reachable(base_url)
	var models: PackedStringArray = []
	var list_err := ""
	if reachable:
		var listed: Dictionary = await list_local_models(base_url)
		if bool(listed.get("ok", false)):
			models = listed.get("models", PackedStringArray())
		else:
			list_err = str(listed.get("error", ""))
	return {
		"binary": bin,
		"version": version,
		"installed": not bin.is_empty() or reachable,
		"reachable": reachable,
		"models": models,
		"list_error": list_err,
		"download_url": OLLAMA_DOWNLOAD_URL,
	}
