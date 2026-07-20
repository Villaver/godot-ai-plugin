@tool
extends Control

const Config := preload("res://addons/ai_companion/core/config.gd")
const Agent := preload("res://addons/ai_companion/core/agent.gd")
const Markdown := preload("res://addons/ai_companion/ui/markdown_bbcode.gd")
const ScreenshotTool := preload("res://addons/ai_companion/tools/screenshot_tool.gd")
const Ollama := preload("res://addons/ai_companion/providers/ollama_lifecycle.gd")
const Secrets := preload("res://addons/ai_companion/core/secrets.gd")

## Single readability knob. Title / UI / mono / markdown headings all scale from this.
const BODY_FONT_SIZE := 28

var _agent: AICompanionAgent

# UI refs
var _messages: RichTextLabel
var _welcome: Label
var _title_label: Label
var _input: TextEdit
var _send_btn: Button
var _stop_btn: Button
var _clear_btn: Button
var _shot_btn: Button
var _status: Label
var _provider_option: OptionButton
var _api_key_edit: LineEdit
var _api_key_row: HBoxContainer
var _local_url_option: OptionButton
var _local_url_custom: LineEdit
var _local_url_row: HBoxContainer
var _local_url_custom_row: HBoxContainer
var _model_option: OptionButton
var _model_custom: LineEdit
var _temp_spin: SpinBox
var _settings_box: VBoxContainer
var _settings_hint: Label
var _toggle_settings_btn: Button
var _attach_shot_check: CheckBox
var _ollama_box: VBoxContainer
var _ollama_status: Label
var _ollama_refresh_btn: Button
var _ollama_start_btn: Button
var _ollama_pull_btn: Button
var _ollama_open_btn: Button
var _ollama_busy := false
var _installed_ollama_models: PackedStringArray = []
var _chat_theme: Theme
var _applying_fonts := false
var _ui_font_targets: Array[Control] = []

var _model_ids: PackedStringArray = []
var _local_url_ids: PackedStringArray = []

## Display log entries: { "kind": "system"|"user"|"assistant"|"error", "text": String }
var _entries: Array[Dictionary] = []
var _stream_buffer := ""
var _streaming := false
var _render_scheduled := false


func _notification(what: int) -> void:
	# Editor often reapplies its theme; re-assert chat fonts whenever that happens.
	if what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_ENTER_TREE:
		if _applying_fonts:
			return
		call_deferred("_reassert_fonts")


