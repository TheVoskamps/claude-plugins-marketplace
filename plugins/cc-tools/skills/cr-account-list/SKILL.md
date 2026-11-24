---
name: cr-account-list
description: List the Claude Code accounts on this machine and the state of each account's symlinks into ~/.claude — linked, missing, wrong target, dangling, a real file or directory, or not whitelisted.
allowed-tools: Bash(cr-account-links list)
---

# List the accounts and their links

```text
/cc-tools:cr-account-list
```

No arguments. Run this and print its stdout as it stands:

```bash
cr-account-links list
```

On a non-zero exit, relay its stderr verbatim and stop.
