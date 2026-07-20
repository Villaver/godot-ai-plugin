@tool
class_name AICompanionConfig
extends RefCounted

## All settings live in EditorSettings (per-machine / per-user editor config).
## They are NEVER written to ProjectSettings, project.godot, or any file under res://.
## Publishing/exporting a game project therefore cannot ship the API key.
##
## EditorSettings path is outside the project (user:// editor_settings-*.tres).
const SETTINGS_PREFIX := "ai_companion/"
const KEY_PROVIDER := SETTINGS_PREFIX + "provider"
const KEY_API_KEY := SETTINGS_PREFIX + "openrouter_api_key"
const KEY_MODEL := SETTINGS_PREFIX + "model" # OpenRouter model (legacy key name)
const KEY_LOCAL_BASE_URL := SETTINGS_PREFIX + "local_base_url"
const KEY_LOCAL_MODEL := SETTINGS_PREFIX + "local_model"
const KEY_TEMPERATURE := SETTINGS_PREFIX + "temperature"

const PROVIDER_OPENROUTER := "openrouter"
const PROVIDER_LOCAL := "local"

const OPENROUTER_BASE_URL := "https://openrouter.ai/api/v1"
const DEFAULT_LOCAL_BASE_URL := "http://127.0.0.1:11434/v1"
const APP_TITLE := "Godot AI Companion"
const APP_REFERER := "https://github.com/godot-ai-plugin/godot-ai-plugin"

const DEFAULT_PROVIDER := PROVIDER_OPENROUTER
const DEFAULT_OPENROUTER_MODEL := "google/gemma-4-26b-a4b-it:free"
## Ollama library tag (https://ollama.com/library/gemma4).
const DEFAULT_LOCAL_MODEL := "gemma4:e4b"
const DEFAULT_TEMPERATURE := 0.4

## Backward-compatible alias.
const DEFAULT_MODEL := DEFAULT_OPENROUTER_MODEL

## Suggested OpenRouter models — free Gemma 4 variants first.
const SUGGESTED_MODELS: Array[Dictionary] = [
	{"id": "google/gemma-4-26b-a4b-it:free", "label": "Gemma 4 26B MoE (free)"},
	{"id": "google/gemma-4-31b-it:free", "label": "Gemma 4 31B (free)"},
	{"id": "google/gemma-4-26b-a4b-it", "label": "Gemma 4 26B MoE"},
	{"id": "google/gemma-4-31b-it", "label": "Gemma 4 31B"},
	{"id": "openrouter/free", "label": "OpenRouter Free Router"},
]

## Local Ollama base URLs.
const LOCAL_BASE_URL_PRESETS: Array[Dictionary] = [
	{"id": "http://127.0.0.1:11434/v1", "label": "127.0.0.1:11434 (Ollama)"},
	{"id": "http://localhost:11434/v1", "label": "localhost:11434 (Ollama)"},
]

## Local Ollama Gemma 4 models — ids are `ollama pull` / library tags.
const LOCAL_MODEL_PRESETS: Array[Dictionary] = [
	{"id": "gemma4:e2b", "label": "Gemma 4 E2B (~7 GB)"},
	{"id": "gemma4:e4b", "label": "Gemma 4 E4B (~10 GB, recommended)"},
	{"id": "gemma4:12b", "label": "Gemma 4 12B (~8 GB)"},
	{"id": "gemma4:26b", "label": "Gemma 4 26B MoE (~18 GB)"},
	{"id": "gemma4:31b", "label": "Gemma 4 31B (~20 GB)"},
]

## Legacy ids (placeholders + old MLX HF repos) → migrate to Ollama tags.
const _LEGACY_LOCAL_MODELS := {
	"gemma-4": "gemma4:e4b",
	"gemma3": "gemma4:e4b",
	"llama3.2": "gemma4:e4b",
	"gemma4": "gemma4:e4b",
	"mlx-community/gemma-4-e2b-it-4bit": "gemma4:e2b",
	"mlx-community/gemma-4-e4b-it-4bit": "gemma4:e4b",
	"mlx-community/gemma-4-26b-a4b-it-4bit": "gemma4:26b",
	"mlx-community/gemma-4-31b-it-4bit": "gemma4:31b",
}