func _ready() -> void:
	custom_minimum_size = Vector2(320, 240)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	Config.ensure_defaults()
	_agent = Agent.new()
	_agent.token_received.connect(_on_token)
	_agent.message_started.connect(_on_message_started)
	_agent.message_completed.connect(_on_message_completed)
	_agent.failed.connect(_on_failed)
	_agent.busy_changed.connect(_on_busy_changed)
	_agent.tool_started.connect(_on_tool_started)
	_agent.tool_finished.connect(_on_tool_finished)
	_agent.assistant_segment_started.connect(_on_assistant_segment_started)

	_build_ui()
	_load_settings_into_ui()
	_entries.append({
		"kind": "system",
		"text": "Review & investigate only — this companion never edits your project.\n"
			+ "It can inspect this project (list/read/find), search the web, and optionally\n"
			+ "capture an editor screenshot (needs a vision-capable model to “see” it).",
	})
	_render_messages()
	_update_action_state()
	_status.text = "Ready · %s · %s · body %spx" % [
		Config.get_provider_label(),
		Config.get_model(),
		BODY_FONT_SIZE,
	]
	# One more deferred pass after the bottom panel finishes theming the dock.
	call_deferred("_reassert_fonts")


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	# Header
	var header := HBoxContainer.new()
	root.add_child(header)

	_ui_font_targets.clear()

	_title_label = Label.new()
	_title_label.text = "AI Companion"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)

	_toggle_settings_btn = Button.new()
	_toggle_settings_btn.text = "Settings"
	_toggle_settings_btn.tooltip_text = "Show or hide provider settings"
	_toggle_settings_btn.pressed.connect(_on_toggle_settings)
	header.add_child(_toggle_settings_btn)
	_track_ui_font(_toggle_settings_btn)

	_clear_btn = Button.new()
	_clear_btn.text = "Clear"
	_clear_btn.tooltip_text = "Clear conversation"
	_clear_btn.pressed.connect(_on_clear)
	header.add_child(_clear_btn)
	_track_ui_font(_clear_btn)

	# Settings
	_settings_box = VBoxContainer.new()
	_settings_box.add_theme_constant_override("separation", 4)
	_settings_box.visible = not Config.is_ready_to_chat()
	root.add_child(_settings_box)

	var provider_row := HBoxContainer.new()
	_settings_box.add_child(provider_row)
	var provider_label := Label.new()
	provider_label.text = "Provider"
	provider_label.custom_minimum_size = Vector2(90, 0)
	provider_row.add_child(provider_label)
	_track_ui_font(provider_label)
	_provider_option = OptionButton.new()
	_provider_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_provider_option.add_item("OpenRouter (cloud)", 0)
	_provider_option.add_item("Local (Ollama · Gemma 4)", 1)
	_provider_option.item_selected.connect(_on_provider_selected)
	provider_row.add_child(_provider_option)
	_track_ui_font(_provider_option)

	_api_key_row = HBoxContainer.new()
	_settings_box.add_child(_api_key_row)
	var key_label := Label.new()
	key_label.text = "API key"
	key_label.custom_minimum_size = Vector2(90, 0)
	_api_key_row.add_child(key_label)
	_track_ui_font(key_label)
	_api_key_edit = LineEdit.new()
	_api_key_edit.secret = true
	_api_key_edit.placeholder_text = "sk-or-... (OpenRouter; optional for local)"
	_api_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_api_key_edit.text_changed.connect(_on_api_key_changed)
	_api_key_row.add_child(_api_key_edit)
	_track_ui_font(_api_key_edit)

	_local_url_row = HBoxContainer.new()
	_settings_box.add_child(_local_url_row)
	var url_label := Label.new()
	url_label.text = "Base URL"
	url_label.custom_minimum_size = Vector2(90, 0)
	_local_url_row.add_child(url_label)
	_track_ui_font(url_label)
	_local_url_option = OptionButton.new()
	_local_url_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_populate_local_url_options()
	_local_url_option.item_selected.connect(_on_local_url_selected)
	_local_url_row.add_child(_local_url_option)
	_track_ui_font(_local_url_option)

	_local_url_custom_row = HBoxContainer.new()
	_settings_box.add_child(_local_url_custom_row)
	var url_custom_label := Label.new()
	url_custom_label.text = "Custom URL"
	url_custom_label.custom_minimum_size = Vector2(90, 0)
	_local_url_custom_row.add_child(url_custom_label)
	_track_ui_font(url_custom_label)
	_local_url_custom = LineEdit.new()
	_local_url_custom.placeholder_text = "http://127.0.0.1:PORT/v1"
	_local_url_custom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_local_url_custom.text_submitted.connect(func(_t): _apply_custom_local_url())
	_local_url_custom.focus_exited.connect(_apply_custom_local_url)
	_local_url_custom_row.add_child(_local_url_custom)
	_track_ui_font(_local_url_custom)

	var model_row := HBoxContainer.new()
	_settings_box.add_child(model_row)
	var model_label := Label.new()
	model_label.text = "Model"
	model_label.custom_minimum_size = Vector2(90, 0)
	model_row.add_child(model_label)
	_track_ui_font(model_label)
	_model_option = OptionButton.new()
	_model_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_option.item_selected.connect(_on_model_selected)
	model_row.add_child(_model_option)
	_track_ui_font(_model_option)

	var custom_row := HBoxContainer.new()
	_settings_box.add_child(custom_row)
	var custom_label := Label.new()
	custom_label.text = "Custom"
	custom_label.custom_minimum_size = Vector2(90, 0)
	custom_row.add_child(custom_label)
	_track_ui_font(custom_label)
	_model_custom = LineEdit.new()
	_model_custom.placeholder_text = "model id override"
	_model_custom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_custom.text_submitted.connect(func(_t): _apply_custom_model())
	_model_custom.focus_exited.connect(_apply_custom_model)
	custom_row.add_child(_model_custom)
	_track_ui_font(_model_custom)

	var temp_row := HBoxContainer.new()
	_settings_box.add_child(temp_row)
	var temp_label := Label.new()
	temp_label.text = "Temp"
	temp_label.custom_minimum_size = Vector2(90, 0)
	temp_row.add_child(temp_label)
	_track_ui_font(temp_label)
	_temp_spin = SpinBox.new()
	_temp_spin.min_value = 0.0
	_temp_spin.max_value = 2.0
	_temp_spin.step = 0.1
	_temp_spin.value_changed.connect(_on_temp_changed)
	temp_row.add_child(_temp_spin)
	_track_ui_font(_temp_spin)

	# Ollama lifecycle (local only)
	_ollama_box = VBoxContainer.new()
	_ollama_box.add_theme_constant_override("separation", 4)
	_settings_box.add_child(_ollama_box)

	_ollama_status = Label.new()
	_ollama_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ollama_status.text = "Ollama: checking…"
	_ollama_box.add_child(_ollama_status)
	_track_ui_font(_ollama_status)

	var ollama_actions := HBoxContainer.new()
	_ollama_box.add_child(ollama_actions)

	_ollama_refresh_btn = Button.new()
	_ollama_refresh_btn.text = "Refresh"
	_ollama_refresh_btn.tooltip_text = "Re-check Ollama status and installed models"
	_ollama_refresh_btn.pressed.connect(_on_ollama_refresh)
	ollama_actions.add_child(_ollama_refresh_btn)
	_track_ui_font(_ollama_refresh_btn)

	_ollama_start_btn = Button.new()
	_ollama_start_btn.text = "Start Ollama"
	_ollama_start_btn.tooltip_text = "Start the Ollama server if it is not running"
	_ollama_start_btn.pressed.connect(_on_ollama_start)
	ollama_actions.add_child(_ollama_start_btn)
	_track_ui_font(_ollama_start_btn)

	_ollama_pull_btn = Button.new()
	_ollama_pull_btn.text = "Download model"
	_ollama_pull_btn.tooltip_text = "ollama pull the selected Gemma 4 model (can be several GB)"
	_ollama_pull_btn.pressed.connect(_on_ollama_pull)
	ollama_actions.add_child(_ollama_pull_btn)
	_track_ui_font(_ollama_pull_btn)

	_ollama_open_btn = Button.new()
	_ollama_open_btn.text = "Get Ollama"
	_ollama_open_btn.tooltip_text = "Open ollama.com/download in your browser"
	_ollama_open_btn.pressed.connect(_on_ollama_open_download)
	ollama_actions.add_child(_ollama_open_btn)
	_track_ui_font(_ollama_open_btn)

	_settings_hint = Label.new()
	_settings_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_settings_hint.modulate = Color(1, 1, 1, 0.7)
	_settings_box.add_child(_settings_hint)
	_track_ui_font(_settings_hint)

	var sep := HSeparator.new()
	root.add_child(sep)

	# Welcome banner uses a plain Label (not RichTextLabel) so it cannot collapse to a tiny BBCode size.
	_welcome = Label.new()
	_welcome.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_welcome.text = (
		"Review & investigate only — this companion never edits your project.\n"
		+ "It can inspect this project, search the web, and optionally capture an editor screenshot."
	)
	_welcome.modulate = Color(0.85, 0.88, 0.92, 1)
	root.add_child(_welcome)

	# Messages
	var msg_panel := PanelContainer.new()
	msg_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	msg_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(msg_panel)

	_messages = RichTextLabel.new()
	_messages.bbcode_enabled = true
	_messages.fit_content = false
	_messages.scroll_following = true
	_messages.selection_enabled = true
	_messages.scroll_active = true
	_messages.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_messages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_messages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages.custom_minimum_size = Vector2(0, 160)
	# Add to tree first so editor theme is inherited, then force our chat theme.
	msg_panel.add_child(_messages)
	_apply_message_fonts(_messages)

	# Status
	_status = Label.new()
	_status.text = "Ready"
	_status.modulate = Color(1, 1, 1, 0.75)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status)

	# Composer
	_input = TextEdit.new()
	_input.custom_minimum_size = Vector2(0, 96)
	_input.placeholder_text = "Ask for a review, design advice, or how you'd approach something…"
	_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_input.gui_input.connect(_on_input_gui_input)
	root.add_child(_input)
	_track_ui_font(_input)

	var actions := HBoxContainer.new()
	root.add_child(actions)

	_attach_shot_check = CheckBox.new()
	_attach_shot_check.text = "Attach screenshot"
	_attach_shot_check.tooltip_text = (
		"Include a Godot editor screenshot with your next message. "
		+ "Useful for UI/layout questions. Requires a vision-capable model."
	)
	actions.add_child(_attach_shot_check)
	_track_ui_font(_attach_shot_check)

	_shot_btn = Button.new()
	_shot_btn.text = "Screenshot now"
	_shot_btn.tooltip_text = "Capture the editor and send it with your message immediately"
	_shot_btn.pressed.connect(_on_screenshot_send)
	actions.add_child(_shot_btn)
	_track_ui_font(_shot_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)

	_stop_btn = Button.new()
	_stop_btn.text = "Stop"
	_stop_btn.disabled = true
	_stop_btn.pressed.connect(_on_stop)
	actions.add_child(_stop_btn)
	_track_ui_font(_stop_btn)

	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_on_send)
	actions.add_child(_send_btn)
	_track_ui_font(_send_btn)

	_reassert_fonts()


