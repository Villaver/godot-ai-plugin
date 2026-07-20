@tool
class_name AIOpenRouterClient
extends RefCounted

## Thin OpenRouter-oriented wrapper around the generic OpenAI-compatible client.
## Kept so older references keep working; new code should use AIOpenAICompatClient.

const Compat := preload("res://addons/ai_companion/providers/openai_compat_client.gd")
const Config := preload("res://addons/ai_companion/core/config.gd")

signal token_received(text: String)
signal completed()
signal failed(message: String)

var _inner = Compat.new()


func _init() -> void:
	_inner.token_received.connect(func(t: String): token_received.emit(t))
	_inner.completed.connect(func(): completed.emit())
	_inner.failed.connect(func(m: String): failed.emit(m))


func is_busy() -> bool:
	return _inner.is_busy()


func cancel() -> void:
	_inner.cancel()


func chat_stream(
	api_key: String,
	model: String,
	messages: Array,
	temperature: float = 0.4,
	max_tokens: int = 4096
) -> void:
	await _inner.chat_stream({
		"base_url": Config.OPENROUTER_BASE_URL,
		"api_key": api_key,
		"model": model,
		"messages": messages,
		"temperature": temperature,
		"max_tokens": max_tokens,
		"provider_label": "OpenRouter",
		"extra_headers": PackedStringArray([
			"HTTP-Referer: %s" % Config.APP_REFERER,
			"X-Title: %s" % Config.APP_TITLE,
		]),
	})
