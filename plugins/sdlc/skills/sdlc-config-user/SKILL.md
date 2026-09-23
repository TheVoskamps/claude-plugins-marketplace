---
name: sdlc-config-user
description: Interactively create or merge-update the repo user sdlc config, `<repo-root>/.sdlc/user-config.yml` (tier 3 — this user, this repo, never committed), and add it to the repo's tracked `.gitignore`.
---

# sdlc Config: Repo User

## Run the contract's writer steps against tier 3

You are writing tier 3, the repo user file. Read
`skills/lib/sdlc-config.md` for its path, its keys, and the writer
steps, and run those steps against that file. That contract is the only
statement of them; this skill does not restate them.

## Abort outside a repository

Abort, saying so, when `git rev-parse --show-toplevel` fails: there is
no repository to write into.

## Keep the file out of every commit

The file must never be committed, so the repo's tracked `.gitignore`
lists it. Before the writer's approval step, read
`<repo-root>/.gitignore` and check whether it already ignores the file.
A plain `git check-ignore` also honours `core.excludesFile` and
`.git/info/exclude`, which never leave this machine, so borrow the git
directory of an empty repository in the session scratchpad and turn the
global file off; only the working tree's own `.gitignore` files are
then consulted. From `<repo-root>`:

```bash
git init -q <scratchpad>/sdlc-ignore-probe
git --git-dir=<scratchpad>/sdlc-ignore-probe/.git --work-tree=. \
  -c core.excludesFile=/dev/null \
  check-ignore --no-index -q .sdlc/user-config.yml
```

Exit status `0` means it is already ignored, and `.gitignore` is left
alone. Otherwise, plan to append this line, under a one-line comment
saying the file is one user's private sdlc config, at the end of
`.gitignore` — or to create `.gitignore` holding it:

```text
.sdlc/user-config.yml
```

Show that change beside the merged config file in the writer's approval
step, and make both on the one yes. When `.gitignore` is absent or
empty, write it with `Write`. Otherwise append with `Edit`, leaving
every other line where it is. The check runs every time, so repeated
runs add the line at most once.

The `.gitignore` change is tracked and the user's to commit. Write the
config file and `.gitignore`, and nothing else.
