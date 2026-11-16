# Hush

Local meeting notes for macOS. Hush records Zoom, Google Meet, Teams or an in-room meeting **without
joining the call**, transcribes it **on your Mac** (Indonesian, English, or both mixed), labels who
said what, and writes a summary with decisions and action items. A small see-through **prompter**
can draft answers to questions people ask you, live.

- **No bot.** Hush listens to your Mac's audio output and microphone. Nothing shows up in the participant list.
- **Stays on your Mac.** Audio, transcripts and notes live in `~/Library/Application Support/Hush`. No account, no cloud, no telemetry.
- **Any AI you choose.** Claude Code CLI (default), Codex CLI, any OpenAI-compatible server (Ollama, LM Studio, OpenRouter, OpenAI) or the Anthropic API. Or none: local rules still pull out action items.
- **MCP server.** Claude Code (or any MCP client) can list, read and search your meetings.

Status: v0.1, Apple Silicon, macOS 14.4+. Tested on an M2 with 8 GB RAM, macOS 27.2.

## Install

One command (needs [Homebrew](https://brew.sh); Apple's free Command Line Tools are installed if missing; no Xcode, no Apple account):

```bash
curl -fsSL https://raw.githubusercontent.com/ainurfqq/hush-meetings/main/install.sh | bash
```

While the repo is private, use the GitHub CLI (after `gh auth login`):

```bash
gh api repos/ainurfqq/hush-meetings/contents/install.sh -H "Accept: application/vnd.github.raw" | bash
```

The installer builds Hush from source, installs `~/Applications/Hush.app`, links the `hush` command
into `~/.local/bin`, installs `whisper.cpp` with Homebrew and downloads about 800 MB of models
(each checked against a pinned SHA-256 in `scripts/engines.lock`).

Then run `open ~/Applications/Hush.app`. A waveform icon appears in the menu bar.

Uninstall: `bash ~/Library/Application\ Support/Hush/src/uninstall.sh` (add `--purge` to also delete meetings and models).

## Use

| Do this | How |
|---|---|
| Record an online meeting | Menu bar → **Record online meeting**. Hush records your mic ("Me") and the call audio (everyone else). |
| Record an in-room meeting | Menu bar → **Record in-room meeting**. Mic only; speakers are told apart by voice. |
| Process a recording you already have | Menu bar → **Import audio file…**, or `hush process meeting.m4a` |
| Read notes | **Open Hush** → pick a meeting → Summary / Transcript / Action items / Speakers (rename "Speaker 2" to a real name) |
| Prompter | ⌃⌥H show/hide · ⌃⌥A answer the last question now · ⌃⌥R start/stop recording |
| Tell people | Menu bar → **Copy consent message**, paste it into the meeting chat |

The first time you record, macOS asks for **Microphone** and **System Audio Recording** access. Allow both.

### The prompter and screen sharing

The prompter window uses macOS's window-sharing setting (`NSWindow.sharingType = .none`). On macOS 27.2
it was absent from every standard capture path we tested: `screencapture` (still and video),
ScreenCaptureKit (screenshot, live stream, window capture) and the legacy CGWindowList API. Proof is in
the QA report.

Check it on your own Mac: menu bar → **Check prompter is hidden from screen capture**
(or `~/Applications/Hush.app/Contents/MacOS/Hush --verify-hidden`). Hush captures the prompter area with ScreenCaptureKit
three times: with the panel hidden, shown, and deliberately made capturable as a control. It reports "Hidden ✓" only
when the shown capture matches the background and the control does not.

It is **not** a promise of invisibility. Apple calls this setting legacy, and a meeting app can use its
own capture method. Reports exist of Zoom and Teams capturing such windows on macOS 15. Before you rely
on it, run a one-minute check: start a test call with yourself, share your **entire screen**, open the
prompter with ⌃⌥H, and look at what the other side sees. Sharing one window instead of the whole screen
is safer still.

## AI providers

Settings → AI provider, or the CLI:

```bash
hush config set provider claude-cli          # default; uses your Claude Code login
hush config set provider openai-compatible   # then:
hush config set openAIBaseURL http://127.0.0.1:11434/v1 && hush config set model qwen2.5:7b
hush config set provider anthropic && hush key anthropic sk-ant-...      # key goes to the Keychain
hush config set provider codex-cli
hush config set provider none                # local rules only
```

Only the transcript text you summarize or ask about is sent, and only to the provider you picked.
Audio never leaves the Mac. Keys live in the macOS Keychain (service `id.roxst.hush`).

On 8 GB Macs, keep the prompter on a cloud provider (Claude Code CLI). A local model running next to
the speech engine during a live call made both slower in our tests. `prompterProvider` lets bigger Macs
use a local model for the prompter only.

## Claude Code / MCP

```bash
claude mcp add --transport stdio --scope user hush -- ~/.local/bin/hush mcp
```

Tools: `list_meetings`, `get_transcript`, `get_summary`, `get_action_items`, `search`. All are
read-only. Ask Claude Code things like "what did I promise in yesterday's meeting?".

## CLI

```
hush process <audio> [--title T]    hush list            hush show <id|latest> [--summary|--transcript|--json]
hush search <words>                 hush summarize <id>  hush ask "<question>" [--meeting <id>]
hush doctor                         hush setup           hush config [set <key> <value>]   hush mcp
```

## How it works

```
mic ──(Apple echo cancelling)──▶ mic.wav ──────────────┐
call audio ──(Core Audio process tap)──▶ system.wav ──┤
                                                       ▼
        sherpa-onnx diarization (pyannote seg 3.0 + 3D-Speaker CAM++) → who spoke when
        whisper.cpp large-v3-turbo (per turn, language auto-detect) → what they said
        your AI provider (or local rules) → summary, decisions, action items
```

Built with plain `swiftc` (`scripts/build.sh`), with no Swift package dependencies. The speech engines run as
local subprocesses. The speech server only listens on 127.0.0.1 and stops when Hush quits.

Tests: `scripts/test.sh` runs 23 unit tests plus an end-to-end test on a generated 5.6-minute
Indonesian/English meeting (speaker accuracy must be ≥ 80 %).

## Your responsibility

Recording people without telling them is illegal in many places. In Indonesia it can fall under
the personal data protection law (UU PDP, Law 27/2022). **You are responsible for getting consent and
for following the rules of every meeting, interview or exam you use Hush in.** Hush shows a recording
indicator and gives you a consent message to share. It does not hide itself from proctoring or
monitoring software and is not meant to.

## Licence

MIT, see `LICENSE`. Third-party engines and models are listed in `THIRD_PARTY.md`.
