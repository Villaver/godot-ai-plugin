@tool
class_name AIOpenAICompatClient
extends RefCounted

## Generic OpenAI-compatible chat completions client with SSE streaming.
## Works with OpenRouter, Ollama, and other /v1 endpoints.

const Secrets := preload("res://addons/ai_companion/core/secrets.gd")

signal token_received(text: String)
signal completed()
signal failed(message: String)

var _http := HTTPClient.new()
var _cancelled := false
var _busy := false
var _sse_remainder := ""
var _provider_label := "LLM"


func is_busy() -> bool:
	return _busy


func cancel() -> void:
	_cancelled = true


## options:
##   base_url: String  e.g. "https://openrouter.ai/api/v1" or "http://127.0.0.1:11434/v1"
##   model: String
##   messages: Array
##   api_key: String (optional for local)
##   temperature: float
##   max_tokens: int
##   extra_headers: PackedStringArray (optional)
##   provider_label: String (for error messages)
func chat_stream(options: Dictionary) -> void:
	if _busy:
		failed.emit("A request is already in progress.")
		return

	_busy = true
	_cancelled = false
	_sse_remainder = ""
	_provider_label = str(options.get("provider_label", "LLM"))

	var err := await _run_stream(options)
	_busy = false
	_http.close()

	if _cancelled:
		completed.emit()
		return

	if err != OK:
		return

	completed.emit()


func _run_stream(options: Dictionary) -> Error:
	var base_url := str(options.get("base_url", "")).strip_edges()
	var model := str(options.get("model", "")).strip_edges()
	var messages: Array = options.get("messages", [])
	var api_key := str(options.get("api_key", "")).strip_edges()
	var temperature := float(options.get("temperature", 0.4))
	var max_tokens := int(options.get("max_tokens", 4096))
	var extra_headers: PackedStringArray = options.get("extra_headers", PackedStringArray())

	if base_url.is_empty():
		failed.emit("%s: base URL is empty." % _provider_label)
		return ERR_INVALID_PARAMETER
	if model.is_empty():
		failed.emit("%s: model id is empty." % _provider_label)
		return ERR_INVALID_PARAMETER

	var parsed := parse_base_url(base_url)
	if parsed.is_empty():
		failed.emit("%s: could not parse base URL '%s'." % [_provider_label, base_url])
		return ERR_INVALID_PARAMETER

	var host: String = parsed["host"]
	var port: int = parsed["port"]
	var use_tls: bool = parsed["tls"]
	var api_path: String = str(parsed["base_path"]).rstrip("/") + "/chat/completions"
	if not api_path.begins_with("/"):
		api_path = "/" + api_path

	var tls: TLSOptions = TLSOptions.client() if use_tls else null
	var err := _http.connect_to_host(host, port, tls)
	if err != OK:
		failed.emit("%s: could not start connection to %s:%s (%s)." % [
			_provider_label, host, str(port), error_string(err)
		])
		return err

	while _http.get_status() == HTTPClient.STATUS_CONNECTING \
			or _http.get_status() == HTTPClient.STATUS_RESOLVING:
		if _cancelled:
			return ERR_SKIP
		_http.poll()
		await Engine.get_main_loop().process_frame

	if _http.get_status() != HTTPClient.STATUS_CONNECTED:
		failed.emit("%s: failed to connect to %s:%s (status %s). Is the server running?" % [
			_provider_label, host, str(port), _http.get_status()
		])
		return ERR_CANT_CONNECT

	var body := {
		"model": model,
		"messages": messages,
		"stream": true,
		"temperature": temperature,
		"max_tokens": max_tokens,
	}
	var body_text := JSON.stringify(body)

	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: text/event-stream",
	])
	if not api_key.is_empty():
		headers.append("Authorization: Bearer %s" % api_key)
	for h in extra_headers:
		headers.append(h)

	err = _http.request(HTTPClient.METHOD_POST, api_path, headers, body_text)
	if err != OK:
		failed.emit("%s: failed to send request (%s)." % [_provider_label, error_string(err)])
		return err

	while _http.get_status() == HTTPClient.STATUS_REQUESTING:
		if _cancelled:
			return ERR_SKIP
		_http.poll()
		await Engine.get_main_loop().process_frame

	var status := _http.get_status()
	if status != HTTPClient.STATUS_BODY and status != HTTPClient.STATUS_CONNECTED:
		failed.emit("%s: unexpected HTTP status after request: %s" % [_provider_label, status])
		return ERR_CONNECTION_ERROR

	var code := _http.get_response_code()
	var raw := ""

	while _http.get_status() == HTTPClient.STATUS_BODY:
		if _cancelled:
			return ERR_SKIP
		_http.poll()
		var chunk := _http.read_response_body_chunk()
		if chunk.size() == 0:
			await Engine.get_main_loop().process_frame
			continue
		raw += chunk.get_string_from_utf8()

		if code >= 200 and code < 300:
			var consume_err := _consume_sse_buffer(raw)
			raw = _sse_remainder
			if consume_err == ERR_FILE_EOF:
				return OK
			if consume_err != OK:
				return consume_err

	if code < 200 or code >= 300:
		failed.emit(_format_http_error(code, raw))
		return ERR_CONNECTION_ERROR

	if not raw.strip_edges().is_empty():
		var end_err := _consume_sse_buffer(raw)
		if end_err == ERR_FILE_EOF:
			return OK
		if end_err != OK:
			return end_err

	return OK


