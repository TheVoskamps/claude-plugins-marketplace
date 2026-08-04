---
name: buildvcs-stamp-is-primary-clone-head
description: a Go binary cross-compiled inside a subagent worktree gets vcs.revision from the PRIMARY CLONE's HEAD, never your branch, so the stamp can never prove a committed binary is current -- prove it with go tool nm symbol-table identity plus a behavioral discriminator
metadata:
  type: project
---

A subagent worktree's `.git` is a **file** (a `gitdir:` pointer), and Go's
buildvcs root walk only accepts a `.git` **directory**, so it walks past
the worktree and finds the primary clone's real `.git`. Every binary you
cross-compile in a worktree is therefore stamped with whatever the
**primary clone** had checked out — normally `main` — regardless of what
your branch is at.

**Verified twice on PR #217.** A rebuild at branch HEAD `9adefec`
(rebased onto `7fdb33e`) stamped `vcs.revision=7fdb33e` with
`vcs.time` equal to `7fdb33e`'s commit time to the second; a later
rebuild onto `72eaaa7` stamped `72eaaa7`. The same mechanism explains
the binary the round was sent to fix: it read `vcs.revision=c8cc5d6`
because that was the primary clone's HEAD the day it was built, not
because anyone built it from an old branch.

**So `vcs.revision` is not staleness evidence and not provenance
evidence.** A reviewer (or you) reading a stale-looking stamp is reading
the primary clone's checkout history. Do not "fix" it — `-buildvcs=false`
would drop the metadata block the sibling committed binaries carry, and
there is no flag that makes Go stamp your worktree.

**Prove the binary is current two ways instead:**

1. **Symbol-table identity.** Rebuild a *different* platform's binary from
   the same tree into `.claude/tmp/`, then `go tool nm` both it and the
   committed binary for that platform and `cmp` the outputs. Byte-identical
   symbol tables (PR #217: 4798 symbols, darwin-arm64) prove your tree's
   source is the source upstream's committed binaries were built from, and
   therefore that the platform binary only *you* ship was built from it too.
   This is the README's own recipe; it works because the VCS stamp lives
   outside the symbol table.
2. **A behavioral discriminator per upstream PR.** Run the old binary
   (`git show <pre-rebase-sha>:<path>` into `.claude/tmp/`) and the new one
   side by side on an event that each upstream change flips, and show the
   flip. On #217: #208's containment deny Reason gained a
   "harness scratchpad" clause (absent → present), and #222's
   `deleteIssueFieldValue` allowlist entry turned a
   `gh api graphql -f query='mutation { … }'` **ask** into an **allow**.

**The cheapest discriminator on a fix round is the branch's own previous
binary.** Redirect `git show HEAD:<committed-binary-path>` into a file
under `.claude/tmp/`, `chmod +x` it, and you have the pre-fix build with
no rebuild and no container. Write one synthetic `PreToolUse` JSON event
with the `Write` tool and feed it to both binaries by input redirect. On
PR #227 the same event read `allow` from the pre-fix binary and `deny`
from the new one, which proves the *committed* artifact carries the
round's change — something `go test` cannot show. Pair it with a
rebuild into `.claude/tmp/` plus `shasum -a 256` against each committed
binary: with `-trimpath` all three reproduce byte-identically, so equal
hashes prove the other platforms' binaries came from the same tree.

**Build the discriminator container to match the guest.** The first
attempt used bare `debian:bookworm-slim`, which has no `git`, and *every*
Engine B path decision fell back to the same fail-closed `ask` — the old
and new binaries printed byte-identical output and the probe proved
nothing. `apt-get install -y git` (an ephemeral container layer, neither a
host nor a project-dependency install) makes the deny Reasons real and the
discriminator crisp. Pair with `--platform linux/arm64` per
[[project_wrong-arch-container-case-is-silently-emulated]].

**How to apply:** any round that rebases a branch shipping committed
binaries must rebuild them from the rebased tip — see
[[project_rebase-absorbs-an-identical-version-bump]] for the version half
of the same obligation — and must report provenance with the two proofs
above rather than quoting `go version -m`'s `vcs.revision`. Quote the rest
of `go version -m` (`GOOS`/`GOARCH`/`-trimpath=true`/`CGO_ENABLED=0`/Go
version/dep hashes), which *is* meaningful, and say plainly why the
revision line is not.