func _populate_local_url_options() -> void:
	_local_url_option.clear()
	_local_url_ids.clear()
	for item in Config.LOCAL_BASE_URL_PRESETS:
		_local_url_option.add_item(str(item["label"]))
		_local_url_ids.append(str(item["id"]))
	_local_url_option.add_item("Custom…")
	_local_url_ids.append("")


func _populate_model_options() -> void:
	_model_option.clear()
	_model_ids.clear()
	var presets: Array = Config.LOCAL_MODEL_PRESETS if Config.is_local() else Config.SUGGESTED_MODELS
	for m in presets:
		_model_option.add_item(str(m["label"]))
		_model_ids.append(str(m["id"]))
	_model_option.add_item("Custom…")
	_model_ids.append("")


func _load_settings_into_ui() -> void:
	_provider_option.select(1 if Config.is_local() else 0)
	_api_key_edit.text = Config.get_api_key()
	_temp_spin.value = Config.get_temperature()
	_refresh_provider_ui()
	_select_model_in_ui(Config.get_model())
	_select_local_url_in_ui(Config.get_local_base_url())
	if Config.is_local():
		_refresh_ollama_status()


func _refresh_provider_ui() -> void:
	var local := Config.is_local()
	_api_key_row.visible = true # kept for optional local proxy auth + OpenRouter
	_local_url_row.visible = local
	_local_url_custom_row.visible = local
	if _ollama_box:
		_ollama_box.visible = local
	_populate_model_options()
	_select_model_in_ui(Config.get_model())
	if local:
		_settings_hint.text = (
			"Local via Ollama (macOS + Windows). Use Refresh / Start / Download model. "
			+ "No Python/MLX required. Optional API key only if a loopback proxy needs auth.\n"
			+ "Keys are stored only in your Godot EditorSettings (this machine) — never in the project."
		)
		_model_custom.placeholder_text = "gemma4:e4b"
		_refresh_ollama_status()
	else:
		_settings_hint.text = (
			"Get a key at openrouter.ai — free Gemma 4 models available.\n"
			+ "Your API key is stored only in Godot EditorSettings on this machine — "
			+ "never written into the game project, never exported, never shared via the addon."
		)
		_model_custom.placeholder_text = "provider/model (optional override)"