static func _editor_settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()


static func ensure_defaults() -> void:
	var es := _editor_settings()
	if not es.has_setting(KEY_PROVIDER):
		es.set_setting(KEY_PROVIDER, DEFAULT_PROVIDER)
	if not es.has_setting(KEY_API_KEY):
		es.set_setting(KEY_API_KEY, "")
	if not es.has_setting(KEY_MODEL):
		es.set_setting(KEY_MODEL, DEFAULT_OPENROUTER_MODEL)
	if not es.has_setting(KEY_LOCAL_BASE_URL):
		es.set_setting(KEY_LOCAL_BASE_URL, DEFAULT_LOCAL_BASE_URL)
	if not es.has_setting(KEY_LOCAL_MODEL):
		es.set_setting(KEY_LOCAL_MODEL, DEFAULT_LOCAL_MODEL)
	if not es.has_setting(KEY_TEMPERATURE):
		es.set_setting(KEY_TEMPERATURE, DEFAULT_TEMPERATURE)

	es.set_initial_value(KEY_PROVIDER, DEFAULT_PROVIDER, false)
	es.set_initial_value(KEY_API_KEY, "", false)
	es.set_initial_value(KEY_MODEL, DEFAULT_OPENROUTER_MODEL, false)
	es.set_initial_value(KEY_LOCAL_BASE_URL, DEFAULT_LOCAL_BASE_URL, false)
	es.set_initial_value(KEY_LOCAL_MODEL, DEFAULT_LOCAL_MODEL, false)
	es.set_initial_value(KEY_TEMPERATURE, DEFAULT_TEMPERATURE, false)

	_register_setting_metadata(es)

	# One-shot migrate of stored local model if it's a legacy id.
	var current_local := str(es.get_setting(KEY_LOCAL_MODEL)).strip_edges()
	var migrated := _migrate_local_model(current_local)
	if migrated != current_local:
		es.set_setting(KEY_LOCAL_MODEL, migrated)


## Mark the API key as a password/secret in Editor Settings UI.
## Still stored only in EditorSettings (not the project).
static func _register_setting_metadata(es: EditorSettings) -> void:
	# Password hint + SECRET usage: hidden/masked in inspector-style UIs.
	es.add_property_info({
		"name": KEY_API_KEY,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PASSWORD,
		"hint_string": "",
		"usage": PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_SECRET,
	})
	es.add_property_info({
		"name": KEY_PROVIDER,
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
	})
	es.add_property_info({
		"name": KEY_MODEL,
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
	})
	es.add_property_info({
		"name": KEY_LOCAL_BASE_URL,
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
	})
	es.add_property_info({
		"name": KEY_LOCAL_MODEL,
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_DEFAULT,
	})
	es.add_property_info({
		"name": KEY_TEMPERATURE,
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0,2,0.1",
		"usage": PROPERTY_USAGE_DEFAULT,
	})


static func _migrate_local_model(model: String) -> String:
	if model.is_empty():
		return DEFAULT_LOCAL_MODEL
	if _LEGACY_LOCAL_MODELS.has(model):
		return str(_LEGACY_LOCAL_MODELS[model])
	if model.begins_with("mlx-community/"):
		return DEFAULT_LOCAL_MODEL
	return model


static func get_provider() -> String:
	ensure_defaults()
	var p := str(_editor_settings().get_setting(KEY_PROVIDER)).strip_edges()
	if p == PROVIDER_LOCAL:
		return PROVIDER_LOCAL
	return PROVIDER_OPENROUTER


static func set_provider(value: String) -> void:
	ensure_defaults()
	var p := value.strip_edges()
	if p != PROVIDER_LOCAL:
		p = PROVIDER_OPENROUTER
	_editor_settings().set_setting(KEY_PROVIDER, p)


static func is_local() -> bool:
	return get_provider() == PROVIDER_LOCAL


static func get_api_key() -> String:
	ensure_defaults()
	return str(_editor_settings().get_setting(KEY_API_KEY))


static func set_api_key(value: String) -> void:
	ensure_defaults()
	# Trim only; do not log or echo this value anywhere.
	_editor_settings().set_setting(KEY_API_KEY, value.strip_edges())


