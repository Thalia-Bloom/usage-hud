<p align="center"><img src="media/panel-dark.png" width="420" alt="Usage HUD panel: one bar per provider with reset times and confidence labels"></p>

# Usage HUD

**One menu-bar meter for every AI subscription you code with.** Codex, Claude, Gemini, Grok and local models. See how much of each 5-hour and weekly window is used, when it resets, and whether the number can be trusted.

**[Buy for $9](https://hud.thaliabloom.com/?utm_source=github&utm_campaign=mk-006)** · one-time · personal license · updates through 1.x · 14-day refund by email

<p align="center"><img src="media/demo.gif" width="640" alt="Usage HUD demo"></p>

## What you see

- One bar per provider, the reset time, and a freshness stamp. Turn a provider off without deleting its history.
- A confidence label on every number: official, high, medium, or manual, with a one-line reason.
- Local models: exact token counts from your Ollama logs, today and the rolling seven days.

## Built on trust

- Everything is collected on your Mac. Nothing is sent to us. There is no account and no telemetry.
- Claude numbers come from the same usage endpoint Claude Code's own `/usage` panel reads. The HUD never refreshes or changes your Claude Code token.
- Codex numbers come from your local Codex session logs, labeled as local telemetry, not billing.
- `codex-usage-doctor` tells you in plain English whether each number is reliable and why.

## Requirements

Apple silicon Mac, macOS 14 or later, and Node.js 18 or later. For each lane you want: Claude Code signed in (plus Python 3, which the Xcode Command Line Tools include), Codex CLI, Antigravity CLI (agy) for Gemini, Grok CLI, or Ollama. Set up checks all of this and names anything missing.

## Install

Unzip, move to Applications, open. The app is signed with a Developer ID and notarized by Apple, so macOS opens it without a warning. Then click Set up in the panel: it finds your coding tools, hides the ones you don't have, and collects the first reading. No terminal. Details in [INSTALL.md](INSTALL.md).

## FAQ

**Why did my weekly usage jump?** The weekly cap is separate from the 5-hour window and can move from other Claude clients on the same plan. [Why weekly usage jumped](https://hud.thaliabloom.com/why-weekly-usage-jumped/).
**ccusage stopped tracking Claude?** ccusage reads local logs. Usage HUD reads the same usage endpoint Claude Code's `/usage` panel reads. [When ccusage stops tracking Claude](https://hud.thaliabloom.com/ccusage-stopped-tracking-claude/).
**Where do I buy?** [hud.thaliabloom.com](https://hud.thaliabloom.com/). $9, one time, 14-day refund. Want to check your numbers first? [claude-usage-check](https://github.com/Thalia-Bloom/claude-usage-check) is free and MIT.
**Is there a free alternative?** [CodexBar](https://github.com/steipete/CodexBar) is free and covers more providers. If it already does the job, you do not need this.
**Is the source available?** Not yet. This repository is the product page and the install guide.
**Refunds?** Email support@thaliabloom.com within 14 days.
**License?** Personal. Use it on the Macs you own.

Bloom Web Services · 30 N Gould St, Ste N, Sheridan, WY 82801 · support@thaliabloom.com