func _select_model_in_ui(model: String) -> void:
	var idx := _model_ids.find(model)
	if idx >= 0 and not _model_ids[idx].is_empty():
		_model_option.select(idx)
		_model_custom.text = ""
	else:
		_model_option.select(_model_ids.size() - 1)
		_model_custom.text = model


func _select_local_url_in_ui(url: String) -> void:
	var idx := _local_url_ids.find(url)
	if idx >= 0 and not _local_url_ids[idx].is_empty():
		_local_url_option.select(idx)
		_local_url_custom.text = ""
	else:
		_local_url_option.select(_local_url_ids.size() - 1)
		_local_url_custom.text = url


func _on_toggle_settings() -> void:
	_settings_box.visible = not _settings_box.visible


func _on_provider_selected(index: int) -> void:
	var provider := Config.PROVIDER_LOCAL if index == 1 else Config.PROVIDER_OPENROUTER
	Config.set_provider(provider)
	_refresh_provider_ui()
	_update_action_state()
	if not Config.is_ready_to_chat():
		_settings_box.visible = true
	_status.text = "Provider: %s · model %s" % [Config.get_provider_label(), Config.get_model()]


func _on_api_key_changed(value: String) -> void:
	Config.set_api_key(value)
	_update_action_state()


func _on_local_url_selected(index: int) -> void:
	if index < 0 or index >= _local_url_ids.size():
		return
	var id := _local_url_ids[index]
	if id.is_empty():
		_apply_custom_local_url()
	else:
		Config.set_local_base_url(id)
		_local_url_custom.text = ""
	_status.text = "Local URL: %s" % Config.get_local_base_url()
	_update_action_state()


func _apply_custom_local_url() -> void:
	var custom := _local_url_custom.text.strip_edges()
	if custom.is_empty():
		return
	Config.set_local_base_url(custom)
	_local_url_option.select(_local_url_ids.size() - 1)
	_status.text = "Local URL: %s" % Config.get_local_base_url()
	_update_action_state()


