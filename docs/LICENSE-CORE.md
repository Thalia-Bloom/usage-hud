# Shipped product vs Bloom packaging

Usage HUD lives in one GitHub repo. Two trees serve different jobs:

| Tree | Folders | Role |
|------|---------|------|
| **Shipped / run** | `Sources/`, `Tests/`, `bin/`, `script/`, `launchd/`, `Resources/` | Mac menu-bar app, helpers, install templates, release and Mini checks. This is what the **50% cut** and **line budget** apply to. |
| **Bloom packaging** | `site/`, `store/` | Public site and checkout worker for Bloom ops; not part of the Mac product tarball and **not** counted toward the cut target. |
| **Install dependency** | `hooks/` | The budget guard is copied by `make install` and must be in the source distribution. |
| **Private operations** | `docs/ops/` | Internal support automation; excluded from the source distribution. |

## Line budget

`script/count-shipped-lines.js` measures the shipped tree (text sources only; skips binaries such as icons and DMG art).

`script/test-line-budget.js` runs in `check-mini` and fails if shipped lines grow above the recorded ceiling. The **target** after cut PRs is about **half** of the Oct 2026 baseline (~19.5k lines), with the same user-visible product.

## Open source

The Mac product tree is **MIT** (`LICENSE` at repo root). `script/test-shipped-open-source.js` fails on Bloom-private paths, hostnames, keys or secret shapes in the shipped dirs plus root `README.md`, `INSTALL.md`, and `LICENSE`. Public product URLs (`hud.thaliabloom.com`, `support@thaliabloom.com`) are allowed.

Install from an extracted source archive: see **Install from source** in `README.md` (`make install`).

## Source distribution

`make source` exports committed `HEAD` to `dist/UsageHUD-source.tar.gz` using an explicit file allowlist. It includes build inputs, runtime helpers, fixtures, product tests, the hook installed by Make, the MIT license and public integration docs. The appcast template remains for local packaging. Marketing renders, hosted services, operational support scripts/tests and private runbooks stay out. Exported text passes the same hygiene check before the archive is written; findings name the file and rule, never matched content.

`make test-mini` runs product tests in an explicitly marked source distribution and retains the site/store checks in the full repository. The tree identifier in `SOURCE-EXPORT.json` is provenance, not a build or signing receipt. An archive is ready for publication only after it has been extracted and checked. These packaging exclusions do not fulfill the 50% code-reduction target.
