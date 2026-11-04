# Usage HUD for agents

Usage HUD tracks how much of each AI coding plan you have used: Claude,
Codex, Gemini, Grok, and local models. The same numbers the menu-bar panel
shows are available to agents in three ways, all built into the app binary:

- **A command line**: `status`, `room`, `lane`, `spend`, and `activity` print short text or JSON;
  `setup` does what the panel's Set up button does.
- **An MCP server**: `mcp` speaks the Model Context Protocol over stdio, so
  Claude Code, Codex, Gemini CLI, Cursor, and other MCP clients can call it.
- **A setup prompt**: paste it into any agent session and that agent wires
  up the rest of your agents.

Everything except `setup` is read-only. The command line and the MCP server
read the state files the app already keeps in `~/.codex-usage-hud`. They
never write those files, never use the network, and never output tokens,
credential paths, prompts, or file contents. They work when the app is
closed; every reading says how old it is. `setup` installs the same
background refresh jobs the Set up button installs, and nothing else.

Nothing extra to install: no Node, no Python, no package.

## Quick start: the setup prompt

1. Open Usage HUD **Settings** and find **Connect your agents**.
2. Click **Copy prompt**.
3. Paste it into a Claude Code, Codex, Gemini CLI, or Cursor session.

The agent checks that Usage HUD answers (and runs `setup` if there are no
readings yet), adds the MCP server to each agent CLI it finds, asks before
it adds a two-line rule to your global instructions, and then shows you
every change it made.

### Setting up from an agent

You do not have to click Set up yourself. Tell any coding agent "Usage HUD
is installed at `/Applications/Usage HUD.app`, set it up" and the agent runs
`setup`. It finds the coding tools on this Mac, installs their background
refresh, takes a first reading, and prints the next action for any lane that
needs one (for example, "Sign in to Grok, then run setup again"). No login
information is needed.

You can also print the prompt from a terminal:

```sh
'/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' prompt
```

The prompt contains this Mac's real paths. For an app in `/Applications` and
a home folder of `/Users/you`, it reads:

```text
Please connect my coding agents to Usage HUD, the menu-bar app on this Mac that shows how much of each AI plan's limits I have used (Claude, Codex, Gemini, Grok, local models). Its command line and MCP server are read-only: they read local files, need no keys, and send nothing anywhere.

The Usage HUD command on this Mac:
'/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD'

1. Check that it works by running:
   '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' status
   It should print one line per plan. If it says there are no readings yet, run:
   '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' setup
   That finds the coding tools on this Mac, installs their background refresh and takes a first reading, the same as the Set up button. It needs no keys or logins. Read the next action it prints for each plan and tell me those, then continue.

2. Add the MCP server, named usage-hud, to each agent CLI installed here. Run `command -v claude codex gemini` and skip any that are missing. If an agent already has a server named usage-hud, leave it alone.
   - Claude Code. Check: claude mcp get usage-hud
     Add: claude mcp add --scope user usage-hud -- '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' mcp
   - Codex. Check: codex mcp get usage-hud
     Add: codex mcp add usage-hud -- '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' mcp
     If `codex mcp` does not exist, append this to /Users/you/.codex/config.toml instead:
     [mcp_servers.usage-hud]
     command = "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD"
     args = ["mcp"]
   - Gemini CLI. Check: gemini mcp list
     Add: gemini mcp add --scope user usage-hud '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' mcp
     If that fails, add this entry inside "mcpServers" in /Users/you/.gemini/settings.json, keeping everything already there:
     "usage-hud": { "command": "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD", "args": ["mcp"] }
     Gemini CLI starts MCP servers only in folders I have trusted, so `gemini mcp list` may show it as disabled here.
   - Cursor. If /Users/you/.cursor exists, add the same entry inside "mcpServers" in /Users/you/.cursor/mcp.json, keeping everything already there.

3. Ask me: "Add a two-line Usage HUD rule to your agents' global instructions?" Only if I say yes, append these two lines to the file of each agent you set up (create the file if it is missing, and skip it if the lines are already there): /Users/you/.claude/CLAUDE.md for Claude Code, /Users/you/.codex/AGENTS.md for Codex, /Users/you/.gemini/GEMINI.md for Gemini CLI.
   - Before long or parallel work, check Usage HUD: call the usage-hud MCP tool which_plan_has_room, or run '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' room
   - If your plan is running hot or nearly out, tell the user and name the plan that has room.

4. Show me every change you made: each command you ran and its result, and each file you edited with the exact lines you added. Then tell me to restart any open agent sessions so they load the new server.

To undo later: claude mcp remove --scope user usage-hud; codex mcp remove usage-hud; gemini mcp remove --scope user usage-hud; then delete the two lines.
```