func _on_model_selected(index: int) -> void:
	if index < 0 or index >= _model_ids.size():
		return
	var id := _model_ids[index]
	if id.is_empty():
		_apply_custom_model()
	else:
		Config.set_model(id)
		_model_custom.text = ""
	_status.text = "Model: %s" % Config.get_model()
	_update_action_state()
	if Config.is_local():
		_refresh_ollama_status()


func _apply_custom_model() -> void:
	var custom := _model_custom.text.strip_edges()
	if custom.is_empty():
		return
	Config.set_model(custom)
	_model_option.select(_model_ids.size() - 1)
	_status.text = "Model: %s" % Config.get_model()
	_update_action_state()
	if Config.is_local():
		_refresh_ollama_status()


func _on_temp_changed(value: float) -> void:
	Config.set_temperature(value)


func _on_ollama_open_download() -> void:
	OS.shell_open(Ollama.download_page_url())


func _on_ollama_refresh() -> void:
	await _refresh_ollama_status()


func _on_ollama_start() -> void:
	if _ollama_busy:
		return
	_set_ollama_busy(true, "Starting Ollama…")
	var res: Dictionary = await Ollama.ensure_server_running(Config.get_local_base_url())
	_set_ollama_busy(false)
	if bool(res.get("ok", false)):
		_status.text = str(res.get("message", "Ollama ready."))
	else:
		_entries.append({"kind": "error", "text": str(res.get("message", "Could not start Ollama."))})
		_render_messages()
		_status.text = "Ollama start failed"
	await _refresh_ollama_status()


func _on_ollama_pull() -> void:
	if _ollama_busy:
		return
	var model := Config.get_local_model()
	_set_ollama_busy(true, "Downloading %s…" % model)
	var res: Dictionary = await Ollama.pull_model(
		model,
		Callable(self, "_on_ollama_pull_progress"),
		Config.get_local_base_url()
	)
	_set_ollama_busy(false)
	if bool(res.get("ok", false)):
		_status.text = "Model ready: %s" % model
		_entries.append({
			"kind": "system",
			"text": "Downloaded Ollama model `%s`." % model,
		})
	else:
		_entries.append({
			"kind": "error",
			"text": "Model download failed: %s" % res.get("message", "unknown"),
		})
		_status.text = "Download failed"
	_render_messages()
	await _refresh_ollama_status()


func _on_ollama_pull_progress(message: String, fraction: float) -> void:
	if _ollama_status:
		if fraction >= 0.0:
			_ollama_status.text = "Ollama: %s" % message
		else:
			_ollama_status.text = "Ollama: %s" % message
	if _status:
		_status.text = message


func _set_ollama_busy(busy: bool, status_text: String = "") -> void:
	_ollama_busy = busy
	if _ollama_refresh_btn:
		_ollama_refresh_btn.disabled = busy
	if _ollama_start_btn:
		_ollama_start_btn.disabled = busy
	if _ollama_pull_btn:
		_ollama_pull_btn.disabled = busy
	if _ollama_open_btn:
		_ollama_open_btn.disabled = busy
	if not status_text.is_empty():
		if _ollama_status:
			_ollama_status.text = "Ollama: %s" % status_text
		if _status:
			_status.text = status_text


func _refresh_ollama_status() -> void:
	if _ollama_status == null or not Config.is_local():
		return
	if _ollama_busy:
		return
	_ollama_status.text = "Ollama: checking…"
	var info: Dictionary = await Ollama.probe(Config.get_local_base_url())
	_installed_ollama_models = PackedStringArray()
	var models_var: Variant = info.get("models", PackedStringArray())
	if typeof(models_var) == TYPE_PACKED_STRING_ARRAY:
		_installed_ollama_models = models_var
	elif typeof(models_var) == TYPE_ARRAY:
		for m in models_var:
			_installed_ollama_models.append(str(m))

	var parts: PackedStringArray = []
	if bool(info.get("reachable", false)):
		parts.append("server running")
	elif not str(info.get("binary", "")).is_empty():
		parts.append("installed, server not running")
	else:
		parts.append("not found — install from ollama.com/download")

	var ver := str(info.get("version", "")).strip_edges()
	if not ver.is_empty():
		parts.append(ver)

	var model := Config.get_local_model()
	var have := await Ollama.has_model(model, Config.get_local_base_url())
	if bool(info.get("reachable", false)):
		if have:
			parts.append("model %s ready" % model)
		else:
			parts.append("model %s not downloaded — use Download model" % model)

	if not _installed_ollama_models.is_empty():
		var shown: PackedStringArray = []
		for m in _installed_ollama_models:
			shown.append(str(m))
			if shown.size() >= 6:
				break
		var extra := _installed_ollama_models.size() - shown.size()
		var list_txt := ", ".join(shown)
		if extra > 0:
			list_txt += " (+%s more)" % extra
		parts.append("local models: %s" % list_txt)

	_ollama_status.text = "Ollama: " + " · ".join(parts)
	if _ollama_start_btn:
		_ollama_start_btn.disabled = _ollama_busy or bool(info.get("reachable", false))
	if _ollama_pull_btn:
		_ollama_pull_btn.disabled = _ollama_busy
	if _ollama_open_btn:
		_ollama_open_btn.visible = not bool(info.get("installed", false)) or not bool(info.get("reachable", false))


