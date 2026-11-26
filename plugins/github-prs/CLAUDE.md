# github-prs

`bin/lib/github-prs-common.sh` — read when writing or changing a verb.
Kernel: report every failure through a catalogue entry; a verb's own
exit statuses sit in 2–125; use no construct the ERR trap cannot see.

- No SKILL.md carries a `gh` procedure; the skill runs its script.
- `gp_gh` adds `--hostname` to every `api` call, and `GH_HOST` is never
  exported.
- A body is read through `gp_read_body`, never through `gh`.
- A verb that changes a PR re-reads it and exits 3 when the change did
  not land.
- A body reaches `gh` by file path or on stdin, never as a command-line
  argument.
- The PR-reference parser `gp_parse_pr` has a twin in the `issues`
  plugin carrying the same repository grammar; a change to that grammar
  edits both.
- Every verb is GitHub-only; no other source-control backend is added.
- `pr-create` reads its two repo-config keys, `default-pr-target-branch`
  and `issue-link-prefix`, by an inline parse of those lines.
