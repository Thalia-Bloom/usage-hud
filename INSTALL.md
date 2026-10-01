# Install Usage HUD

Usage HUD is a macOS 14 or later menu-bar app. It reads local usage snapshots and does not send your prompts, transcripts, or tokens anywhere.

## 1. Unzip and move the app

1. Unzip `UsageHUD.zip` (Safari usually unzips it for you).
2. Move **Usage HUD** into your Applications folder.
3. Open **Usage HUD**.

The app is signed with a Developer ID and notarized by Apple, so macOS opens it without a warning. If you built an ad-hoc test zip yourself, Gatekeeper blocks the first open: on macOS 15 or later, open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**; on macOS 14, right-click the app → **Open** → **Open**.

The app is a menu-bar extra (no Dock icon). Click the glyph to open the panel. Right-click the glyph, or click the gear in the panel footer, for Settings.

## 2. Click Set up

Open the panel and click **Set up**. Usage HUD looks for the coding tools on this Mac, installs a background refresh for the ones it finds, and collects the first reading. That takes about 10 seconds.

You do not need the terminal.

Lanes you do not have stay hidden. After you install another tool, open Settings and click **Detect again**.

**Remove** in Settings unloads those jobs and deletes their LaunchAgent files. It does not delete history or credentials.

Snapshots are written to `~/.codex-usage-hud/`. The app never requires a license check.

## 3. Requirements

- macOS 14 or later
- The matching CLI signed in on this Mac: Codex, Claude Code, Gemini or Antigravity, Grok
- Claude and Codex need nothing else. When Node.js or Python 3 is missing, the app reads both lanes itself.
- Node.js 18 or later for Gemini and Grok (install from [nodejs.org](https://nodejs.org) or Homebrew, then Set up again)
- Antigravity CLI (`agy`) for Gemini; the Gemini CLI alone has no quota the app can read
- Ollama for Local Models

Python 3 is optional. With both Node.js and Python 3 installed, Set up also installs the Claude background job described below.

Empty lanes tell you the next action instead of showing 0%.

Set up skips jobs whose runtime is missing and tells you which lanes that affects.

## 4. What each lane needs

### Codex

Needs the Codex CLI so session logs exist under `~/.codex/sessions`. With Node.js, background refresh writes `codex-usage.json`. Without Node.js, the app reads the newest rate-limit reading from those session logs itself, so run one Codex session first.

### Claude

Needs Claude Code signed in on this Mac. Official window percentages come from the same usage endpoint Claude Code’s `/usage` panel uses, with the token in the Keychain item named `Claude Code-credentials`. The app only reads that token; it never refreshes or changes it.

With Node.js and Python 3 installed, the login job `com.codexusagehud.claude-writer` runs that official fetch on a timer. If either is missing, the app runs the same fetch itself, about every 10 minutes and when you click **Refresh**, and writes `claude-usage-native.json`. Only one of the two runs at a time. You do **not** need to edit `~/.claude/settings.json` for the Claude lane to work.

The first reading may show a macOS prompt asking to let `security` use "Claude Code-credentials". Click **Always Allow** (it reads the sign-in, nothing else). Click **Deny** and the Claude lane says so instead of guessing.

If Claude Code is not signed in, the lane reports unauthorized / missing credentials instead of a fake 0%.

### Gemini

Needs Gemini CLI and/or Antigravity (`agy`) on this Mac. Background refresh writes `gemini-usage.json`. If no quota file exists, the app can still derive a weaker local reading from `~/.gemini/tmp/*/chats/*.jsonl`.

### Grok

Needs the Grok CLI signed in (`~/.grok/auth.json`). Background refresh writes `grok-usage.json`. There is no in-app fallback if that file is missing.

### Local Models

Needs Ollama with retained server logs under `~/.ollama/logs`. The app totals evaluated-prompt and generated tokens from those logs. Background refresh is not required.

## 5. Optional: Claude statusline tap

The statusline tap is **optional** and needs Node.js. The Claude lane already fetches official usage on a timer. If you also want Claude Code’s status line to push live rate-limit numbers into the HUD, point Claude Code’s `statusLine.command` at the copied helper after Set up. Set up copies it to:

`~/Library/Application Support/Codex Usage HUD/bin/bloom-usage-statusline-tap`

That path has spaces in it (`Application Support`, `Codex Usage HUD`), so it must be quoted. Edit `~/.claude/settings.json` and add:

```json
{
  "statusLine": {
    "type": "command",
    "command": "\"$HOME/Library/Application Support/Codex Usage HUD/bin/bloom-usage-statusline-tap\""
  }
}
```

If Claude Code already has a `statusLine` entry, replace its `command` value with the quoted path above rather than adding a second `statusLine` key.

Do not apply that change unless you want it. Set up never edits `~/.claude/settings.json`.

Updates and support: https://hud.thaliabloom.com
