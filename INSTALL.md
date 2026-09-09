# Install Usage HUD

Usage HUD is a macOS 14 or later menu-bar app. It reads local usage snapshots and does not send your prompts, transcripts, or tokens anywhere.

## 1. Unzip and move the app

1. Unzip `CodexUsageHUD-<version>-<build>.zip`.
2. Move `CodexUsageHUD.app` into your Applications folder.
3. Open **Usage HUD**.

If Gatekeeper blocks the first open (“macOS cannot verify the developer”), right-click the app → **Open** → **Open**. A Developer ID + notarized build does not need this step; ad-hoc test zips do.

The app is a menu-bar extra (no Dock icon). Click the glyph to open the panel. Right-click the glyph, or click the gear in the panel footer, for Settings.

## 2. Set up background refresh

The app displays whatever is already on disk. Open **Settings** and click **Set up**. That copies the bundled helpers and installs login jobs that keep Codex, Claude, Gemini, and Grok snapshots fresh.

Then click **Refresh now** if you want the first collection immediately. After that, reopen the panel (or wait a few seconds).

**Remove** unloads those jobs and deletes their LaunchAgent files. It does not delete history or credentials.

Snapshots are written to `~/.codex-usage-hud/`. The app never requires a license check.

## 3. Requirements

- macOS 14 or later
- Node.js for Codex, Gemini, and Grok (install from [nodejs.org](https://nodejs.org), then Set up again)
- Python 3 for Claude (macOS / Homebrew / python.org)
- Ollama for Local Models
- The matching CLI signed in on this Mac: Codex, Claude Code, Gemini or Antigravity, Grok

Turn off any lane you do not use in Settings (Connected / Show). Empty lanes say so in plain English instead of showing 0%.

Set up will skip jobs whose runtime is missing and tell you which ones.

## 4. What each lane needs

### Codex

Needs the Codex CLI so session logs exist under `~/.codex/sessions`. Background refresh writes `codex-usage.json`.

### Claude

Needs Claude Code signed in on this Mac. Official window percentages come from the same usage endpoint Claude Code’s `/usage` panel uses, with the token in the Keychain item named `Claude Code-credentials`.

The login job `com.codexusagehud.claude-writer` runs that official fetch on a timer. You do **not** need to edit `~/.claude/settings.json` for the Claude lane to work.

If Claude Code is not signed in, the lane reports unauthorized / missing credentials instead of a fake 0%.

### Gemini

Needs Gemini CLI and/or Antigravity (`agy`) on this Mac. Background refresh writes `gemini-usage.json`. If no quota file exists, the app can still derive a weaker local reading from `~/.gemini/tmp/*/chats/*.jsonl`.

### Grok

Needs the Grok CLI signed in (`~/.grok/auth.json`). Background refresh writes `grok-usage.json`. There is no in-app fallback if that file is missing.

### Local Models

Needs Ollama with retained server logs under `~/.ollama/logs`. The app totals evaluated-prompt and generated tokens from those logs. Background refresh is not required.

## 5. Optional: Claude statusline tap

The statusline tap is **optional**. The Claude writer already fetches official usage on a timer. If you also want Claude Code’s status line to push live rate-limit numbers into the HUD, point Claude Code’s `statusLine.command` at the copied helper after Set up:

`~/Library/Application Support/Codex Usage HUD/bin/bloom-usage-statusline-tap`

Do not apply that change unless you want it. Set up never edits `~/.claude/settings.json`.

Updates and support: https://hud.thaliabloom.com