## Command line

The command line is the app's own executable:

```sh
'/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' <command>
```

The path has a space in it, so quote it. If you want a short name, the repo
ships `bin/usage-hud`, a small `sh` wrapper that finds the app (through
`$USAGE_HUD_BIN`, its own location inside an app bundle, `/Applications`,
or `~/Applications`) and passes your arguments through. This page writes
`usage-hud` for either form.

| Command | What it prints |
| --- | --- |
| `status` | The verdict, the plan with the most room, and one line per plan. |
| `status --json` | The full [agent summary](#json-agent-summary). |
| `room` | One line: which plan has room right now. |
| `room --json` | The verdict, the plan with room, one sentence of advice, and every usable plan. |
| `lane <provider>` | One plan in detail, every window. Add `--json` for the lane object. |
| `spend` | API value (what usage would cost at API prices, never billed), monthly plan cost, and value multiple, per plan and in total. Add `--json` for the spend summary. |
| `activity` | Recent coding-agent sessions, tokens, API value, burn rate, and the top burner across Claude Code, Codex, and Gemini. Add `--json` for the activity summary. |
| `setup` | What the Set up button does: finds the coding tools on this Mac, installs their background refresh, takes a first reading. One line per plan: found or not, job installed or skipped and why, the first reading, and the next action. Add `--json` for the [setup report](#setup-report). |
| `detect` | Detection only: which tools are on this Mac, which jobs are already installed, which readings exist. Changes nothing. Same shape as `setup`. |
| `mcp` | Runs the MCP server on stdin and stdout. |
| `prompt` | Prints the setup prompt with this Mac's paths. |
| `schema` | Prints the JSON Schema for `status --json`. |
| `help`, `version` | Help and version; `--help` and `--version` also work. |

Providers for `lane`: `claude`, `codex`, `gemini`, `grok`, `local`.
Display names such as `"Claude Code"` also work.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. For `room`: a plan has room now. For `setup`: at least one plan has a reading or an installed job. |
| `1` | `room`: no plan clearly has room right now. `setup`: Set up could not run (for example the app is not in Applications) or installed nothing usable; the message says why. |
| `2` | Usage error: unknown command, flag, or provider. |
| `3` | `status`, `room`, `lane`: no readings yet; run `setup`. `setup`, `detect`: no supported tool was found on this Mac. |

Scripts can gate work on `room`:

```sh
usage-hud room && start-the-long-job
```

### Sample output

```console
$ usage-hud status
GO  Claude: clear to build.
Room now: Grok, 0% of its week used, on pace, resets in 6d 5h.

Claude        week   11%  on pace       resets in 6d 2h · measured, 7m old
Codex         week   93%  almost spent  resets in 1d 21h · official, 7m old
Gemini        week  100%  spent         resets in 3d 7h · official, 2h old (stale)
Grok          week    0%  on pace       resets in 6d 5h · official, 13m old
Local Models  -        -  pace unknown  Local models have no plan limit; this lane counts tokens only.

$ usage-hud room
Grok has the most room now: 0% of its week used, on pace, resets in 6d 5h.

$ usage-hud setup
Set up complete. First reading: Claude, Codex.
Claude        found (Claude Code credentials file) · job: loaded · reading: 11% of the week used
Codex         found (Codex session logs) · job: loaded · reading: 93% of the week used
Gemini        not found (Gemini is not installed) · next: Install the Antigravity CLI (agy) and sign in to Gemini, then run setup again.
Grok          found (Grok credentials) · job: skipped (needs Node.js) · next: Install Node.js 18 or later (nodejs.org or Homebrew), then run setup again.
Local Models  not found (Ollama is not installed) · next: Install and start Ollama, then run setup again.

Note: Grok needs Node.js. Install Node.js 18 or later from nodejs.org or Homebrew.
```

### Setup report

`setup --json` and `detect --json` print the same object. `schemaVersion`
is `1`.

```json
{
  "schemaVersion": 1,
  "command": "setup",
  "ok": true,
  "nothingFound": false,
  "blocker": null,
  "message": "Set up complete. First reading: Claude.",
  "lanes": [
    {
      "id": "claude",
      "displayName": "Claude",
      "tool": "Claude Code",
      "found": true,
      "detail": "Claude Code credentials file",
      "installed": true,
      "job": "loaded",
      "reading": "11% of the week used",
      "nextAction": null
    }
  ],
  "notes": []
}
```

| Field | Meaning |
| --- | --- |
| `ok` | `true` when at least one lane has a reading or an installed job. |
| `nothingFound` | `true` when no supported tool was found (exit code `3`). |
| `blocker` | Why Set up could not run at all, or `null`. |
| `lanes[].found`, `detail` | Whether the tool was detected, and what detection saw. |
| `lanes[].installed`, `job` | Whether the lane's background job is in place, and the job line: `loaded`, `skipped (needs Node.js)`, or `not needed` for lanes the app reads itself. |
| `lanes[].reading` | The first reading, or `null`. |
| `lanes[].nextAction` | What to do before running `setup` again, or `null`. |
| `notes` | Anything the command line could not do that the app does, such as registering the app's own login item. |

## JSON agent summary

`status --json` and the MCP tool `usage_status` return the same object.
`schemaVersion` is `1`. New fields can appear without a version change;
a removed or renamed field bumps the version. Every documented key is always
present, with `null` when a value is unknown. Run `usage-hud schema` for the
full JSON Schema (draft 2020-12).

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-10-01T20:54:01Z",
  "app": { "name": "Usage HUD", "version": "1.2.0" },
  "verdict": {
    "mode": "GO",
    "lane": "claude",
    "laneName": "Claude",
    "sentence": "Claude: clear to build."
  },
  "roomNow": {
    "lane": "grok",
    "laneName": "Grok",
    "window": "week",
    "usedPercent": 0,
    "pace": "on_pace",
    "resetsAt": "2026-10-08T02:09:29Z",
    "resetsIn": "6d 5h"
  },
  "lanes": [
    {
      "provider": "claude",
      "name": "Claude",
      "window": "week",
      "usedPercent": 11,
      "resetsAt": "2026-10-07T23:00:00Z",
      "resetsIn": "6d 2h",
      "pace": "on_pace",
      "status": "ON PACE",
      "forecastEmptyAt": null,
      "confidence": "measured",
      "source": "statusline event",
      "readingAgeSeconds": 444,
      "readingAge": "7m",
      "stale": false,
      "note": null,
      "windows": [
        { "window": "5h", "scope": null, "usedPercent": 12, "resetsAt": "2026-10-02T00:00:00Z", "resetsIn": "3h 5m", "pace": "room", "state": "live" },
        { "window": "week", "scope": null, "usedPercent": 11, "resetsAt": "2026-10-07T23:00:00Z", "resetsIn": "6d 2h", "pace": "on_pace", "state": "live" },
        { "window": "week", "scope": "Fable", "usedPercent": 0, "resetsAt": "2026-10-07T23:00:00Z", "resetsIn": "6d 2h", "pace": "on_pace", "state": "live" }
      ]
    }
  ]
}
```

The real output lists every plan you have turned on, with keys sorted
alphabetically.

### Fields

**`verdict`** is the panel's headline for your main plan: Claude when it is
shown, otherwise the plan with the tightest window.

| `mode` | Meaning |
| --- | --- |
| `GO` | Fresh reading, within budget, not running hot. |
| `WATCH` | Over the comfortable band, or running hot. Conserve or move work. |
| `STOP` | Nearly out or spent until reset. |
| `CHECK` | The reading is over 15 minutes old, or there is no data. Do not trust the number. |

When the main plan is under pressure, `sentence` names a plan with room, for
example `"Claude: running hot. Codex has room, 20% used."`

**`roomNow`** is the plan with the most room right now, or `null`. A plan
qualifies when its reading is fresh (under 30 minutes), it is not spent,
nearly spent, or tight on its 5-hour window, and it is under 60% used.
Local models never qualify.

**Lane fields**

| Field | Meaning |
| --- | --- |
| `window` | The headline window: `5h`, `week`, or `day`. A 5-hour window at 95% or more takes over the headline, because it decides whether the plan works right now. |
| `usedPercent` | Percent of that window used, or `null` when expired or unknown. |
| `resetsAt`, `resetsIn` | ISO 8601 reset time and the time left, such as `"2h 10m"`. |
| `pace` | `on_pace`, `running_hot`, `room`, `almost_spent`, `spent`, or `unknown`. |
| `status` | The panel's own words, such as `RUNNING HOT`, `5H TIGHT`, `IDLE`, `WAIT`. |
| `forecastEmptyAt` | When the window runs out at the current pace. Set when running hot. |
| `confidence` | `official` (provider-reported), `measured` (parsed from local provider events), `estimated`, or `unknown`. |
| `source` | Where the number came from, such as `official API` or `statusline event`. |
| `readingAgeSeconds`, `readingAge` | How old the reading is. |
| `stale` | `true` when the reading is over 30 minutes old or missing. |
| `note` | One plain sentence when something needs explaining. |
| `windows` | Every window the plan reports, each with its own `pace` and `state` (`live`, `expired`, `unknown`, `reset_passed`). `scope` names a model-limited window, such as Claude's Fable week. |

**How pace works.** Pace compares the share of the window you have used with
the share of time that has passed. More than 15 points ahead of the clock is
`running_hot`; more than 15 points behind is `room`; 90% used is
`almost_spent`; 99.5% is `spent`.

## MCP server

Run `usage-hud mcp`. The server reads JSON-RPC 2.0 messages from stdin, one
per line, and writes one reply per line to stdout. Nothing else goes to
stdout. It exits when stdin closes.

**Protocol versions.** The server is dual-era:

- Modern clients (MCP `2026-07-28`) send `_meta` with
  `io.modelcontextprotocol/protocolVersion` on each request. `server/discover`
  is supported, results carry `resultType` and server info, and `tools/list`
  carries `ttlMs` and `cacheScope`.
- Legacy clients send `initialize`. The server accepts `2025-11-25`,
  `2025-06-18`, `2025-03-26`, and `2024-11-05`, echoes the version you ask
  for, and otherwise answers with `2025-11-25`. Versions before `2025-06-18`
  get text content only, without `outputSchema` or `structuredContent`.

### Register it

Use the setup prompt, or run these yourself. Quote the path.

```sh
# Claude Code (user scope, all projects)
claude mcp add --scope user usage-hud -- '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' mcp

# Codex
codex mcp add usage-hud -- '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' mcp

# Gemini CLI (user scope; servers start only in trusted folders)
gemini mcp add --scope user usage-hud '/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD' mcp
```

Or edit the config file directly.

`~/.codex/config.toml`:

```toml
[mcp_servers.usage-hud]
command = "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD"
args = ["mcp"]
```

`~/.gemini/settings.json` or `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "usage-hud": {
      "command": "/Applications/Usage HUD.app/Contents/MacOS/CodexUsageHUD",
      "args": ["mcp"]
    }
  }
}
```

Restart open agent sessions after you register the server.

### Tools

All five tools are read-only (`readOnlyHint: true`, `openWorldHint: false`).
Only the first three tools declare an `outputSchema`: `usage_status`,
`which_plan_has_room`, and `lane_detail`.

| Tool | Input | Returns |
| --- | --- | --- |
| `usage_status` | none | The full agent summary. |
| `which_plan_has_room` | none | `verdict`, `roomNow`, `advice` (one sentence), and `usable` (fresh plans that are not spent, least used first). |
| `lane_detail` | `{"provider": "claude"}` | `{"lane": …}` for one plan. An unknown or untracked provider returns `isError: true` with a message. |
| `spend_summary` | none | API value (never billed), monthly plan cost, and value multiple, per plan and in total. |
| `recent_activity` | none | Sessions active today and in the last five hours: tool, project folder name, model, last activity, tokens, API value, burn rate, and the top burner. No prompts, file contents, or paths. |

Each result has two text blocks, a plain sentence and the serialized JSON,
plus `structuredContent`.

**When agents should call it.** Call `which_plan_has_room` before long,
expensive, or parallel work and before spawning subagents. If the verdict is
`WATCH` or `STOP`, tell the user and name the plan with room. If a lane says
`stale: true`, say the reading is old instead of treating it as current.

### Example session

Legacy handshake, then a call:

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1"}}}
← {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"instructions":"Read-only usage limits for the AI coding plans on this Mac …","protocolVersion":"2025-11-25","serverInfo":{"name":"usage-hud","title":"Usage HUD","version":"1.2.0"}}}
→ {"jsonrpc":"2.0","method":"notifications/initialized"}
→ {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"which_plan_has_room","arguments":{}}}
← {"id":2,"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"Claude: running hot. Move long or parallel work to Codex: 20% of its week used, room to spare, resets in 4d."},{"type":"text","text":"{\"advice\":…}"}],"isError":false,"structuredContent":{"advice":"Claude: running hot. Move long or parallel work to Codex: …","roomNow":{"lane":"codex",…},"verdict":{"mode":"WATCH",…},…}}}
```

