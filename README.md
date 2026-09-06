# glassbot 🤖

The **local AI companion of GlassyOS** — a private, local-first assistant that
lives on your desktop.

> 🔒 **Made exclusively for GlassyOS.** glassbot is a closed part of the
> GlassyOS ecosystem: the Quickshell widget is wired into the GlassyOS
> desktop, the entry point is bound to a GlassyOS keybind, and the whole
> assistant is designed around the distribution's look and workflow.
> 🗓️ GlassyOS itself releases next year.

glassbot is **local-first**: it runs through **ollama** on your own machine —
no account, no cloud, no data leaving your computer. When you want more power,
it can optionally fall back to a **cloud model** (OpenRouter or Groq, both
with free tiers) for individual replies.

## What it is

Three pieces talk to each other:

```
┌─────────────────────┐     JSON-lines IPC      ┌──────────────────────┐
│  Quickshell widget  │  ◄────────────────────► │  glassbot-backend    │
│  (Glassbot.qml)     │  boot/chat/search/...   │  (Python, v0.6.0)    │
└─────────────────────┘  delta/search_results/  └──────────┬───────────┘
                                                           │
                       ┌───────────────────────────────────┼───────────────┐
                       │                                   │               │
                  ┌────▼────┐                       ┌──────▼─────┐   ┌─────▼────┐
                  │  ollama │  (local models)       │  OpenRouter│   │  Groq    │
                  │ :11434  │                       │  / Groq    │   │ (free)   │
                  └─────────┘                       └────────────┘   └──────────┘
```

1. **`glassbot`** — the entry point (Bash). With no arguments on a Hyprland
   session it toggles the Quickshell chat widget (keybind `SUPER+CTRL+A`).
   With arguments it becomes a one-shot CLI chat that streams the reply to
   stdout; `--tui` drops into a small terminal chat.
2. **`glassbot-backend`** — the engine (Python, 1800+ lines, zero external
   dependencies, stdlib only). Chat logic, model routing, web search, chat
   history, tool handling. Talks to the widget over a JSON-lines IPC protocol
   and to ollama/cloud over HTTP.
3. **`quickshell/Glassbot.qml`** — the desktop widget (1950+ lines): a chat UI
   with sidebar, streaming replies, and a full onboarding flow (pick a local
   model or a cloud provider, validate the key) — all rendered with the
   GlassyOS look (Matugen colors).

## Features

- **Local-first chat** — ollama models (`llama3.2:3b` default, suggested:
  `qwen2.5:1.5b` / `llama3.2:3b` / `qwen2.5:3b` / `llama3.1:8b`), tuned for
  an 8–16 GB machine
- **Cloud fallback** — `backend: auto` picks cloud when a local model is
  missing; providers: OpenRouter (many free models) + Groq (fast). Each
  provider has a **fallback model chain** that kicks in on 429/upstream
  errors. Model auto-migration when the recommended free model rotates.
- **Automatic web search** — the runtime detects time-sensitive questions
  (news, weather, prices, „heute“, „latest“, 2025/2026, …) and fetches real
  results *before* answering; sources are cited as [1], [2], …
  Forced with `/search <q>`, suppressed with `/nosearch <q>`.
  Multi-source: DuckDuckGo HTML → DDG instant answer → Wikipedia.
- **File context** — `/read /path/to/file` attaches a real file to the next
  message (content shown to the model in fenced blocks). Bounded to a strict
  size cap so a single file can't blow the context.
- **Chat history** — every chat is a JSON file under
  `~/.cache/glassbot/chats/`, auto-titled by the model (3–5 words, in the
  user's language), listable/renameable/deletable, plus legacy-history
  migration
- **Safety guardrails** — the system prompt refuses destructive shell flags
  (`-rf /`, `--no-preserve-root`), API keys and passwords in suggested
  commands; secrets only ever come from env vars or the local config
- **Tool suggestions** — the model can emit parsed tool calls for safe,
  reviewable shell commands
- **First-run onboarding** — the widget walks you through model download
  (live pull progress) or cloud provider + key validation before unlocking
  the chat

## Requirements

- Linux + Python 3
- [ollama](https://ollama.com) for local models (optional but recommended)
- Quickshell + Hyprland for the desktop widget (CLI/TUI modes work without it)

## Install

```bash
bash setup        # or: ./setup  (-y non-interactive)
```

The installer:
1. checks Python + (optionally) ollama
2. copies `glassbot` + `glassbot-backend` → `~/.local/bin/`
3. copies the Quickshell widget → `~/.config/hypr/scripts/quickshell/glassbot/`
   (when a Hyprland setup is detected)
4. creates `~/.config/glassbot/config.json` from the example if missing
5. deletes itself

### Config

`~/.config/glassbot/config.json` (example: `config.example.json`):

| Key | Default | Meaning |
|---|---|---|
| `model` | `llama3.2:3b` | local ollama model |
| `ollama_url` | `http://localhost:11434` | ollama endpoint |
| `backend` | `auto` | `auto` / `local` / `cloud` |
| `cloud_provider` | `openrouter` | `openrouter` or `groq` |
| `cloud_model` | `openai/gpt-oss-120b:free` | provider model |
| `cloud_api_key` | *(empty)* | **never commit this!** |
| `search_results` | `5` | how many web snippets to fetch |
| `tools_enabled` | `true` | allow tool suggestions |

The API key is resolved as: **environment variable**
(`OPENROUTER_API_KEY` / `GROQ_API_KEY`) → `config.json` → a standalone
keyfile in `~/.config/glassbot/`. Prefer the env var — the config file
should stay key-free so it can be shared.

## Usage

```bash
glassbot                            # toggle the Quickshell chat widget
glassbot "hello!"                   # one-shot chat, streams reply to stdout
glassbot /search "glassyos news"    # one-shot web-augmented reply
glassbot --tui                      # minimal terminal chat
glassbot --reset                    # clear conversation history
glassbot --status                   # backend / ollama status
glassbot-backend --version
```

Widget chat commands: `/search <q>`, `/nosearch <q>`, `/read <path>`,
`/new` (new chat).

## Architecture notes

- **Zero external Python dependencies** — the backend is pure stdlib
  (`urllib`, `json`, `socket`-free HTTP helpers). Nothing to `pip install`.
- **One JSON object per line** in both directions over stdin/stdout IPC
  (`--ipc`): the widget sends `boot`, `chat`, `search`, `new_chat`,
  `open_chat`, `delete_chat`, `rename_chat`, `list_chats`, `ping`; the
  backend answers with `boot_state`, `delta` (streaming tokens),
  `search_results`, `end`, `chats_refresh`, `chat_loaded`, `status`,
  `error`.
- **Streaming everywhere** — token deltas stream to the UI; local ollama
  streaming and OpenAI-compatible cloud streaming share one code path with a
  common fallback chain.

## License

MIT © GlassyOS — part of the [glasstools](https://github.com/eliii-te/glasstools)
ecosystem. **Made exclusively for GlassyOS.**