func _on_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_ENTER and not key.shift_pressed and not key.alt_pressed \
				and not key.ctrl_pressed and not key.meta_pressed:
			accept_event()
			_on_send()


func _on_send() -> void:
	await _send_with_optional_screenshot(false)


func _on_screenshot_send() -> void:
	await _send_with_optional_screenshot(true)


func _send_with_optional_screenshot(force_shot: bool) -> void:
	if _agent.is_busy():
		return
	var text := _input.text.strip_edges()
	var want_shot := force_shot or (_attach_shot_check != null and _attach_shot_check.button_pressed)
	if text.is_empty() and not want_shot:
		return
	if not Config.is_ready_to_chat():
		_settings_box.visible = true
		if Config.is_local():
			_status.text = "Configure local base URL and model first."
		else:
			_status.text = "Add your OpenRouter API key first."
		return

	var image_data_url := ""
	if want_shot:
		_status.text = "Capturing editor screenshot…"
		# Hide settings (API key field) before capture so the key never enters model context.
		var settings_was_visible := false
		if _settings_box != null and _settings_box.visible:
			settings_was_visible = true
			_settings_box.visible = false
			await get_tree().process_frame
			await get_tree().process_frame
		var cap: Dictionary = await ScreenshotTool.capture_editor_screenshot({})
		if settings_was_visible and _settings_box != null:
			_settings_box.visible = true
		image_data_url = str(cap.get("image_data_url", ""))
		if image_data_url.is_empty():
			_entries.append({"kind": "error", "text": str(cap.get("text", "Screenshot failed."))})
			_render_messages()
			_status.text = "Screenshot failed"
			return
		if _attach_shot_check:
			_attach_shot_check.button_pressed = false

	var user_label := text
	if user_label.is_empty():
		user_label = "(editor screenshot)"
	elif want_shot:
		user_label = text + "\n[attached editor screenshot]"

	_entries.append({"kind": "user", "text": user_label})
	_render_messages()
	_input.text = ""
	_status.text = "Thinking via %s…" % Config.get_provider_label()
	await _agent.send_user_message(text, image_data_url)


func _on_stop() -> void:
	_agent.cancel()
	_status.text = "Stopping…"


func _on_clear() -> void:
	if _agent.is_busy():
		_status.text = "Stop generation before clearing."
		return
	_agent.clear_history()
	_entries.clear()
	_stream_buffer = ""
	_streaming = false
	_entries.append({"kind": "system", "text": "Conversation cleared."})
	_render_messages()
	_status.text = "Ready · %s · %s" % [Config.get_provider_label(), Config.get_model()]


func _on_message_started() -> void:
	_streaming = true
	_stream_buffer = ""
	_entries.append({"kind": "assistant", "text": ""})
	_schedule_render()


func _on_assistant_segment_started() -> void:
	# New model turn after a tool result.
	_streaming = true
	_stream_buffer = ""
	_entries.append({"kind": "assistant", "text": ""})
	_schedule_render()


func _on_token(text: String) -> void:
	_stream_buffer += text
	if not _entries.is_empty() and str(_entries[_entries.size() - 1].get("kind", "")) == "assistant":
		_entries[_entries.size() - 1]["text"] = _stream_buffer
	_schedule_render()


func _on_tool_started(tool_name: String, detail: String) -> void:
	_streaming = false
	# Drop empty assistant placeholder if the model jumped straight to a tool call.
	if not _entries.is_empty() and str(_entries[_entries.size() - 1].get("kind", "")) == "assistant":
		if str(_entries[_entries.size() - 1].get("text", "")).strip_edges().is_empty():
			_entries.pop_back()
	var label := _tool_label(tool_name, detail, true)
	_entries.append({
		"kind": "tool",
		"text": label,
		"tool": tool_name,
		"running": true,
	})
	_status.text = "Tool: %s…" % tool_name
	_schedule_render()


