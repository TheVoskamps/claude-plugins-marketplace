---
name: personalize-auto-mode
description: "Rewrite an existing Claude Code autoMode block against this machine's facts: re-point the names, organizations, SSO profiles, repositories and paths in the environment paragraphs from ~/.config/auto-mode-tools/facts.yml, then write the live settings.json after a diff, an approval, a backup and a validation pass."
---

You are running the `/auto-mode-tools:personalize-auto-mode` skill.
Take the `autoMode` block already in the user's Claude Code
`settings.json` and re-point it at this machine's reality: the names,
organizations, SSO profiles, repositories and paths that appear inside
the environment paragraphs.

This is **seeded-only, not fully derived**. The block being rewritten
is the seed and carries the reasoning; the facts file supplies what is
specific to this machine. After this skill runs, `settings.json` is the
living artifact and the facts file is expected to go stale. Re-running
the skill is a start-over, not an increment.

## The facts file

`$XDG_CONFIG_HOME/auto-mode-tools/facts.yml`, defaulting to
`~/.config/auto-mode-tools/facts.yml`.

Read it and check `schema-version`. It must be `1`. On any other
value, **abort**, naming the file and the version expected:

```text
<facts-path> has schema-version <found>; this skill reads
schema-version 1. Aborting rather than reading it as if it matched.
```

If the file does not exist, stop and tell the human where to write it,
showing the schema below. Do not invent facts and do not read them out
of the block you are rewriting.

The schema, with placeholder values — nothing identity-specific ships
in this plugin:

```yaml
schema-version: 1

identity:
  display-name: "Ada Lovelace"
  github-login: alovelace
  email: ada@example.org

bots:
  - display-name: "Claude for Ada"
    github-login: claude-for-alovelace
    email: ada+claude@example.org

organizations: [ExampleOrg, OtherOrg]

sso-profiles: [example-dev, example-prod]

public-repositories:
  - ExampleOrg/public-thing

scratch-globs: ["~/scratch/**"]
worktree-globs: ["**/.claude/worktrees/**"]

notes: |
  Free prose for what the keys above cannot enumerate.
```

The split between the structured keys and `notes:` is deliberate. The
structured keys are the enumerable facts: they appear **verbatim**
inside the environment paragraphs and must be reproduced exactly, since
free prose invites dropping a list member or paraphrasing a profile
name with nothing to catch it. `notes:` is for what the keys cannot
enumerate.

`identity` and each `bots` entry carry the same three key names, so
read one shape twice rather than two shapes. A `bots` entry is one
record because a rule matching a bot generally needs its login and its
email to agree.

## Procedure

Write the same file `/auto-mode-tools:tune-auto-mode` writes, so carry
the same protections, in this order:

1. **Read** the live `~/.claude/settings.json`. If it has no `autoMode`
   block, stop and say so — this skill rewrites a block, it does not
   author one.
2. **Produce the rewritten block** in a scratch `CLAUDE_CONFIG_DIR`
   copy of that file, never in the live file.
3. **Show the human the diff** and get an explicit approval.
4. **Take a timestamped backup** of the live file, and tell the human
   its path.
5. **Verify** the candidate passes
   `CLAUDE_CONFIG_DIR=<scratch> claude auto-mode config` without error.
6. **Only then** write the live file.

If either the approval or the validation does not come, leave the live
file untouched and say where the scratch copy is.

## What a rewrite is

The environment entries are dense paragraphs, not templates, so
personalizing one is a **rewrite** rather than a token substitution.
The structured keys give you exact lists to place; `notes:` and the
existing prose give you the rest to reason from. A paragraph that
mentions an organization the facts file does not list is a paragraph to
re-reason about, not a paragraph to leave standing with a stale name in
it.

Keep the block to `environment`, `allow`, `soft_deny` and `hard_deny`.

## Independence

This skill does not depend on `/auto-mode-tools:tune-auto-mode` and
**does not read the ledger**. It writes nothing to the state directory.
It must work on an `autoMode` block that has never been tuned. There is
no ordering contract between the two skills.
