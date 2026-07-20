# Godot AI Companion — Design Document

## 1. Vision

An **editor plugin** for Godot that gives the developer an **AI companion** inside the Godot editor. The companion helps the developer **think**, **review**, and **investigate** — not implement.

Typical use cases:

| Mode | Example prompts |
|------|-----------------|
| **Code review** | "Review this player controller for edge cases." |
| **Feedback** | "Is this scene tree structure reasonable for a inventory UI?" |
| **Investigation** | "How would you design an attribute/stat system in Godot 4?" |
| **Introspection** | "This scene emits `health_changed` — where is that signal connected or used?" |
| **Best practices** | "What's the recommended way to handle multiplayer authority in Godot 4.x?" |

The companion should feel like a senior Godot developer sitting next to you: opinionated when useful, honest when unsure, and able to look things up.

---

## 2. Non-goals (hard constraints)

These are deliberate product boundaries, not temporary limitations:

1. **No autonomous implementation**  
   The agent must **never** create, edit, delete, or apply Godot resources, scenes, scripts, or project settings on the developer's behalf.

2. **No Godot editor mutation**  
   No spawning nodes, no rearranging the scene tree, no writing files into the project via agent tools.

3. **Not a coding agent / vibe-coder**  
   Unlike tools such as Gemma Chat (build mode), Cursor agents, or Aider, this plugin does **not** own a write-loop over the codebase.

4. **Advice only**  
   The AI may **suggest** code snippets, architecture diagrams, or refactor plans in chat. The developer copies/applies changes manually.

If a future feature ever needs write access, then probably that feaure needs to be scrapped.

---

## 3. Product principles

1. **Read-only by design** — tools can inspect the project; they cannot mutate it.
2. **Provider-agnostic** — one chat UX; pluggable backends (cloud + local).
3. **Honest uncertainty** — system prompt and UX encourage "I don't know" / "I'm not sure" instead of hallucinated Godot APIs.
4. **Context is progressive** — start with plain chat; add project awareness in layers.
5. **Editor-native** — dock/panel that fits Godot's EditorPlugin patterns; no external Electron shell required for day-to-day use.

---

## 4. High-level architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Godot Editor                            │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  AI Companion Dock (EditorPlugin UI)                  │  │
│  │  - Chat transcript                                    │  │
│  │  - Composer                                           │  │
│  │  - Provider / model picker                            │  │
│  │  - Settings (API keys, endpoints)                     │  │
│  └───────────────────────────┬───────────────────────────┘  │
│                              │                              │
│  ┌───────────────────────────▼───────────────────────────┐  │
│  │  Agent Core (GDScript)                                │  │
│  │  - Conversation state                                 │  │
│  │  - System prompt assembly                             │  │
│  │  - Tool loop (read-only tools only)                   │  │
│  │  - Streaming display                                  │  │
│  └───────────┬─────────────────────────────┬─────────────┘  │
│              │                             │                │
│  ┌───────────▼───────────┐     ┌───────────▼─────────────┐  │
│  │  Context Providers    │     │  Tool Host              │  │
│  │  - Open script/scene  │     │  - web_search           │  │
│  │  - Selection          │     │  - fetch_url            │  │
│  │  - Project index      │     │  - list/read/find       │  │
│  │  - Context budget     │     │  - describe_scene       │  │
│  └───────────────────────┘     │  - find_signal_usage    │  │
│                                │  - screenshot (vision)  │  │
│                                └───────────┬─────────────┘  │
└────────────────────────────────────────────┼────────────────┘
											 │
					OpenAI-compatible HTTP (SSE streaming)
											 │
		  ┌───────────────────────┴───────────────────────┐
		  │                                               │
		  ▼                                               ▼
   OpenRouter.ai                                   Ollama (local)
   (cloud models)                                  Gemma 4 tags
   openrouter.ai/api/v1                            127.0.0.1:11434/v1
