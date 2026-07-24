---
name: json-payload-via-file-not-echo
description: Feed JSON test payloads to hook scripts from a file, never via echo '...' — the Bash tool's shell expands \n inside single quotes and silently corrupts the JSON
metadata:
  type: reference
---

When exercising a hook script (or any stdin-JSON consumer) during a
review, write the payload to a file with the Write tool and redirect it
in (`script.sh < payload.json`). Do **not** build it with
`echo '{"prompt":"a\nb"}'`.

**Why:** the Bash tool's shell expands `\n` inside *single* quotes into a
literal newline. A literal newline inside a JSON string is invalid JSON,
so `jq` fails and the script emits its fallback placeholders. On PR #183
this looked exactly like a Critical "the script ignores every field"
bug — the acceptance-criteria payload returned `(unknown agent)` /
`(default model)` / `(no prompt)`. `od -c` on the piped payload showed
the raw newline and exonerated the script; re-running from a file gave
the correct output. Filing that as a finding would have been a fabricated
Critical.

**How to apply:** before believing any "the script dropped all its input"
result, run `... | od -c | head` on the payload you actually piped. If
you see a bare `\n` byte inside a JSON string, the harness mangled it —
re-test from a file. Repo `.claude/tmp/<slug>/` is the right sandbox;
the session scratchpad under `/private/tmp` is blocked by the
worktree-isolation guard for `jq` and friends.

Related: [[verify-bash-regex-in-real-bash]] — same class of defect, where
the tool's shell rather than the code under review is what actually
misbehaves.