func _on_tool_finished(tool_name: String, result_preview: String) -> void:
	# Update the last matching running tool row.
	for i in range(_entries.size() - 1, -1, -1):
		var e: Dictionary = _entries[i]
		if str(e.get("kind", "")) == "tool" and bool(e.get("running", false)):
			var detail := ""
			# Keep the original detail from text if present after " — ".
			var prev := str(e.get("text", ""))
			var sep := prev.find(" — ")
			if sep >= 0:
				detail = prev.substr(sep + 3)
				# Strip trailing ellipsis markers from running state.
				detail = detail.trim_suffix("…")
			var summary := result_preview.strip_edges().replace("\n", " ")
			if summary.length() > 120:
				summary = summary.substr(0, 120) + "…"
			var done_text := _tool_label(tool_name, detail, false)
			if not summary.is_empty():
				done_text += "\n" + summary
			_entries[i]["text"] = done_text
			_entries[i]["running"] = false
			break
	_status.text = "Thinking via %s…" % Config.get_provider_label()
	_schedule_render()


func _tool_label(tool_name: String, detail: String, running: bool) -> String:
	var verb := tool_name
	match tool_name:
		"web_search":
			verb = "Searching" if running else "Searched"
		"fetch_url":
			verb = "Fetching" if running else "Fetched"
		"list_project_files":
			verb = "Listing" if running else "Listed"
		"read_project_file":
			verb = "Reading" if running else "Read"
		"find_in_project":
			verb = "Searching project" if running else "Searched project"
		"get_editor_context":
			verb = "Reading editor context" if running else "Editor context"
		"describe_scene":
			verb = "Describing scene" if running else "Described scene"
		"find_signal_usage":
			verb = "Tracing signal" if running else "Traced signal"
		"capture_editor_screenshot":
			verb = "Capturing screenshot" if running else "Screenshot"
		_:
			verb = ("Running " + tool_name) if running else tool_name
	if detail.strip_edges().is_empty():
		return verb + ("…" if running else "")
	return "%s — %s%s" % [verb, detail.strip_edges(), "…" if running else ""]


func _on_message_completed(_full_text: String) -> void:
	_streaming = false
	# Drop trailing empty assistant bubble if the model only ran tools / cancelled.
	if not _entries.is_empty() and str(_entries[_entries.size() - 1].get("kind", "")) == "assistant":
		if str(_entries[_entries.size() - 1].get("text", "")).strip_edges().is_empty():
			_entries.pop_back()
	_stream_buffer = ""
	_render_messages()
	_status.text = "Ready · %s · %s" % [Config.get_provider_label(), Config.get_model()]
	_update_action_state()


func _on_failed(message: String) -> void:
	_streaming = false
	# If we opened an empty assistant bubble, drop it.
	if not _entries.is_empty() and str(_entries[_entries.size() - 1].get("kind", "")) == "assistant":
		var last_text := str(_entries[_entries.size() - 1].get("text", ""))
		if last_text.is_empty():
			_entries.pop_back()
	_stream_buffer = ""
	_entries.append({"kind": "error", "text": Secrets.redact(message)})
	_render_messages()
	_status.text = "Error"
	_update_action_state()


func _on_busy_changed(_is_busy: bool) -> void:
	_update_action_state()
	if _agent != null and _agent.is_busy() and _status != null:
		# Don't clobber a more specific tool status.
		if not str(_status.text).begins_with("Tool:"):
			_status.text = "Generating via %s…" % Config.get_provider_label()


func _update_action_state() -> void:
	var busy := _agent != null and _agent.is_busy()
	_send_btn.disabled = busy or not Config.is_ready_to_chat()
	_stop_btn.disabled = not busy
	_clear_btn.disabled = busy
	_input.editable = not busy
	if _shot_btn:
		_shot_btn.disabled = busy or not Config.is_ready_to_chat()
	if _attach_shot_check:
		_attach_shot_check.disabled = busy


func _schedule_render() -> void:
	# Coalesce rapid token updates to one rebuild per frame.
	if _render_scheduled:
		return
	_render_scheduled = true
	call_deferred("_flush_render")


func _flush_render() -> void:
	_render_scheduled = false
	_render_messages()