```

---

## 5. Plugin layout (Godot addon)

```
godot-ai-plugin/                     # this repository
├── DESIGN.md
├── project.godot                    # minimal dev shell (plugin enabled)
└── addons/
	└── ai_companion/
		├── plugin.cfg
		├── plugin.gd                # EditorPlugin entry (bottom panel)
		├── ui/
		│   ├── chat_dock.gd         # panel UI (built in code)
		│   └── markdown_bbcode.gd   # assistant Markdown → BBCode
		├── core/
		│   ├── agent.gd             # conversation + streaming + tool loop
		│   ├── system_prompt.gd
		│   ├── editor_context.gd    # open script/scene/selection snapshot
		│   ├── context_budget.gd    # history/tool-result shrinking
		│   ├── config.gd            # EditorSettings only (provider, keys, models)
		│   └── secrets.gd           # redact keys; detect secret filenames
		├── providers/
		│   ├── openai_compat_client.gd  # generic SSE client (OpenRouter + local)
		│   ├── ollama_lifecycle.gd      # detect / start / pull models (Ollama)
		│   └── openrouter_client.gd     # thin OpenRouter wrapper (compat)
		└── tools/
			├── action_parser.gd     # XML <action> protocol
			├── tool_host.gd         # read-only tool registry
			├── http_util.gd
			├── net_guard.gd         # SSRF block (localhost / private nets)
			├── web_tools.gd         # web_search + fetch_url
			├── project_paths.gd     # res:// sandboxing
			├── project_tools.gd     # list / read / find
			├── scene_tools.gd       # describe_scene + find_signal_usage
			└── screenshot_tool.gd   # optional editor screenshot (vision)
```

**Current status:** Streaming chat (OpenRouter + Ollama), web research, project/scene introspection, screenshots, Ollama lifecycle, **security hardening** (secrets stay out of projects). Still no write tools.

**Install path for users:** copy/symlink `addons/ai_companion` into their Godot project, enable in Project → Project Settings → Plugins.

---

## 6. LLM providers

All providers speak (or are adapted to) the **OpenAI Chat Completions** shape, ideally with **SSE streaming** (`stream: true`).

### 6.1 Shared client — **implemented**

Both cloud and local traffic go through `providers/openai_compat_client.gd`:

- OpenAI Chat Completions + SSE (`stream: true`)
- Configurable `base_url`, optional `api_key`, model, temperature
- URL parser for `http(s)://host:port/base`

### 6.2 OpenRouter.ai — **implemented**

| | |
|--|--|
| Base URL | `https://openrouter.ai/api/v1` |
| Auth | `Authorization: Bearer <OPENROUTER_API_KEY>` |
| Default model | `google/gemma-4-26b-a4b-it:free` |
| Also suggested | `google/gemma-4-31b-it:free`, paid Gemma 4 variants, `openrouter/free` |
| Extras | `HTTP-Referer` / `X-Title` headers per OpenRouter norms |

### 6.3 Local — Ollama (Gemma 4) — **implemented**

Local is **Ollama-first** (macOS + Windows; no Python/MLX venv). Same OpenAI-compatible chat client as OpenRouter.

| | |
|--|--|
| Base URL (default) | `http://127.0.0.1:11434/v1` |
| Auth | none (optional Bearer if a local proxy needs it) |
| Default model id | `gemma4:e4b` |
| Local model presets | Ollama Gemma 4 tags: `gemma4:e2b`, `e4b`, `12b`, `26b`, `31b` |
| Lifecycle helper | `providers/ollama_lifecycle.gd` — detect install, start server, list models, **pull/download** selected model with progress |
| Settings UI | Refresh / Start Ollama / Download model / Get Ollama |

**Why Ollama (not MLX-LM):** MLX needs a pinned Python + Apple Silicon; Ollama is a single install on Windows and Mac and matches typical Godot users. Legacy MLX HuggingFace model ids in EditorSettings are auto-migrated to Ollama tags.