## Parse "http(s)://host:port/base/path" into connection parts.
static func parse_base_url(url: String) -> Dictionary:
	var u := url.strip_edges()
	if u.is_empty():
		return {}

	var tls := false
	if u.begins_with("https://"):
		tls = true
		u = u.substr(8)
	elif u.begins_with("http://"):
		tls = false
		u = u.substr(7)
	else:
		# bare host — assume http for local convenience
		tls = false

	var path := ""
	var slash := u.find("/")
	var hostport := u
	if slash >= 0:
		hostport = u.substr(0, slash)
		path = u.substr(slash)
	if path.is_empty():
		path = "/v1"

	var host := hostport
	var port := 443 if tls else 80
	var colon := hostport.rfind(":")
	# IPv6 in brackets not supported for simplicity; local is 127.0.0.1
	if colon > 0:
		host = hostport.substr(0, colon)
		var port_str := hostport.substr(colon + 1)
		if port_str.is_valid_int():
			port = int(port_str)
		else:
			return {}

	if host.is_empty():
		return {}

	return {
		"host": host,
		"port": port,
		"tls": tls,
		"base_path": path,
	}


func _consume_sse_buffer(buffer: String) -> Error:
	var buf := buffer
	_sse_remainder = ""

	while true:
		var sep := buf.find("\n\n")
		var sep_len := 2
		if sep < 0:
			sep = buf.find("\r\n\r\n")
			sep_len = 4
		if sep < 0:
			_sse_remainder = buf
			return OK

		var event := buf.substr(0, sep)
		buf = buf.substr(sep + sep_len)
		var parse_err := _handle_sse_event(event)
		if parse_err == ERR_FILE_EOF:
			_sse_remainder = ""
			return ERR_FILE_EOF
		if parse_err != OK:
			_sse_remainder = ""
			return parse_err

	return OK


func _handle_sse_event(event: String) -> Error:
	var data_lines: PackedStringArray = []
	for line in event.split("\n"):
		var cleaned := line.strip_edges()
		if cleaned.is_empty() or cleaned.begins_with(":"):
			continue
		if cleaned.begins_with("data:"):
			data_lines.append(cleaned.substr(5).strip_edges())

	if data_lines.is_empty():
		return OK

	var data := "\n".join(data_lines)
	if data == "[DONE]":
		return ERR_FILE_EOF

	var parsed: Variant = JSON.parse_string(data)
	if typeof(parsed) != TYPE_DICTIONARY:
		return OK

	var dict: Dictionary = parsed

	if dict.has("error"):
		failed.emit(Secrets.redact("%s error: %s" % [_provider_label, _error_message(dict["error"])]))
		return ERR_CONNECTION_ERROR

	var choices: Variant = dict.get("choices", [])
	if typeof(choices) != TYPE_ARRAY or (choices as Array).is_empty():
		return OK

	var choice: Variant = (choices as Array)[0]
	if typeof(choice) != TYPE_DICTIONARY:
		return OK

	var choice_dict: Dictionary = choice
	if choice_dict.has("error"):
		failed.emit("%s error: %s" % [_provider_label, _error_message(choice_dict["error"])])
		return ERR_CONNECTION_ERROR

	var delta: Variant = choice_dict.get("delta", {})
	if typeof(delta) == TYPE_DICTIONARY:
		var content: Variant = (delta as Dictionary).get("content", null)
		if content != null and str(content) != "":
			token_received.emit(str(content))

	# Some local servers put full message instead of delta on rare non-stream chunks.
	var message: Variant = choice_dict.get("message", {})
	if typeof(message) == TYPE_DICTIONARY:
		var msg_content: Variant = (message as Dictionary).get("content", null)
		if msg_content != null and str(msg_content) != "" and typeof(delta) != TYPE_DICTIONARY:
			token_received.emit(str(msg_content))

	return OK


func _format_http_error(code: int, raw: String) -> String:
	var parsed: Variant = JSON.parse_string(raw.strip_edges())
	if typeof(parsed) == TYPE_DICTIONARY:
		var dict: Dictionary = parsed
		if dict.has("error"):
			return Secrets.redact(
				"%s HTTP %s: %s" % [_provider_label, code, _error_message(dict["error"])]
			)
		if dict.has("message"):
			return Secrets.redact(
				"%s HTTP %s: %s" % [_provider_label, code, str(dict["message"])]
			)
	var snippet := raw.strip_edges().replace("\n", " ")
	if snippet.length() > 300:
		snippet = snippet.substr(0, 300) + "…"
	if snippet.is_empty():
		snippet = "(empty body)"
	return Secrets.redact("%s HTTP %s: %s" % [_provider_label, code, snippet])


func _error_message(err_val: Variant) -> String:
	if typeof(err_val) == TYPE_DICTIONARY:
		return Secrets.redact(str((err_val as Dictionary).get("message", err_val)))
	return Secrets.redact(str(err_val))
