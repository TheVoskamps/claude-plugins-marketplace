# auto-mode-tools changelog

## 0.1.0 — 2026-08-21

Adds two independent skills for working on the `autoMode` block of a
Claude Code `settings.json`.

- `/tune-auto-mode` runs a complete critique of a large block.
  `claude auto-mode critique` caps its answer at 4096 tokens, so the
  skill captures that request through a local loopback sink, which never
  contacts the API, and replays it in the current session, which has no
  such ceiling. You accept or reject findings round by round, against a
  scratch copy of your settings. Your decisions accumulate in a ledger
  that later rounds read.
- `/personalize-auto-mode` rewrites an existing block against this
  machine's facts, read from `~/.config/auto-mode-tools/facts.yml`.

Both skills write the live `settings.json` only after a backup and a
validation pass.