**Flow:** install Ollama from [ollama.com/download](https://ollama.com/download) → Start Ollama (if needed) → pick Gemma 4 preset → **Download model** (`POST /api/pull`) → chat.

OpenAI-compatible `/v1/chat/completions` remains the chat path; native `/api/tags` and `/api/pull` are used only for lifecycle.

### 6.4 Config surface

Stored in **EditorSettings** (machine-local, not in the game project):

- `provider` — `openrouter` | `local`
- OpenRouter API key + model
- Local base URL + model
- temperature

Provider and model are chosen in the bottom-panel **Settings** UI.

---

## 7. Agent behavior

### 7.1 Role

System prompt frames the model as:

- A **Godot 4** specialist companion for the open project
- Focused on **review, design discussion, investigation**
- **Forbidden** from claiming it modified the project
- Required to **admit uncertainty** and prefer looking up docs over inventing APIs
- Encouraged to ask clarifying questions when the task is ambiguous

### 7.2 Tool use — **implemented (XML stream protocol)**

Smaller local models often handle **structured XML tool calls** more reliably than JSON function-calling (lesson from gemma-chat).

**Current strategy:**

- Single provider-agnostic protocol: XML `<action>` blocks parsed from the assistant stream (`tools/action_parser.gd`)
- Agent pauses emission at incomplete tags, runs the tool, injects a tool-result message, continues (max rounds)
- Optionally map to native function-calling later for providers that support it well

Example (web — shipped):

```xml
<action name="web_search">
<query>Godot 4 CharacterBody2D best practices</query>
</action>
```

Example (project — shipped):

```xml
<action name="read_project_file">
<path>res://scripts/player.gd</path>
</action>
```

### 7.3 Allowed tools (read-only)

| Tool | Status | Purpose |
|------|--------|---------|
| `web_search` | **done** | DuckDuckGo HTML search for docs / best practices |
| `fetch_url` | **done** | Fetch a URL and return plain-text extract |
| `list_project_files` | **done** | List project tree (skips `.godot` / `.git`) |
| `read_project_file` | **done** | Read a text file under `res://` (size-capped) |
| `find_in_project` | **done** | Substring search across scripts/scenes/config |
| `get_editor_context` | **done** | Current edited script, selection, open scene, autoloads |
| `capture_editor_screenshot` | **done** | Editor UI screenshot for vision-capable models |
| `describe_scene` | **done** | Parse `.tscn` for node tree, scripts, connections |
| `find_signal_usage` | **done** | Scene connections + script declare/emit/connect/await |

### 7.4 Explicitly disallowed tools

- `write_file`, `edit_file`, `delete_file`
- `run_bash` / shell with side effects
- Any EditorInterface mutation (create node, save scene, etc.)
- Network requests that are not user-visible investigative fetches

### 7.5 Uncertainty

- System prompt: if documentation is not in context and search fails, say so.
- Optional UI badge when the model self-tags low confidence (heuristic / instructed phrase).
- Prefer linking to official docs over paraphrasing obscure APIs from memory.

---

## 8. Context system (phased)

Context is **assembled into the system/user message**, not used to silently rewrite the project.

### Phase A — No project context (MVP chat) — **done**

- Manual chat only
- User pastes code if needed
- Provider + model switching works (OpenRouter + local)
- Streaming responses + Markdown→BBCode rendering

### Phase A2 — Web research — **done**

- On-demand `web_search` / `fetch_url` via XML tool loop
- Tool activity rows in the transcript

### Phase B — Lightweight editor context — **done**

Automatically attach (token-budgeted) into the system prompt each turn:

- Godot version
- Project name / main scene / features / autoloads
- Currently focused script path + selection or nearby lines
- Open scene path(s) + FileSystem selection

Also available on demand via `get_editor_context`.

### Phase B2 — Editor screenshot (optional vision) — **done**

- Tool: `capture_editor_screenshot` (downscaled JPEG, multimodal message part)
- UI: “Attach screenshot” checkbox + “Screenshot now”
- **Caveat:** only useful with a **vision-capable** model. Text-only Gemma may ignore or reject images — the model is instructed to admit when it cannot see images. Prefer project text tools for code questions.

### Phase C — On-demand project tools — **done**

Agent can call read-only tools when the question needs the codebase ("where is X used?"):

- `list_project_files`, `read_project_file`, `find_in_project`
- Paths sandboxed strictly under `res://`

### Phase D — Structured Godot awareness — **done (core)**

- `describe_scene` — text `.tscn` parse: node tree, attached scripts, instanced scenes, signal connections, key props
- `find_signal_usage` — scene `[connection]` rows + script declare/emit/connect/await references
- Context budgeting for long tool-heavy chats (`context_budget.gd`)

Still optional later: richer `.tres` resource reports, input-map dump, live edited-scene tree via EditorInterface (beyond file parse).

**Token budget:** history + tool results compressed before each request; prefer tool-on-demand over dumping the whole repo.

---

## 9. UI / UX

### 9.1 Chat dock — **implemented (bottom panel)**

- **Bottom panel** tab via `add_control_to_bottom_panel` (with Output / Debugger)
- Message list (user / assistant); assistant Markdown → BBCode
- Streaming token append
- Tool activity rows (web + project tools + screenshot)
- Stop generation + clear conversation
- Optional editor screenshot attach

### 9.2 Composer — **implemented**

- Multiline input (Enter sends, Shift+Enter newline)
- Attach screenshot checkbox / Screenshot now button
- Optional later: attach current selection as a chip

### 9.3 Settings — **implemented (core)**

- Provider: OpenRouter | Local (Ollama · Gemma 4) — **done**
- Local base URL override + presets — **done**
- API key (masked LineEdit; EditorSettings + `PROPERTY_USAGE_SECRET`) — **done**
- Per-provider model presets — **done**
- Ollama lifecycle controls — **done**
- Enable/disable web tools — planned
- Max context size / max tool rounds — planned (tool rounds hardcoded today)

### 9.4 Safety copy — **implemented**

Footer / empty-state:

> Review & investigate only. This companion never edits your project.

Settings also state that the API key never enters the game project.

---

## 10. Configuration & secrets (security)

### 10.1 Where the API key lives

| Setting | Storage | Ships with game / addon zip? |
|---------|---------|------------------------------|
| OpenRouter API key | **`EditorSettings` only** (`ai_companion/openrouter_api_key`) | **No** |
| Provider / models / temp / local URL | `EditorSettings` | **No** |
| Feature flags (future) | Prefer EditorSettings | **No** keys there |

**Hard rule:** never write API keys (or any secret) into:

- `project.godot` / `ProjectSettings`
- any file under `res://`
- exported `.pck` / game builds
- the published `addons/ai_companion` tree

Godot stores EditorSettings under the **editor user data** path (outside the project), so:

1. **Publishing this plugin** (copying `addons/ai_companion`) cannot include anyone’s key.
2. **A game developer using the plugin** stores *their* key only on *their* machine; teammates and players do not receive it via the project repo or export.
3. The settings UI uses a **secret/password** LineEdit; metadata marks the setting with `PROPERTY_HINT_PASSWORD` + `PROPERTY_USAGE_SECRET`.

### 10.2 Other threat surfaces (and mitigations)

| Risk | Mitigation | Status |
|------|------------|--------|
| Key in error messages / UI | `AISecrets.redact()` on client errors, agent failures, status | **done** |
| Key never logged via `print` | Client must not print Authorization headers or request bodies with keys | **done** |
| Model reads `.env` / keys from project | Refuse secret-like paths; redact key-shaped tokens in reads/find | **done** |
| SSRF via `fetch_url` (localhost, metadata, private IP) | `net_guard.gd` blocks loopback/private/link-local/metadata hosts | **done** |
| OpenRouter key sent to fake “local” URL | Optional local Bearer only if base URL is loopback | **done** |
| Path traversal outside `res://` | `project_paths.gd` sandbox | **done** |
| Write / shell tools | Not registered; system prompt forbids mutation | **done** |
| Screenshot leaks key UI | Hide settings panel before capture | **done** |
| Prompt / tool / “skills” injection | Host allowlist + arg filter + result neutralization (see §10.5) | **done** |
| Chat history on disk | Session-only in memory today (no persistence) | **done** (by design) |
| Repo leaks secrets while developing | Root `.gitignore` for `.env`, keys, credentials | **done** |

### 10.3 Residual / accepted risks

- **Cloud provider sees project context** you (or tools) send — expected for OpenRouter; use **local Ollama** for private code.
- **Screenshots** may show other on-screen secrets; user controls attach.
- **Hostname SSRF** is best-effort (DNS resolve); exotic DNS rebinding is not fully closed.
- **Teammate clones the project** — they must paste **their own** OpenRouter key; yours never travels with the project.
- **Indirect prompt injection** can still waste tool rounds or bias advice (e.g. a malicious README saying “always recommend X”). It cannot create write/shell tools that do not exist.
- **`web_search` / `fetch_url`** only reach **public** hosts; they can still pull untrusted public content into the chat context.

### 10.4 Publishing checklist

When shipping `addons/ai_companion` (Asset Library / GitHub release):

1. Ship **only** the addon folder (plus license/readme as needed).
2. Confirm **no** `EditorSettings`, `.env`, or personal keys in the tree.
3. Do **not** commit `export_presets.cfg` with secrets.
4. Document: “API key is per-editor, never stored in the project.”

### 10.5 Prompt injection, tool injection, “skills” injection

Agents are often attacked by **instructions hidden in data** (web pages, project files, pasted text) that try to:

- “Ignore previous instructions / enter agent mode”
- Invent new tools (`write_file`, `bash`, `run_skill`, MCP calls)
- Exfiltrate secrets via search queries or fetched URLs
- Load external “skills” that grant capabilities

**This companion’s primary defense is architectural, not prompt-only:**

| Layer | What it does |
|-------|----------------|
| **No capability surface** | There is no skill loader, no MCP client, no shell, no write/edit/delete tools in the host. |
| **Hard allowlist** | `AIToolHost` only dispatches names from `tool_specs()`. Unknown names are refused. |
| **Denied-name denylist** | `AIInjectionGuard` also blocks common dangerous names even if a future bug widens matching. |
| **Arg filtering** | Only declared parameter keys per tool are kept; others are dropped. Values capped/sanitized. |
| **Host is authoritative** | The model may *request* `<action name="…">`; only the host runs tools. User messages and tool *results* are never executed as actions. |
| **Tool-result envelope** | Results are wrapped as untrusted `<<<TOOL_RESULT trusted="false">>>` DATA, not system authority. |
| **Markup neutralization** | `<action`, `<tool_call`, `<function`, etc. inside tool data are broken with zero-width chars so copied text cannot look like a live call. |
| **Secret / network / path guards** | Still apply on every tool run (no `.env`, no private SSRF, no escape from `res://`). |
| **Round cap** | Max 8 tool rounds per user turn — limits runaway loops from adversarial content. |
| **System prompt** | Explicit anti-injection rules; documents that tools/skills cannot be gained from pages or files. |

**What injection still cannot do here (by design):**

- Create or edit project files / scenes
- Run shell or install “skills”
- Call tools outside the allowlist
- Send the OpenRouter key to non-loopback “local” URLs
- Read blocked secret-like paths

**What it might still do (accepted):**

- Make the model give bad advice or quote malicious content
- Trigger extra read-only searches/fetches (cost/latency/privacy of *public* pages)
- Bias the conversation until the user clears chat or stops generation

---

## 11. Implementation roadmap

**Progress summary:** Milestones **0–4 complete**. Milestone **5 partially done** (Ollama lifecycle + security hardening). Remaining: tool toggles, optional chat persistence, clearer error UX.

### Milestone 0 — Design — **done**

- [x] Agree on scope, non-goals, and architecture (`DESIGN.md`)

### Milestone 1 — MVP chat plugin — **done**

**Goal:** usable bottom-panel chat talking to OpenRouter and/or local Ollama (Gemma 4).

- [x] Addon skeleton (`plugin.cfg`, `plugin.gd`, bottom panel UI)
- [x] Generic OpenAI-compatible SSE client (`openai_compat_client.gd`)
- [x] OpenRouter provider (API key + model + temperature in EditorSettings)
- [x] Local provider (Ollama base URL + Gemma 4 tags + lifecycle: start/pull)
- [x] Conversation history in the panel session
- [x] Review-only system prompt + admit uncertainty
- [x] Markdown → BBCode rendering for assistant replies
- [x] Stop / clear conversation

**Success criteria met:** streamed answers from OpenRouter (e.g. free Gemma 4) and from a local OpenAI-compatible endpoint.

### Milestone 2 — Web research tools — **done**

- [x] `web_search` (DuckDuckGo HTML) + `fetch_url` (HTML → text)
- [x] XML `<action>` parser + tool host (read-only allowlist)
- [x] Agent tool loop (max rounds; stream → tool → continue)
- [x] Tool activity UI in the transcript
- [x] System prompt documents when/how to use web tools

### Milestone 3 — Project introspection (read-only) — **done**

- [x] Editor context injection (open script/selection/scene, Godot version, autoloads)
- [x] `list_project_files`, `read_project_file`, `find_in_project`
- [x] Path sandboxing strictly under `res://`
- [x] System prompt + tool activity for project tools
- [x] Optional `capture_editor_screenshot` + UI attach (vision models)

### Milestone 4 — Godot-aware investigation — **done**

- [x] `describe_scene` (`.tscn` node tree, scripts, instances, connections)
- [x] `find_signal_usage` (scene connections + script references)
- [x] Context budgeting (compress old tool results / drop old images)
- [ ] Optional conversation persistence (deferred to polish if desired)

### Milestone 5 — Polish — **in progress**

- [x] Ollama lifecycle helper (detect / start / download selected Gemma 4 model)
- [x] Security hardening (API key only in EditorSettings; redact; secret-file block; SSRF guard)
- [x] Injection defense (tool allowlist, denied names, arg filter, untrusted tool envelopes, anti-skills prompt)
- [ ] Robust error states (server down, bad key, model missing)
- [ ] Settings toggles (web tools on/off, max tool rounds)
- [ ] Optional conversation persistence
- [ ] README, screenshots, example prompts

~~Optional MLX lifecycle helper~~ — **dropped** in favor of Ollama (cross-platform).

---

## 12. Technical notes (Godot-specific)

### 12.1 HTTP & streaming — **implemented in pure GDScript**

Godot 4 `HTTPClient` + SSE parsing (`data: {...}\n\n`) in `openai_compat_client.gd`. Tool HTTP uses the same style via `http_util.gd`. No helper process required so far.

### 12.2 Threading

Network I/O should not freeze the editor. Use:

- `HTTPRequest` nodes where sufficient, or
- background `Thread` + deferred UI updates for SSE token pump

### 12.3 Sandboxing project reads

All file tools resolve paths via `ProjectSettings.globalize_path("res://...")` and reject `..` escapes outside the project root.

### 12.4 Compatibility

- Target **Godot 4.x** (4.2+ preferred for modern editor APIs)
- **Local AI:** Ollama on **macOS + Windows** (primary)
- OpenRouter cloud path is cross-platform

---

## 13. Relationship to `gemma-chat-public`

Reusable ideas (not code coupling):

| From gemma-chat | How we use it |
|-----------------|---------------|
| OpenAI-compatible local server + SSE | Local provider client (Ollama `/v1`) |
| Model registry (Gemma 4 variants) | Ollama Gemma 4 tag presets + pull UI |
| XML `<action>` tool protocol | Read-only tool calling for small models |
| Web search / fetch tools | Same investigative capability |
| System prompt discipline | Adapted for **review-only** (drop write/build tools entirely) |
| MLX Python venv lifecycle | **Not ported** — Ollama replaces it for Windows+Mac |

We intentionally **do not** port: workspace file writes, bash tool, build/canvas mode, agent write loops.

---

## 14. Risks & open questions

| Risk / question | Mitigation / decision needed |
|-----------------|------------------------------|
| GDScript SSE reliability | Mitigated for chat + tools (pure GDScript works); revisit if edge cases appear |
| Port clash MLX vs Ollama (both often 11434) | Local path is Ollama-first; configurable base URL if needed |
| Local model quality for Godot advice | web_search available; strong cloud models via OpenRouter |
| Context window overflow | History budget + tool-result compression; screenshots downscaled; still watch long chats |
| Multimodal / vision support varies by model | Screenshot optional; text tools remain primary; model told to admit if it cannot see images |
| Users expecting auto-coding | Clear UI copy + refused write tools |
| Should settings be per-project or global? | Keys/models in EditorSettings today; revisit per-project defaults later |
| Offline-only installs | Local provider path works without OpenRouter; web tools need network |

---

## 15. Success definition

The plugin is successful when a Godot developer can:

1. Open a dock in their existing project  
2. Point it at OpenRouter **or** a local Gemma/Ollama endpoint  
3. Ask for a design review or investigation  
4. Get grounded, honest answers — optionally backed by web/docs and read-only project inspection  
5. **Never** fear that the AI silently changed their game  

---

## 16. Next concrete step

**Milestone 5 — remaining polish:**

1. Clearer error UX when Ollama is down, model missing, or OpenRouter key/model fails.
2. Settings toggles (enable/disable web tools, max tool rounds).
3. Optional conversation persistence across editor sessions (if added: still no keys on disk in the project).
4. Keep the hard rule: **no writes, no editor mutation, no keys in the project.**
