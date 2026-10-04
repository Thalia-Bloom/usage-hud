# Install Usage HUD

Usage HUD is a macOS 14 or later menu-bar app. It reads local usage snapshots and does not send your prompts, transcripts, or tokens anywhere.

## 1. Install

1. Open `UsageHUD.dmg`.
2. Drag **Usage HUD** onto **Applications**.
3. Open **Usage HUD** from Applications. If you open it somewhere else, it offers to move itself there.

The app is signed with a Developer ID and notarized by Apple, so macOS opens it without a warning. Prefer a zip? `UsageHUD.zip` on the releases page holds the same app.

Usage HUD lives in the menu bar (no Dock icon). On first launch the panel opens under its menu-bar meter. Click the meter to open the panel; right-click it for Settings, Check for Updates, About and Quit.

Updates install themselves after you say yes: Usage HUD checks once a day, and **Check for Updates…** checks now.

## 2. Click Set up

Open the panel and click **Set up**. Usage HUD looks for the coding tools on this Mac, installs a background refresh for the ones it finds, and collects the first reading. That takes about 10 seconds.

You do not need the terminal.

Lanes you do not have stay hidden. After you install another tool, open Settings and click **Detect again**.

**Remove** in Settings unloads those jobs and deletes their LaunchAgent files. It does not delete history or credentials.

Snapshots are written to `~/.codex-usage-hud/`. The app never requires a license check.

## 3. Connect your agents (optional)

Open **Settings › Agents** and click **Copy prompt**. Paste it into Claude Code, Codex, Gemini CLI or Cursor. That agent adds Usage HUD's read-only MCP server to each agent CLI on this Mac, asks before adding a two-line rule to their instructions, and shows you every change. See [AGENTS.md](AGENTS.md).

The app's command line has two commands for this. `setup` does what the Set up button does: it finds the coding tools on this Mac, installs their background refresh, takes a first reading, and prints one line per lane with the next action for any lane that needs one. `detect` only reports what it finds and changes nothing. Both take `--json`.

```sh
'/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' setup
'/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' detect
```

**Setting up from an agent.** You can skip the button and say to any coding agent: "Usage HUD is installed at `/Applications/Usage HUD.app`, set it up." The agent runs `setup` and tells you the next action for each lane. No login information is needed.

## 4. Set your plans (optional)

**Settings › Plans** shows what you pay per month next to the API value of your usage. Claude Max and ChatGPT Pro are detected; set the others or type a custom amount. API value is what your tokens would cost at pay-per-use API prices; you are never billed for it.

## 5. Requirements

- macOS 14 or later
- The matching CLI signed in on this Mac: Codex, Claude Code, Gemini or Antigravity, Grok
- Claude and Codex need nothing else. When Node.js or Python 3 is missing, the app reads both lanes itself.
- Node.js 18 or later for Gemini and Grok (install from [nodejs.org](https://nodejs.org) or Homebrew, then Set up again)
- Antigravity CLI (`agy`) for Gemini; the Gemini CLI alone has no quota the app can read
- Ollama for Local Models

Python 3 is optional. With both Node.js and Python 3 installed, Set up also installs the Claude background job described below.

Empty lanes tell you the next action instead of showing 0%.

Set up skips jobs whose runtime is missing and tells you which lanes that affects.

## 6. What each lane needs

### Codex

Needs the Codex CLI so session logs exist under `~/.codex/sessions`. With Node.js, background refresh writes `codex-usage.json`. Without Node.js, the app reads the newest rate-limit reading from those session logs itself, so run one Codex session first.

### Claude

Needs Claude Code signed in on this Mac. Official window percentages come from the same usage endpoint Claude Code’s `/usage` panel uses, with the token in the Keychain item named `Claude Code-credentials`. The app only reads that token; it never refreshes or changes it.

With Node.js and Python 3 installed, the login job `com.codexusagehud.claude-writer` runs that official fetch on a timer. If either is missing, the app runs the same fetch itself, about every 10 minutes and when you click **Refresh**, and writes `claude-usage-native.json`. Only one of the two runs at a time. You do **not** need to edit `~/.claude/settings.json` for the Claude lane to work.

Claude Code saves its sign-in with macOS's own `security` tool, and the app reads it with the same tool, so there is normally no prompt. If your Mac does ask to let `security` use "Claude Code-credentials", click **Always Allow** (it reads the sign-in, nothing else). Click **Deny** and the Claude lane says so instead of guessing.

If Claude Code is not signed in, the lane reports unauthorized / missing credentials instead of a fake 0%.

### Gemini

Needs Gemini CLI and/or Antigravity (`agy`) on this Mac. Background refresh writes `gemini-usage.json`. If no quota file exists, the app can still derive a weaker local reading from `~/.gemini/tmp/*/chats/*.jsonl`.

### Grok

Needs the Grok CLI signed in (`~/.grok/auth.json`). Background refresh writes `grok-usage.json`. There is no in-app fallback if that file is missing.

### Local Models

Needs Ollama with retained server logs under `~/.ollama/logs`. The app totals evaluated-prompt and generated tokens from those logs. Background refresh is not required.

## 7. Optional: Claude statusline tap

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
