@tool
class_name AISecrets
extends RefCounted

## Helpers for keeping API keys and other secrets out of logs, UI, and project files.


## Redact API keys / bearer tokens that might appear in error bodies or status text.
static func redact(text: String) -> String:
	if text.is_empty():
		return text
	var out := text
	# OpenRouter / OpenAI-style keys
	out = _re_replace(out, "sk-or-v1-[A-Za-z0-9_-]{8,}", "sk-or-v1-***REDACTED***")
	out = _re_replace(out, "sk-[A-Za-z0-9]{16,}", "sk-***REDACTED***")
	# Authorization headers
	out = _re_replace(out, "(?i)(Authorization\\s*:\\s*Bearer\\s+)\\S+", "$1***REDACTED***")
	out = _re_replace(out, "(?i)(Bearer\\s+)[A-Za-z0-9._\\-]{12,}", "$1***REDACTED***")
	# Generic api_key=… / "api_key":"…"
	out = _re_replace(out, "(?i)(api[_-]?key\\s*[=:]\\s*[\"']?)[^\\s\"'&,}]+", "$1***REDACTED***")
	return out


static func looks_like_secret_filename(path: String) -> bool:
	var base := path.get_file().to_lower()
	var full := path.replace("\\", "/").to_lower()

	# Exact / prefix names
	var exact := [
		".env", ".env.local", ".env.production", ".env.development",
		".envrc", "credentials", "credentials.json", "secrets.json",
		"service-account.json", "google-services.json", "googleservice-info.plist",
		"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
		"auth.json", "token.json", "secrets.tres", "secrets.cfg",
	]
	if base in exact:
		return true
	if base.begins_with(".env."):
		return true

	# Extensions commonly used for private keys / cert material we should not feed to LLMs
	var ext := base.get_extension()
	if ext in ["pem", "p12", "pfx", "key", "keystore", "jks", "kdbx"]:
		return true

	# Path segments / substrings
	var needles := [
		"/secrets/", "/.ssh/", "/.aws/", "/.gnupg/",
		"secret", "credential", "private_key", "privatekey",
		"api_key", "apikey", "access_token", "auth_token",
	]
	for n in needles:
		if full.contains(n):
			# Avoid over-blocking innocuous names like "secret_door.gd"
			if n in ["secret", "credential"] and (full.ends_with(".gd") or full.ends_with(".tscn") or full.ends_with(".cs")):
				continue
			return true

	return false


static func _re_replace(text: String, pattern: String, replacement: String) -> String:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return text
	return re.sub(text, replacement, true)
