---
name: git-range
description: Fetch origin, confirm a branch on origin still points at the head you are about to read, and print that head's merge base with a base branch plus its own commits since a previous head — never a commit the base gained. Read-only apart from the fetch.
---

# Git Range

Answer the three questions a reader of a branch asks before it trusts
what it reads: has the branch moved since I took its head, where does it
leave its base, and which of its commits are new since the head I read
last time. One fetch, one check, one range.

The range is the branch's **own** commits. A rebase that advances the
base makes every commit the base gained reachable from the new head and
unreachable from the previous one, so a plain
`<prev-head>...<head>` reads those upstream commits as the branch's;
this skill bounds the range by the base, and drops every commit whose
patch an earlier head already carried. A clean rebase therefore yields
no commit at all, and a conflict-resolving one yields exactly the
commits whose patch changed.

## Invocation

```text
/git-tools:git-range --base <base-ref> --head-ref <head-ref> --head <sha> [--prev-head <sha>]
```

- `--base <base-ref>` (required): the base branch's name on `origin`,
  such as a PR's `baseRefName`.
- `--head-ref <head-ref>` (required): the branch's name on `origin`,
  such as a PR's `headRefName`.
- `--head <sha>` (required): the full SHA you expect `origin/<head-ref>`
  to point at, such as a PR's `headRefOid`.
- `--prev-head <sha>` (optional): the full SHA of the head read last
  time. Omitted, the range starts at the merge base, so it is the whole
  branch.

## Execution

Run the bundled script, spelled as a bare name, from inside any
checkout whose `origin` is the branch's repository:

```bash
git-range --base <base-ref> --head-ref <head-ref> --head <sha> [--prev-head <sha>]
```

It runs `git fetch origin` once and changes nothing else.

## Output and exit status

- **Exit 0** — `origin/<head-ref>` is `<sha>`, and stdout is the range,
  one tab-separated line each:

  ```text
  merge-base\t<sha>
  commit\t<sha>
  ```

  The `merge-base` line comes first, and is the merge base of `--head`
  and `origin/<base-ref>`. Then one `commit` line per commit of
  `git rev-list --right-only --cherry-pick <prev>...<head> ^origin/<base-ref>`,
  in that command's order, newest first, where `<prev>` is
  `--prev-head` or else the merge base. No `commit` line means the
  range is empty.
- **Exit 1** — a command failed, or something the range needs is
  missing: the fetch failed, `origin/<base-ref>` or
  `origin/<head-ref>` does not exist, the head and the base share no
  merge base, or `--prev-head` is not a commit in this repository —
  for instance a previous head that a force-push left unreachable and
  the fetch did not bring back. Stderr names which; stdout is empty.
- **Exit 2** — a usage error, including a `--head` or `--prev-head`
  that is not a full SHA; nothing was run.
- **Exit 3** — `origin/<head-ref>` is not `<sha>`: the branch moved
  since you took its head. Stderr names both SHAs; stdout is empty.
  Re-read the head before you read the branch again.
