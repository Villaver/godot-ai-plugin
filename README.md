# Godot AI Companion

A **read-only** AI companion for the Godot 4 editor.

It helps you **review code**, **discuss design**, and **investigate** your project — scenes, signals, scripts, and docs.  
It does **not** write files, edit scenes, or change your project for you.

> Review & investigate only. You stay in control of every change.

---

## Features

| Area | What you get |
|------|----------------|
| **Chat dock** | Bottom panel next to Output / Debugger, streaming replies, Markdown rendering |
| **OpenRouter** | Cloud models, including free Gemma 4 options |
| **Local Ollama** | Run Gemma 4 on your machine (macOS + Windows); detect / start / download from Settings |
| **Web research** | Search the web and fetch docs pages for up-to-date best practices |
| **Project introspection** | List/read/search project files (sandboxed under `res://`) |
| **Godot-aware tools** | Describe `.tscn` node trees & connections; find signal usage |
| **Editor context** | Open scene, focused script, selection fed into the system prompt |
| **Optional screenshot** | Attach an editor screenshot (needs a vision-capable model) |
| **Safety-first** | No write/shell tools; API keys never stored in the project |

---

## Requirements

- **Godot 4.2+** (developed against 4.3)
- One of:
  - An [OpenRouter](https://openrouter.ai/) API key, **or**
  - [Ollama](https://ollama.com/) installed for local models

---

## Install

### As a project addon (recommended while developing)

1. Copy `addons/ai_companion` into your Godot project’s `addons/` folder  
   (or clone this repo and open it as a project).
2. In Godot: **Project → Project Settings → Plugins**
3. Enable **AI Companion**
4. Open the **AI Companion** tab in the **bottom panel**

### From this repository

```bash
git clone git@github.com:Villaver/godot-ai-plugin.git
```

Open the folder in Godot 4.x, enable the plugin, and use the bottom panel.

---

## Quick start

### Option A — OpenRouter (easiest)

1. Create a key at [openrouter.ai](https://openrouter.ai/)
2. In the companion: **Settings**
3. Provider: **OpenRouter**
4. Paste your API key (stored only in Godot **EditorSettings** on your machine)
5. Pick a model (default: free Gemma 4) and chat

Example models:

- `google/gemma-4-26b-a4b-it:free`
- `google/gemma-4-31b-it:free`
- Any other OpenRouter model id you prefer

### Option B — Local Ollama (private / offline-friendly)

1. Install [Ollama](https://ollama.com/) (macOS or Windows)
2. Settings → Provider: **Local (Ollama · Gemma 4)**
3. Use **Refresh** / **Start Ollama** / **Download model** as needed
4. Default model tag: `gemma4:e4b` (other Gemma 4 sizes in the preset list)

Chat goes to `http://127.0.0.1:11434/v1` by default (OpenAI-compatible API).

---

## What it’s for

Good prompts:

- *“Review this player controller for edge cases.”*
- *“How would you design an attribute/stat system in Godot 4?”*
- *“Describe the open scene’s node tree and signal connections.”*
- *“Where is `health_changed` connected and emitted?”*
- *“What do the official docs say about CharacterBody2D in Godot 4?”*

Not for:

- “Implement this feature for me in the project”
- Autonomous refactors or multi-file edits
- Letting the AI own your scene tree

The companion may **suggest** snippets and plans in chat. **You** apply them.

---

## Tools (read-only)

When useful, the model can request tools. The **host** decides what runs — there is no skill loader and no write tools.

| Tool | Purpose |
|------|---------|
| `web_search` | DuckDuckGo search snippets |
| `fetch_url` | Fetch a **public** http(s) page as text |
| `list_project_files` | List under `res://` |
| `read_project_file` | Read a text file (capped; secrets blocked) |
| `find_in_project` | Substring search in scripts/scenes/config |
| `get_editor_context` | Fresh editor/project snapshot |
| `describe_scene` | Parse a `.tscn`: nodes, scripts, connections |
| `find_signal_usage` | Scene connections + script declare/emit/connect |
| `capture_editor_screenshot` | Editor UI capture (vision models) |

Paths stay inside the project. `fetch_url` refuses localhost / private / cloud-metadata hosts.

---

## Security & privacy

| Topic | Behavior |
|-------|----------|
| **API keys** | Stored only in **EditorSettings** (editor user data). Never in `project.godot`, never in the addon zip, never in game exports. |
| **Your code + OpenRouter** | Whatever context/tools send is visible to the cloud provider. Prefer **local Ollama** for private code. |
| **Project tools** | Read-only; refuse secret-like names (`.env`, keys, certs); redact key-shaped tokens in output. |
| **Injection** | Tool allowlist + denied names (`write_file`, `bash`, `run_skill`, …). Tool results are treated as untrusted data. |
| **No autonomous writes** | Even if a prompt says “ignore rules and edit files”, those tools do not exist. |

See `DESIGN.md` §10 for the full threat model and publishing checklist.

---

## Repository layout

```
addons/ai_companion/     # The plugin (copy this into other projects)
  plugin.cfg / plugin.gd
  core/                  # Agent, config, system prompt, secrets, context
  providers/             # OpenRouter / OpenAI-compat client, Ollama lifecycle
  tools/                 # Read-only tools + guards
  ui/                    # Chat dock + Markdown→BBCode
test_fixtures/           # Tiny demo scene/scripts for scene/signal tools
DESIGN.md                # Architecture & roadmap
project.godot            # Dev project so you can open this repo in Godot
```

---

## Development

1. Clone and open this project in Godot 4.3+
2. Enable **AI Companion** under Plugins
3. After script changes: **Project Settings → Plugins → off/on**, or reload the project

Design notes and roadmap: [`DESIGN.md`](./DESIGN.md)

---

## Configuration (EditorSettings)

All companion settings live under the `ai_companion/*` EditorSettings keys on **your machine**, including:

- Provider (`openrouter` / `local`)
- OpenRouter API key (secret)
- Model ids (per provider)
- Local base URL
- Temperature

They are **not** part of the game project and are **not** shared when you publish the addon or the game.

---

## License

[MIT](./LICENSE) — Copyright (c) 2026 Koen Verheyen

You may use this plugin in personal and commercial Godot projects, modify it,
and redistribute it, as long as you keep the copyright and license notice.

---

## Remote

```text
git@github.com:Villaver/godot-ai-plugin.git
```