## True if a string accidentally looks like it contains our stored key (for guards).
static func text_contains_api_key(text: String) -> bool:
	var key := get_api_key().strip_edges()
	if key.is_empty() or key.length() < 12:
		return false
	return text.contains(key)


static func get_openrouter_model() -> String:
	ensure_defaults()
	var model := str(_editor_settings().get_setting(KEY_MODEL)).strip_edges()
	return model if not model.is_empty() else DEFAULT_OPENROUTER_MODEL


static func set_openrouter_model(value: String) -> void:
	ensure_defaults()
	_editor_settings().set_setting(KEY_MODEL, value.strip_edges())


static func get_local_base_url() -> String:
	ensure_defaults()
	var url := str(_editor_settings().get_setting(KEY_LOCAL_BASE_URL)).strip_edges()
	return url if not url.is_empty() else DEFAULT_LOCAL_BASE_URL


static func set_local_base_url(value: String) -> void:
	ensure_defaults()
	_editor_settings().set_setting(KEY_LOCAL_BASE_URL, value.strip_edges())


static func get_local_model() -> String:
	ensure_defaults()
	var model := str(_editor_settings().get_setting(KEY_LOCAL_MODEL)).strip_edges()
	var migrated := _migrate_local_model(model)
	if migrated != model:
		set_local_model(migrated)
	return migrated if not migrated.is_empty() else DEFAULT_LOCAL_MODEL


static func set_local_model(value: String) -> void:
	ensure_defaults()
	_editor_settings().set_setting(KEY_LOCAL_MODEL, _migrate_local_model(value.strip_edges()))


## Active model for the currently selected provider.
static func get_model() -> String:
	if is_local():
		return get_local_model()
	return get_openrouter_model()


static func set_model(value: String) -> void:
	if is_local():
		set_local_model(value)
	else:
		set_openrouter_model(value)


static func get_base_url() -> String:
	if is_local():
		return get_local_base_url()
	return OPENROUTER_BASE_URL


static func get_provider_label() -> String:
	return "Ollama" if is_local() else "OpenRouter"


static func get_temperature() -> float:
	ensure_defaults()
	return float(_editor_settings().get_setting(KEY_TEMPERATURE))


static func set_temperature(value: float) -> void:
	ensure_defaults()
	_editor_settings().set_setting(KEY_TEMPERATURE, clampf(value, 0.0, 2.0))


static func has_api_key() -> bool:
	return not get_api_key().strip_edges().is_empty()


## True when the selected provider has enough settings to attempt a request.
static func is_ready_to_chat() -> bool:
	if is_local():
		return not get_local_base_url().is_empty() and not get_local_model().is_empty()
	return has_api_key()


## Options dict for AIOpenAICompatClient.chat_stream.
static func build_client_options(messages: Array, temperature: float = -1.0) -> Dictionary:
	var temp := get_temperature() if temperature < 0.0 else temperature
	var opts := {
		"base_url": get_base_url(),
		"model": get_model(),
		"messages": messages,
		"temperature": temp,
		"max_tokens": 4096,
		"provider_label": get_provider_label(),
		"api_key": "",
		"extra_headers": PackedStringArray(),
	}
	if is_local():
		# Optional Bearer only for true loopback local servers — never send the
		# OpenRouter key to a random "local" base URL on the public internet.
		var key := get_api_key().strip_edges()
		if not key.is_empty() and _local_base_is_loopback():
			opts["api_key"] = key
	else:
		opts["api_key"] = get_api_key().strip_edges()
		opts["extra_headers"] = PackedStringArray([
			"HTTP-Referer: %s" % APP_REFERER,
			"X-Title: %s" % APP_TITLE,
		])
	return opts


static func _local_base_is_loopback() -> bool:
	var url := get_local_base_url().strip_edges().to_lower()
	# Accept only localhost / 127.0.0.1 / ::1 for attaching a bearer token.
	if url.begins_with("http://127.0.0.1") or url.begins_with("https://127.0.0.1"):
		return true
	if url.begins_with("http://localhost") or url.begins_with("https://localhost"):
		return true
	if url.begins_with("http://[::1]") or url.begins_with("https://[::1]"):
		return true
	return false
