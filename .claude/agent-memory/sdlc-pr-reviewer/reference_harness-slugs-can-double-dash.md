---
name: harness-slugs-can-double-dash
description: The harness's project slugs rewrite EVERY non-alphanumeric cwd character to "-", so adjacent ones (e.g. "/.claude") produce consecutive dashes; verify any session-shape/slug pattern against the live ground truth (ls /tmp/claude-<uid>/ and ~/.claude/projects/) before accepting an "observed layout" claim.
metadata:
  type: reference
---

On PR #208 (issue #193) the pinned session-shape regex
`^(?:-[A-Za-z0-9]+)+/...` was derived from an "observed layout across 17
projects on two machines" claim in the issue's authoritative Design
section. The claim was falsifiable in one command: `ls /tmp/claude-501/`
showed real harness session dirs `-Users-edwinvoskamp--claude` and
`-Users-edwinvoskamp--config-macos-setup` (standard `scratchpad`/`tasks`
layout inside), which the regex cannot match — hidden-dir cwds slug
`/.` to `--`. The committed binary deferred instead of allowing them,
which was the PR's one High.

**How to apply:** whenever a permission-gate PR encodes a shape for
harness-provisioned paths (session dirs, project slugs, uuid layouts),
do not accept the PR/issue's empirical premise — list the live surfaces:

```bash
ls /tmp/claude-$(id -u)/          # real scratchpad slugs (the gate defers on the prefix root, reads inside allowed)
ls ~/.claude/projects/            # same slug scheme, more history
```

The slug alphabet is `[A-Za-z0-9-]` but dashes DO double (any adjacent
non-alnum pair: `/.`, a `/` followed by a space, `~` sequences). A
shape that requires `-[alnum]` after every dash silently misses every
hidden-directory project. Probe the committed binary with a synthetic
event for one of the real doubled-dash slugs to confirm.

Related: [[guardrails-binary-verification]] — the active gate is main's
binary, so ls/cat probes of /tmp may deny mid-review; the PR's own
binary run via `bash -c '<bin> < event.json'` is the reliable probe.
