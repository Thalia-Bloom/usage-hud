# Release and source audit — 2026-11-09

The current public v1.3.4 UsageHUD.zip was downloaded and its SHA-256 matched
GitHub's published asset digest. Its live appcast Ed25519 signature verified
against the public key shipped in Resources/Info.plist. The appcast enclosure
points to the expected Thalia-Bloom/usage-hud HTTPS release location.

Sparkle is locked to 2.10.0. The upstream published advisories inspected on this
date affect versions through 2.9.5 and are fixed by 2.9.6 or earlier:
https://github.com/sparkle-project/Sparkle/security/advisories
The packaged app uses an HTTPS feed and a pinned public verification key.
The installer performs a deep strict signature verification and checks the
developer's Team ID before replacing an existing installation. Publishing or
rotating a signing key was not part of this audit.

The full native suite (392 tests) and script/check-mini.sh pass. Restricted
test runners can set BLOOM_TEST_TMPDIR to a writable fixture directory and
CODEX_USAGE_HUD_STATE_DIR to disposable state. Tests never need provider
credentials or a real signing identity. Source export tests still reject
untracked/private content, symlinks and secret-shaped strings. A full-history
Gitleaks scan found no candidates in this public repository.

The README now qualifies its privacy claim with the optional public badge.
This text change needs the maintainer's review before publication.

These are bounded source, test and current-release checks, not a guarantee
against unknown defects or compromise of the signing key or publisher account.
