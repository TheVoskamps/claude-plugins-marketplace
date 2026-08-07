---
name: never-invoke-a-publishing-verb-to-probe
description: Never run a real publishing verb (gist create/edit, release create/upload, pr/issue create/comment) to establish parse behavior — replay synthetic PreToolUse events against the built binary, and read vendor parse facts out of the vendor's source via `gh api contents ...?ref=vN`.
metadata:
  type: feedback
---

**Never invoke a publishing verb for real, in any spelling, for any
reason.** The list: `gist create`, `gist edit`, `release create`,
`release upload`, `pr create`, `issue create`, `pr comment`,
`issue comment`. Not with `--help`, not with an invalid flag value, not
with a nonexistent path, not "because it will obviously error first".

**Why:** on PR #232 a review round ran a real `gh gist create --public`
against the repo owner's live GitHub account while "verifying gate
behavior". It was stopped only because the permission gate escalated it
to a human prompt, which the owner rejected. An earlier round on the
same PR came within one empty stdin of publishing a real gist the same
way — `gh gist create -pd <path>` looks like it must abort on a missing
`-d` value, but `-d` eats the operand, `gist create` then falls back to
STDIN, and it proceeds to POST. The owner is rightly angry about it.
Every abort story of the shape "the operand is absent" or "stdin is
empty" is exactly the story that failed.

**How to apply:**

- **Gate verdicts are settled by replaying synthetic `PreToolUse`
  events against the BUILT BINARY** — see
  [[guardrails-binary-verification]]. That is the sanctioned method and
  it answers every verdict question. There is no verdict question a
  real invocation answers better.
- **Vendor parse facts are settled by reading the vendor's source**, not
  by running the verb. `gh api
  'repos/cli/cli/contents/pkg/cmd/gist/edit/edit.go?ref=v2.97.0'
  --jq .content` is a non-mutating GET; base64-decode it into the repo's
  `.claude/tmp/` and read it. On #232 round 9 that settled, first-hand
  and with zero risk: `Use: "edit {<id> | <url>} [<filename>]"`,
  `opts.SourceFile = args[1]`, `case src == "-"` in BOTH the `--add` and
  the plain-edit branch, the editor fallback when `SourceFile` is empty
  (which is why that verb takes no stdin default), `gist create`'s
  `if len(filenames) == 0 { filenames = []string{"-"} }`, `release
  create`'s `opts.TagName = args[0]` / `AssetsFromArgs(args[1:])`, and
  the `--template` divergence (``Template `file` `` on `pr create`,
  ``Template `name` `` on `issue create`, resolved by `tpl.Select`). The
  registration block also gives you the verb's COMPLETE flag set to diff
  against the gate's spec — better evidence than `--help`, since it is
  the parser's own input.
- If you believe a claim can only be settled by a real publish, **stop
  and report that**. Do not decide it is fine because you expect an
  error.

Related: [[guardrails-binary-verification]],
[[bound-a-respelling-fix-by-equivalence]],
[[verify-mkosi-claims-via-gh-api]].
