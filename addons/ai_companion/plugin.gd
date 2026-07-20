@tool
extends EditorPlugin

const ConfigScript := preload("res://addons/ai_companion/core/config.gd")
const SecretsScript := preload("res://addons/ai_companion/core/secrets.gd")
const SystemPromptScript := preload("res://addons/ai_companion/core/system_prompt.gd")
const EditorContextScript := preload("res://addons/ai_companion/core/editor_context.gd")
const OpenAICompatScript := preload("res://addons/ai_companion/providers/openai_compat_client.gd")
const OllamaLifecycleScript := preload("res://addons/ai_companion/providers/ollama_lifecycle.gd")
const ActionParserScript := preload("res://addons/ai_companion/tools/action_parser.gd")
const ProjectPathsScript := preload("res://addons/ai_companion/tools/project_paths.gd")
const ProjectToolsScript := preload("res://addons/ai_companion/tools/project_tools.gd")
const SceneToolsScript := preload("res://addons/ai_companion/tools/scene_tools.gd")
const ScreenshotScript := preload("res://addons/ai_companion/tools/screenshot_tool.gd")
const NetGuardScript := preload("res://addons/ai_companion/tools/net_guard.gd")
const InjectionGuardScript := preload("res://addons/ai_companion/tools/injection_guard.gd")
const ToolHostScript := preload("res://addons/ai_companion/tools/tool_host.gd")
const ContextBudgetScript := preload("res://addons/ai_companion/core/context_budget.gd")
const AgentScript := preload("res://addons/ai_companion/core/agent.gd")
const MarkdownScript := preload("res://addons/ai_companion/ui/markdown_bbcode.gd")
const ChatDockScript := preload("res://addons/ai_companion/ui/chat_dock.gd")

var _panel: Control
var _panel_button: Button


func _enter_tree() -> void:
	# Touch preloads so class_name types are registered before the panel builds.
	ConfigScript.ensure_defaults()
	var _keep: Array = [
		SecretsScript,
		SystemPromptScript,
		EditorContextScript,
		ActionParserScript,
		ProjectPathsScript,
		ProjectToolsScript,
		SceneToolsScript,
		ScreenshotScript,
		NetGuardScript,
		InjectionGuardScript,
		ToolHostScript,
		ContextBudgetScript,
		AgentScript,
		OpenAICompatScript,
		OllamaLifecycleScript,
		MarkdownScript,
		ChatDockScript,
	]
	_panel = ChatDockScript.new()
	_panel.name = "AI Companion"
	_panel_button = add_control_to_bottom_panel(_panel, "AI Companion")


func _exit_tree() -> void:
	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
		_panel_button = null
