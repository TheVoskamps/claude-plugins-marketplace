---
name: cr-account-add
description: Create a Claude Code account directory, ~/.claude.<name>, if absent, and each whitelisted symlink it lacks, keeping every real file or directory in it.
disable-model-invocation: true
allowed-tools: Bash(cr-account-links add:*)
---

# Add an account's links

```text
/cc-tools:cr-account-add <name>
```

Run this with the one name in `$ARGUMENTS`, without asking first, and
print its stdout as it stands:

```bash
cr-account-links add <name>
```

On a non-zero exit, relay its stderr verbatim and stop.
