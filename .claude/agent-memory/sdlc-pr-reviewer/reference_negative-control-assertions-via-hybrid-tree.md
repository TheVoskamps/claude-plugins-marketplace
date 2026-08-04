---
name: negative-control-assertions-via-hybrid-tree
description: To verify a fixer's "N of the new assertions fail against the previous code" claim, build a hybrid tree — git archive HEAD payload + git show <pre-fix-commit>:<path> over the one changed file — and run the branch suite there; the FAIL list should be exactly the claimed assertions.
metadata:
  type: reference
---

A fixer's negative-control claim ("four of the six new assertions fail
against the previous loop") is load-bearing: it is what makes the new
assertions worth having. The branch suite passing proves nothing about
whether they bite. Verify the claim with a hybrid tree — the branch's
payload with exactly one file reverted to the pre-fix blob:

```bash
H=.claude/tmp/hybrid; rm -rf "$H"; mkdir -p "$H"
git archive HEAD plugins/claude-vm/payload | tar -x -C "$H"
git show <pre-fix-commit>:plugins/claude-vm/payload/<changed-file> \
  > "$H/plugins/claude-vm/payload/<changed-file>"
bash "$H/plugins/claude-vm/payload/test/<suite>.sh" 2>&1 \
  | grep -E '^FAIL|passed, .* failed'
```

The pre-fix commit is the previous round's head, read off the PR's
commit list (`gh pr view --json commits`). On PR #228 this gave
"114 passed, 4 failed" against round-2's provisioner, and the four
FAILs were exactly the no-url mp-policy assertions the fixer named —
claim confirmed in one run, no worktree churn.

Pair it with a real-bash micro-check of the underlying mechanism when
the defect is a shell parsing fact (run under explicit `bash`, per
[[verify-bash-regex-in-real-bash]]): for #228,
`printf 'name\t\tboot\n' | { IFS=$'\t' read -r a b c; ... }` shows the
empty middle field collapsing (`b=boot`), and the parameter-expansion
split shows it preserved.

Related: [[baseline-suite-totals-via-git-archive]] (same
extract-and-run mechanics, aimed at delta totals instead of
negative controls).