Modern, stateless request (no handshake):

```json
→ {"jsonrpc":"2.0","id":"a1","method":"tools/call","params":{"name":"usage_status","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
← {"id":"a1","jsonrpc":"2.0","result":{"_meta":{"io.modelcontextprotocol/serverInfo":{…}},"content":[…],"isError":false,"resultType":"complete","structuredContent":{…}}}
```

Errors: an unknown tool returns JSON-RPC error `-32602`, an unknown method
`-32601`, a line that is not JSON `-32700`, and an unsupported modern
version `-32022` with the supported list in `data.supported`.

## Troubleshooting

- **"No readings yet" or exit code 3.** Run `usage-hud setup`, or open Usage
  HUD and click **Set up**. The per-lane next action says what is missing.
- **Every lane is stale.** The app or its background refresh is not running.
  Open Usage HUD; readings refresh within a few minutes.
- **The agent does not see the tools.** Restart the agent session. In
  Gemini CLI, trust the folder you are working in.
- **A plan is missing.** It is turned off in Usage HUD **Settings**, or its
  tool is not installed.

## Remove it

```sh
claude mcp remove --scope user usage-hud
codex mcp remove usage-hud
gemini mcp remove --scope user usage-hud
```

Then delete the two Usage HUD lines from `~/.claude/CLAUDE.md`,
`~/.codex/AGENTS.md`, and `~/.gemini/GEMINI.md` if you added them.
