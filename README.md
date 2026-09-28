# glassbot 🤖

**The local-first AI companion of GlassyOS — a private assistant that lives on your desktop.**

glassbot is the assistant that ships inside **GlassyOS**, an Arch-Linux–based
distribution built on **Hyprland**. Press `SUPER+CTRL+A` and a glass-morphism chat
panel slides in, rendered with your distribution's own theme colours. Ask it
anything; the reply streams in token by token. By default **nothing leaves your
machine** — the whole thing runs on a local [ollama](https://ollama.com) model. If
you want more horsepower (or you just don't have the RAM), you can plug in a free
**cloud provider** and glassbot will use that instead — transparently, with a
fallback chain so a rate-limited model never breaks your chat.

> 🔒 **Made exclusively for GlassyOS.** glassbot is a closed part of the GlassyOS
> ecosystem: the Quickshell widget is wired into the GlassyOS desktop, the entry
> point is bound to a GlassyOS keybind, and the assistant's personality, knowledge
> and system prompt are built around the distribution's look and workflow.
> 🗓️ GlassyOS itself releases next year.

It's deliberately small and dependency-free: **three files** — a Bash launcher, a
single-file Python backend (pure standard library, no `pip install`), and one
Quickshell QML widget. No accounts. No telemetry. No daemons to configure.

---

## Table of contents

- [Why glassbot?](#why-glassbot)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [How it works (architecture)](#how-it-works-architecture)
- [Usage](#usage)
- [Examples](#examples)
- [Troubleshooting & gotchas](#troubleshooting--gotchas)
- [Security notes](#security-notes)
- [Status & roadmap](#status--roadmap)
- [Credits & license](#credits--license)

---

## Why glassbot?

Every big assistant wants your data, an account and a monthly fee. glassbot takes
the opposite approach — the same philosophy the rest of GlassyOS is built on:

- **Local-first, always.** The default path is an ollama model running on *your*
  hardware. Your chats never leave the machine, and they're stored as plain JSON
  you can read, edit, back up or delete.
- **Zero dependencies.** The backend is **one Python file using only the standard
  library**. No virtualenv, no `requirements.txt`, no compiled binary. If Python 3
  is installed, it runs.
- **It fits the desktop.** The interface is a native Quickshell widget that uses
  your live Wallust/Matugen theme colours, so it looks like a first-class part of
  GlassyOS rather than a browser tab.
- **Graceful with the cloud.** If you *do* want a bigger brain, drop in a free
  OpenRouter or Groq key and glassbot prefers the cloud — but keeps working
  offline and never gives you a dead end when a free model gets rate-limited.
- **Useful, not just chatty.** It can search the web before it answers, read files
  you attach with `/read`, and propose shell commands for you to approve (never
  auto-running them).

---

## Features

- 🧠 **Local-first chat** — runs through [ollama](https://ollama.com) on your own
  machine. Default model `llama3.2:3b`; curated suggestions for 8–16 GB boxes:
  `qwen2.5:1.5b` (~1.0 GB), `llama3.2:3b` (~2.0 GB), `qwen2.5:3b` (~1.9 GB) and
  `llama3.1:8b` (~4.7 GB, needs ≥16 GB).
- ☁️ **Optional cloud fallback** — `backend: auto` routes to the cloud when an API
  key is configured, to a local model otherwise. Two OpenAI-compatible providers:
  **OpenRouter** (many free models) and **Groq** (very fast).
- 🔁 **Fallback model chains** — each cloud provider keeps an ordered list of
  models. If your chosen model returns **429** or a **5xx** upstream error *before
  emitting a token*, glassbot transparently retries with the next model in the
  chain and tells the UI it switched. Auth errors (401/403) abort immediately.
- 🔄 **Stale-default auto-migration** — when the recommended free model rotates
  out, old default values in your `config.json` are swapped forward automatically
  so you don't have to edit the file by hand.
- 🕸️ **Automatic web search** — the runtime detects time-sensitive questions
  (news, weather, prices, "heute", "aktuell", "latest", years 2025/2026, live
  events, …) and fetches real results **before** answering. Sources are numbered
  `[1]`, `[2]`, … and rendered as cards in the UI. Force it with `/search <q>`,
  suppress it with `/nosearch <q>` (alias `/nolookup`).
- 🌐 **Multi-source search** — DuckDuckGo HTML → DuckDuckGo Instant Answers →
  Wikipedia, de-duplicated and combined into one result set.
- 📎 **File context** — `/read /path/to/file` attaches a real file to the next
  message. Contents are wrapped in fenced `--- file: … ---` blocks so the model
  sees the actual text. Bounded to **64 KB / 800 lines** per file so one file can't
  blow up the context window. Multiple `/read` clauses stack in a single message.
- 💬 **Multi-chat history** — every conversation is a JSON file under
  `~/.cache/glassbot/chats/`, auto-titled by the model (3–5 words, in the user's
  language). List, open, rename and delete them from the sidebar; pre-0.2
  `history.json` files are migrated automatically on first run.
- 🛠️ **Tool suggestions with approval** — the model can propose shell commands by
  emitting `<<RUN: …>>` markers. Each becomes an **Allow / Deny** card in the
  widget; nothing runs without your click. Output is fed back into the
  conversation for a follow-up answer.
- 🛡️ **Safety guardrails** — the system prompt forbids destructive flags
  (`-rf /`, `--no-preserve-root`), API keys and passwords in suggested commands,
  and the backend independently blocklists destructive patterns before execution.
- 🎨 **Glassmorphism UI** — Quickshell widget with a collapsible chat sidebar,
  streaming replies, search-result cards, source citations, animated "thinking"
  indicator and a pair of blinking eyes on the welcome screen. Colours come from
  your Matugen/Wallust theme.
- 🧭 **First-run onboarding** — the widget walks you through setup: pick a local
  model (with **live download progress**) *or* connect a cloud provider (with key
  validation against the provider's API) before unlocking the chat.

---

## Requirements

| Component | Needed for |
|---|---|
| **Linux** (GlassyOS / Arch-based recommended) | everything |
| **Python 3** | the backend (stdlib only — no packages to install) |
| [**ollama**](https://ollama.com) | local models (optional but recommended) |
| **Quickshell + Hyprland** | the desktop chat widget |
| An **OpenRouter** or **Groq** API key | optional cloud replies (both have free tiers) |

CLI and TUI modes work on any Linux box with Python 3 — no Hyprland, no Quickshell
and even no ollama required (if you're using a cloud provider).

---

## Installation

`setup` is a self-contained installer that lives next to the sources. Run it from
inside the folder:

```bash
bash setup          # interactive
bash setup -y       # non-interactive — assume yes for every prompt
```

What it does, step by step:

1. **Sanity checks** — confirms Linux and that `glassbot` + `glassbot-backend` sit
   next to the installer.
2. **Dependencies** — verifies `python3`; reports whether `ollama` is present
   (a warning, not a hard error) and whether a Hyprland setup was detected.
3. **Binaries** — copies `glassbot` and `glassbot-backend` into `~/.local/bin/`
   and marks them executable.
4. **Widget** — *only when Hyprland is detected*, copies `quickshell/Glassbot.qml`
   to `~/.config/hypr/scripts/quickshell/glassbot/`.
5. **Config** — creates `~/.config/glassbot/config.json` from `config.example.json`
   if none exists yet (never overwrites an existing config).
6. **PATH** — appends `~/.local/bin` to `~/.bashrc` (or `~/.zshrc`) if it isn't
   already there.
7. **Verify + clean up** — checks the install, prints next steps, then **deletes
   itself** (you're asked first unless you passed `-y`).

After installing:

```bash
glassbot --status      # check backend + ollama
glassbot "hello!"      # a one-shot chat
glassbot --tui         # a minimal terminal chat
```

If you're on Hyprland, bind `SUPER+CTRL+A` to run `glassbot` — that keybind is the
canonical way to open the widget in GlassyOS.

> **Manual install.** If you'd rather not run the installer, the three pieces are:
> `install -m755 glassbot ~/.local/bin/glassbot`,
> `install -m755 glassbot-backend ~/.local/bin/glassbot-backend`, and the widget
> goes to `~/.config/hypr/scripts/quickshell/glassbot/Glassbot.qml`.

---

## Quick start

```bash
# 1. Install
bash setup

# 2. (Recommended) get a local model
ollama pull llama3.2:3b

# 3. Open the widget (Hyprland) …
glassbot
# … or just talk to it from the terminal:
glassbot "explain what a Wayland compositor is in two sentences"
```

Typical first session in the widget:

1. The welcome screen greets you and asks you to set it up.
2. **Step 1 — pick a local model.** Choose one and watch it download with live
   progress, or skip if you only want the cloud.
3. **Step 2 — pick a provider.** OpenRouter or Groq, both free-tier friendly.
4. **Step 3 — paste your key.** glassbot validates it against the provider's API
   before saving.
5. Done — the chat unlocks and you're talking to your assistant.

Prefer the terminal? `glassbot --tui` gives you a tiny REPL (`/quit` to exit,
`/reset` to clear history).

---

## Configuration

Config lives at `~/.config/glassbot/config.json` and is written from
`config.example.json` on install. Every key (with its default):

| Key | Default | Meaning |
|---|---|---|
| `model` | `llama3.2:3b` | Local ollama model to use. If it isn't installed, glassbot falls back to the first installed model in the fallback list (`llama3.2:3b`, `qwen2.5:3b`, `qwen2.5:1.5b`, `llama3.2:1b`). |
| `ollama_url` | `http://localhost:11434` | ollama endpoint — change it if ollama runs on another host/port. |
| `search_results` | `5` | How many web snippets to fetch when a search runs. |
| `backend` | `auto` | Routing: `auto` (cloud when a key is present, else local), `local` (always ollama), or `cloud` (always the cloud). |
| `cloud_provider` | `openrouter` | Which provider to use: `openrouter` or `groq`. Switching this automatically swaps `cloud_url` and (if you left the model at a known default) `cloud_model`. |
| `cloud_url` | *(provider URL)* | OpenAI-compatible chat-completions endpoint. Usually you don't touch this. |
| `cloud_model` | *(provider default)* | The cloud model to request. OpenRouter's default is a free model; Groq's default is `llama-3.3-70b-versatile`. |
| `cloud_api_key` | *(empty)* | The API key. **Never commit this** — prefer the environment variable (see below). |
| `setup_done` | `false` | Whether first-run onboarding has been completed. Setting it back to `false` re-triggers onboarding without deleting chats or keys. |
| `tools_enabled` | `true` | Allow the model to propose `<<RUN: …>>` shell commands (always user-approved). |

**API-key resolution order** (first hit wins):

1. **Environment variable** — `OPENROUTER_API_KEY` (the older `GROQ_API_KEY` name
   is still accepted, so an existing dotfile keeps working). *Preferred.*
2. **`config.json`** — the `cloud_api_key` field.
3. **A standalone keyfile** — `~/.config/glassbot/openrouter_api_key` (or
   `groq_api_key`), a single line containing just the key.

Keeping the key in an environment variable or a keyfile means your `config.json`
can stay key-free — which matters because the config file is exactly the kind of
thing you might share when reporting a bug.

```bash
# preferred — keep the secret out of the config file entirely
export OPENROUTER_API_KEY="sk-or-…"
```

Provider details:

| Provider | Default model | Fallback chain | Notes |
|---|---|---|---|
| **OpenRouter** | `qwen/qwen3.8-27b:free` | `nvidia/nemotron-3-super-120b-a12b:free`, `google/gemma-4-26b-a4b-it:free`, `poolside/laguna-s-2.1:free` | Aggregates many models; generous free tier. Keys: <https://openrouter.ai/keys> |
| **Groq** | `llama-3.3-70b-versatile` | `llama-3.1-8b-instant` | Very fast; fewer models, stricter rate limits. Keys: <https://console.groq.com/keys> |

> **Onboarding writes config for you.** When you pick a provider and validate a
> key in the widget, glassbot saves the key, sets `cloud_provider`, and points
> `cloud_url` + `cloud_model` at that provider's defaults. You rarely need to edit
> the file by hand.

---

## How it works (architecture)

Three moving parts talk to each other over local pipes and HTTP:

```
┌─────────────────────┐   JSON-lines IPC (stdin/stdout)   ┌──────────────────────┐
│  Quickshell widget  │  ◄──────────────────────────────► │  glassbot-backend    │
│  Glassbot.qml       │   boot · chat · search · …         │  (Python, stdlib)    │
└─────────────────────┘   delta · end · search_results · … └──────────┬───────────┘
                                                                      │
                    ┌─────────────────────────────────────────────────┼──────────────┐
                    │                                                  │              │
              ┌─────▼─────┐                                    ┌───────▼─────┐  ┌─────▼─────┐
              │  ollama   │  (local models, HTTP :11434)       │ OpenRouter  │  │   Groq    │
              └───────────┘                                    │  / Groq     │  │  (free)   │
                                                               └─────────────┘  └───────────┘
```

### 1. `glassbot` — the launcher (Bash)

The entry point and the only thing a user normally touches. Its behaviour depends
on how it's called:

- **No arguments, in a graphical Hyprland session** (`HYPRLAND_INSTANCE_SIGNATURE`
  is set and `~/.config/hypr/scripts/qs_manager.sh` exists) → runs
  `qs_manager.sh toggle glassbot`, i.e. it toggles the Quickshell widget.
- **No arguments, no Hyprland** → falls back to `--tui` with a friendly note.
- **`glassbot <message …>`** → one-shot chat via `glassbot-backend chat`; the reply
  is streamed straight to stdout.
- **`glassbot /search <query>`** → one-shot, search-augmented reply.
- **`glassbot --tui`** → a minimal terminal REPL: type, press Enter, read the
  streamed reply. `/quit`, `/exit` and `/reset` are handled locally.
- **`glassbot --reset`** → deletes all stored chats.
- **`glassbot --status`** → prints backend / ollama status as JSON.
- **`glassbot --version`** → prints the launcher version and the backend version.

### 2. `glassbot-backend` — the engine (Python)

A single ~1 800-line Python file with **no third-party imports**. It is both a
one-shot CLI and, with `--ipc`, a long-lived JSON-line server for the widget.

**Modes:**

| Invocation | Behaviour |
|---|---|
| `glassbot-backend` (no args) | Reads all of stdin, replies once on stdout. |
| `glassbot-backend --ipc` | Long-lived JSON-lines protocol over stdin/stdout (used by the widget). |
| `glassbot-backend chat "<msg>"` | One-shot chat from argv. |
| `glassbot-backend search "<query>"` | One-shot, search-augmented reply. |
| `glassbot-backend status` | Prints full status JSON (ollama + cloud routing). |
| `glassbot-backend reset` | Deletes all chats. |
| `glassbot-backend --version` | Prints the backend version (currently `0.6.0`). |

**IPC protocol** — one JSON object per line in each direction.

Commands *in* (widget → backend):

```
{"type": "boot"}                                   {"type": "chat",        "text": "…"}
{"type": "search",      "text": "…"}               {"type": "new_chat"}
{"type": "open_chat",   "id": "…"}                 {"type": "delete_chat", "id": "…"}
{"type": "rename_chat", "id": "…", "title": "…"}   {"type": "list_chats"}
{"type": "ping"}                                   {"type": "read_file",   "path": "…"}
{"type": "tool_approve", "id": "…"}                {"type": "tool_deny",   "id": "…"}
{"type": "setup_state"}                            {"type": "setup_install_model", "name": "…"}
{"type": "setup_save_key", "key": "…", "provider": "…"}
{"type": "setup_finish", "backend": "…"}           {"type": "setup_skip"}
{"type": "setup_reset"}
```

Events *out* (backend → widget):

```
{"type": "status",          "ok": true, "model": …, "model_present": true, …}
{"type": "boot_state",      "active_id": …, "messages": […], "chats": […], "setup_done": …, …}
{"type": "delta",           "text": "…"}          {"type": "end",   "search_used": false, "active_id": …}
{"type": "search_results",  "items": […], "query": "…"}
{"type": "backend_used",    "backend": "cloud"|"local"}
{"type": "cloud_model_fallback", "from": "…", "to": "…", "reason": "…"}
{"type": "chats_refresh",   "items": […], "active_id": …}
{"type": "chat_loaded",     "id": …, "title": …, "messages": […]}
{"type": "files_read",      "paths": […]}
{"type": "tool_request",    "id": …, "command": "…"}   {"type": "tool_running", …}
{"type": "tool_result",     "id": …, "ok": …, "output": …, "exit_code": …}
{"type": "setup_state" | "setup_progress" | "setup_result" | "file_read"}
{"type": "error",           "msg": "…"}
```

**Backend routing.** `effective_backend()` resolves the order to try:

- `backend: local` → ollama only.
- `backend: cloud` → cloud only.
- `backend: auto` → cloud first **if** a key is present, otherwise local.

When the preferred backend fails *before* emitting any token, the dispatcher falls
back to the other one — so the same `chat_stream()` code path serves both. Actual
`backend_used` events are emitted so the UI can show a "cloud" / "local" badge.

**Cloud fallback chain.** `_cloud_stream_with_fallback()` iterates the provider's
model chain (your configured model first, then the provider's list). It requests
the first token; if that raises a retryable error (429 / 5xx / transport) it moves
to the next model and emits `cloud_model_fallback`. A 401/403 aborts immediately —
retrying won't fix a bad key. Once a model produces its first token, glassbot
commits to it, so a mid-stream failure never duplicates output.

**Streaming.** Local ollama streaming and OpenAI-compatible cloud streaming share
one interface. Everything (chat, titles, tool follow-ups) is streamed as `delta`
events so the UI renders tokens as they arrive.

**Chat storage.** Each chat is `~/.cache/glassbot/chats/chat-<ms>-<hex>.json` with
`id`, `title`, `created`, `updated` and a `messages` array. The active chat id
lives in `~/.cache/glassbot/active.txt`. History is trimmed to the last **30
turns** (60 messages). A pre-0.2 `~/.cache/glassbot/history.json` is migrated into
a normal chat the first time the backend runs. On the first turn of a conversation
the backend asks the model for a short title (3–5 words, in the user's language)
and stores it.

**Tool execution.** The model may emit `<<RUN: command>>` markers. The backend
extracts each into a pending `tool_request`; when the user approves, `run_tool()`
executes it with `/bin/bash -c`, capped at **30 s** and **16 KB** of output. A
regex blocklist refuses obviously destructive commands (`rm -rf /`,
`--no-preserve-root`, `mkfs.*`, `dd … of=/dev/sd|nvme|mmc`) even after approval.
The output is fed back as a hidden synthetic turn so the model can reason about it.

### 3. `quickshell/Glassbot.qml` — the widget

A single QML file (~2 000 lines) that is the assistant's face inside GlassyOS.

- On load it spawns the backend as a child `Process`:
  `~/.local/bin/glassbot-backend --ipc`, with stdin enabled and a `SplitParser`
  reading one JSON object per line from stdout. If the backend dies, an 800 ms
  timer **auto-respawns** it — which also keeps onboarding alive across crashes.
- A state machine maps backend events to UI state: streaming text, the sidebar
  chat list, search-result cards, tool approval cards (Allow / Deny), and error
  bubbles.
- The **onboarding flow** has four steps (0 welcome, 1 local model, 2 provider,
  3 key) and drives the `setup_*` IPC commands, including live pull percentages.
- Colours come from a `MatugenColors` object, so the panel matches your current
  GlassyOS theme. The welcome screen even has two animated blinking eyes.

---

## Usage

### Launcher

```bash
glassbot                            # toggle the Quickshell chat widget (Hyprland)
glassbot "hello!"                   # one-shot chat, streams reply to stdout
glassbot /search "glassyos news"    # one-shot web-augmented reply
glassbot --tui                      # minimal terminal chat
glassbot --reset                    # clear all stored chats
glassbot --status                   # backend / ollama status
glassbot --version                  # version info
```

### Widget

Open it with `SUPER+CTRL+A` (or `glassbot` with no arguments). Inside the chat you
get a sidebar of conversations, streaming replies, and these commands in the input
box:

| Command | Effect |
|---|---|
| `/search <query>` | Force a web search for this message. |
| `/nosearch <query>` (alias `/nolookup`) | Never search, even for time-sensitive questions. |
| `/local <query>` | Answer with the **local** model for this turn only. |
| `/cloud <query>` | Answer with the **cloud** model for this turn only. |
| `/read <path> [prompt]` | Attach a file's contents to this message (repeatable). |
| `/new` (also `/reset`, `/clear`) | Start a fresh chat (existing chats are kept). |

### Backend CLI (for debugging)

```bash
glassbot-backend chat "what is Hyprland?"   # one-shot
glassbot-backend search "arch linux 2026"   # force a search
glassbot-backend status                     # JSON status
glassbot-backend --ipc                      # drive it by hand over JSON lines
```

---

## Examples

One-shot question straight from the terminal:

```bash
$ glassbot "give me a one-liner to list my biggest files in /var"
```

Search-augmented reply (sources are numbered and cited):

```bash
$ glassbot /search "current euro dollar exchange rate"
```

Attach a file for review (in the widget input):

```
/read ~/projects/app/error.log why does the build fail?
```

Ask glassbot to *do* something — it proposes a command, you approve it:

```
you  ▸ how much RAM do I have free?
bot  ▸ I'll check.
       <<RUN: free -h>>
       [ Allow ]  [ Deny ]      ← you click Allow, output comes back,
       … and glassbot answers with the result.
```

Drive the backend by hand (useful when developing the widget):

```bash
printf '%s\n' '{"type":"boot"}' '{"type":"chat","text":"hi"}' \
  | glassbot-backend --ipc
```

---

## Troubleshooting & gotchas

- **Free cloud models rot.** Providers retire and re-rate-limit free models all the
  time. That's exactly why every provider has a **fallback chain**: if a model
  starts returning 429/5xx before its first token, glassbot moves to the next one
  automatically (you'll see a `cloud_model_fallback` notice). If *all* models in a
  chain die, it's time to update the chain — or switch `cloud_provider`.
- **"Which model am I actually talking to?"** The widget shows a `cloud` / `local`
  badge based on real `backend_used` events, not on your config — so it reflects
  what actually answered.
- **`ollama is offline` in the input box.** The widget pings the backend; if
  ollama isn't reachable (and no cloud key is set) the input is disabled. Start
  ollama (`systemctl --user start ollama`) or configure a cloud key.
- **QML reload needs the right environment.** Reloading the widget by IPC requires
  both `XDG_RUNTIME_DIR` **and** `WAYLAND_DISPLAY=wayland-1` — otherwise Quickshell
  says *"No running instances … current display unk"*. Example:
  `WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 quickshell … ipc call main forceReload`.
- **The widget is launched with an absolute path.** `Glassbot.qml` spawns
  `/home/elias/.local/bin/glassbot-backend` by hard-coded path (Quickshell runs with
  a stripped `PATH` that doesn't include `~/.local/bin`, so a bare command name
  never resolved). If your username isn't `elias`, edit that line — or the auto-
  respawn will loop silently.
- **`QML font.pixelSize` must be an integer.** A value like `14.5` fails with
  *"Invalid property assignment: int expected"* and the widget simply doesn't appear
  — the only clue is in the Quickshell log
  (`/run/user/1000/quickshell/by-id/<id>/log.qslog`; grep with `grep -a` because
  the log contains null bytes).
- **Searches return nothing.** The DDG HTML scraper is frequently blocked; that's
  why glassbot also tries the DuckDuckGo Instant Answer API and Wikipedia. If every
  source is empty you'll get an explicit *"Search returned no results"* error rather
  than a hallucinated answer.
- **`config.json` got clobbered to an old default?** glassbot auto-migrates known
  stale default models forward, but it only touches values it recognises as
  defaults. If you deliberately pinned a model, that value is left alone.
- **Reset vs. wipe.** `glassbot --reset` (and `/new`) only *start fresh* /
  clear conversations. To re-run onboarding, set `setup_done: false` (the widget's
  "reset glassbot" action does this) — it does **not** delete your chats or key.

---

## Security notes

- **Local by default.** Without a cloud key, no prompt or reply ever leaves your
  machine. With one, only the active conversation goes to your chosen provider.
- **Keys stay out of the repo.** `config.json`, `history.json`, `__pycache__/`
  and `*.pyc` are git-ignored. The `.gitignore` note is explicit: *never commit
  real secrets or chat history.* Prefer the `OPENROUTER_API_KEY` env var so the
  config file stays shareable.
- **No auto-execution.** The model can *propose* shell commands, but every one needs
  an explicit **Allow** click, and a backend-side regex blocklist refuses the worst
  destructive patterns regardless. Commands are single-line only, time-limited to
  30 s and output-capped.
- **Files are read, never executed.** `/read` only ever reads the path you name, and
  undecodable bytes are replaced rather than raising.
- **Chats are plain JSON** in `~/.cache/glassbot/` — treat them like any other
  sensitive local data.

---

## Status & roadmap

**Status: β (beta).** The backend is at **v0.6.0**; the widget and launcher track
the same line. Verified/working today:

- local chat through ollama with streaming,
- cloud chat through OpenRouter *and* Groq, including the fallback chains,
- automatic and forced web search with multi-source, cited results,
- multi-chat history with auto-titling, plus legacy migration,
- `/read` file context,
- tool suggestions with Allow/Deny approval cards,
- the full first-run onboarding flow (model pull + key validation).

Ideas / not yet done:

- fully configurable system prompt from `config.json`,
- more cloud providers behind the same OpenAI-compatible interface,
- richer file handling (images / PDFs),
- per-chat backend pinning in the UI,
- a settings panel for `search_results` and `tools_enabled` without editing JSON.

Contributions and ideas are welcome — open an issue.

---

## Credits & license

glassbot is part of the **GlassyOS** project and the wider
[glasstools](https://github.com/eliii-te/glasstools) ecosystem. It is built on:

- [**ollama**](https://ollama.com) for local model inference,
- [**Quickshell**](https://quickshell.org) + **Hyprland** for the desktop widget,
- **OpenRouter** and **Groq** as optional OpenAI-compatible cloud backends.

It carries no third-party Python dependencies — the backend uses only the standard
library.

**License: MIT © GlassyOS.**

**Made exclusively for GlassyOS.** 🐧