func _render_messages() -> void:
	if _messages == null:
		return
	_reassert_fonts()

	var base := BODY_FONT_SIZE
	var parts: PackedStringArray = []
	var last_idx := _entries.size() - 1
	var has_conversation := false
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		var kind := str(entry.get("kind", ""))
		var text := str(entry.get("text", ""))
		# Initial welcome is shown in the Label above; skip duplicate system banner.
		if kind == "system" and not has_conversation and i == 0:
			continue
		if kind == "user" or kind == "assistant":
			has_conversation = true
		match kind:
			"system":
				parts.append("[color=#a0a0a0]%s[/color]" % _escape_bbcode(text))
			"user":
				parts.append("[b][color=#b8d4ff]You[/color][/b]\n%s" % _escape_bbcode(text))
			"assistant":
				var body := Markdown.to_bbcode(text, base)
				if _streaming and i == last_idx:
					if not body.ends_with("\n") and not body.is_empty():
						body += " "
					body += "[color=#888888]▌[/color]"
				parts.append("[b][color=#c5e0c8]Companion[/color][/b]\n%s" % body)
			"tool":
				var running := bool(entry.get("running", false))
				var color := "#9ecbff" if running else "#7aa2c8"
				parts.append("[color=%s]%s[/color]" % [color, _escape_bbcode(text)])
			"error":
				parts.append("[color=#ff8080][b]Error[/b] %s[/color]" % _escape_bbcode(text))
			_:
				parts.append(_escape_bbcode(text))

	_messages.clear()
	if parts.is_empty():
		_messages.append_text("[color=#666666]Conversation appears here.[/color]")
	else:
		_messages.append_text("\n\n".join(parts))


func _escape_bbcode(text: String) -> String:
	return text.replace("[", "[lb]")


func _message_base_font_size() -> int:
	return BODY_FONT_SIZE


## Title / header — slightly larger than body.
func _title_font_size() -> int:
	return _scale_font(1.18, BODY_FONT_SIZE + 3)


## Chrome UI (buttons, settings, status) — a bit smaller than body, still readable.
func _ui_font_size() -> int:
	return _scale_font(0.88, 18)


## Code / mono in the transcript.
func _mono_font_size() -> int:
	return maxi(BODY_FONT_SIZE - 1, _ui_font_size())


func _scale_font(mult: float, minimum: int) -> int:
	return maxi(int(round(float(BODY_FONT_SIZE) * mult)), minimum)


func _track_ui_font(control: Control) -> void:
	if control != null:
		_ui_font_targets.append(control)


func _reassert_fonts() -> void:
	if _applying_fonts:
		return
	_applying_fonts = true
	# Rebuild theme when body size constant changes across reloads.
	_chat_theme = _build_chat_theme()
	if _messages != null:
		_apply_message_fonts(_messages)
	if _title_label != null:
		_apply_control_font(_title_label, _title_font_size())
	if _welcome != null:
		_apply_control_font(_welcome, BODY_FONT_SIZE)
	if _status != null:
		_apply_control_font(_status, _ui_font_size())
	for c in _ui_font_targets:
		if c != null and is_instance_valid(c):
			_apply_control_font(c, _ui_font_size())
	_applying_fonts = false


func _apply_control_font(control: Control, size: int) -> void:
	if control == null:
		return
	control.add_theme_font_size_override("font_size", size)


func _apply_label_font(label: Label, size: int) -> void:
	_apply_control_font(label, size)


func _build_chat_theme() -> Theme:
	var t := Theme.new()
	var body := BODY_FONT_SIZE
	var mono := _mono_font_size()
	# Set on both the class name and empty type — editor theme lookup is picky.
	for type_name in ["RichTextLabel", ""]:
		t.set_font_size("normal_font_size", type_name, body)
		t.set_font_size("bold_font_size", type_name, body)
		t.set_font_size("italics_font_size", type_name, body)
		t.set_font_size("bold_italics_font_size", type_name, body)
		t.set_font_size("mono_font_size", type_name, mono)
		t.set_font_size("font_size", type_name, body)
	return t


func _apply_message_fonts(label: RichTextLabel) -> void:
	if label == null:
		return
	if _chat_theme == null:
		_chat_theme = _build_chat_theme()
	# Full theme replacement beats editor theme inheritance that keeps forcing ~14–16px.
	if label.theme != _chat_theme:
		label.theme = _chat_theme
	var body := BODY_FONT_SIZE
	var mono := _mono_font_size()
	label.add_theme_font_size_override("normal_font_size", body)
	label.add_theme_font_size_override("bold_font_size", body)
	label.add_theme_font_size_override("italics_font_size", body)
	label.add_theme_font_size_override("bold_italics_font_size", body)
	label.add_theme_font_size_override("mono_font_size", mono)
	label.add_theme_font_size_override("font_size", body)
