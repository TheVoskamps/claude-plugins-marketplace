---
name: apt-keyring-extension-vs-content
description: apt >= 2.x infers armored-vs-binary OpenPGP keyring format from the FILE EXTENSION, not content; a binary key saved as .asc silently loads as an empty keyring even though gpgv accepts the same bytes
metadata:
  type: project
---

Root-caused in a live guest (issue #106 review, PR #174 round 6): claude-vm's
`render_apt_source` (build-time, `podman-mkosi.sh`) and
`render_apt_source_boot` (boot-time, `build-guest-image.sh`) both
hard-named the fetched `packages.apt_sources` key `<name>.asc` regardless of
what `curl -fsSL <key_url>` actually returned. GitHub serves
`githubcli-archive-keyring.gpg` as RAW/BINARY OpenPGP (confirmed via `od`:
starts with the literal packet-header bytes `0x99 0x02`), not
ASCII-armored text. bookworm's apt 2.6.1 loaded that binary content under
the `.asc` name as an EMPTY keyring — `apt-get update` failed with
`NO_PUBKEY <id>` / "repository is not signed" on every boot, permanently
blocking `update_at_boot`. The identical bytes verified fine under
`gpgv --keyring <path>` (gpgv DOES sniff content); apt's own `signed-by=`
loader does not — it dispatches on extension.

**The fix** (in both functions, kept in lockstep): after the `curl` fetch,
read the first 15 bytes with `head -c` (not the `read` builtin — `read`
stops at the first embedded newline, which lands well inside 15 bytes for
binary data) and `case` on whether they start with the literal
`-----BEGIN PGP` header (bracket-expression `[[:space:]]` for the space, not
a backslash-escape — a `\\ ` double-escape is required inside
podman-mkosi.sh's unquoted `<<INNER` heredoc, but the existing Test 20
extraction harness (`sed 's/\\\$/$/g'`) only unescapes `\$`, not `\\`, so a
literal `\\ ` broke that extraction as invalid case-pattern syntax
standalone — `[[:space:]]` sidesteps needing any backslash escaping at
all and is portable across both the escaped and unescaped heredoc twins).
Armored → keep/rename to `.asc`; anything else → rename to `.gpg`. The
operator-pinned `signed-by=P` case (repo line already declares an exact
path) is EXEMPT from the rename — that path is emitted verbatim in the
`.list` line, so renaming the file would desync the emitted `signed-by=`
from what's actually on disk. Only the function's own DEFAULT
`<name>.<ext>` naming is sniff-driven.

**How to apply**: any future `render_apt_source`-family change must keep
this rename BEFORE the `have_key=1` line composition that reads
`keyring_write_path`/`keyring_runtime_path` (build-time) or `keyring_path`
(boot-time) — those variables must carry the FINAL extension by the time
the `signed-by=` line is built. See
[[real-build-verification-not-unit-tests]] for why this needed a real
mkosi build (not just unit tests) to surface, and
[[claude-vm-inspect-raw-image-with-debugfs]] for the inspection technique —
though note the render happens in mkosi's `mkosi.sandbox/` BUILD-TIME
staging tree, which is NEVER copied into the final rootfs image (that's
mkosi's designed behavior, not a bug) — to see the rendered keyring file
you must inspect the STAGE dir (podman-mkosi.sh's `mktemp -d
"${TMPDIR:-/tmp}/claude-vm-mkosi.XXXXXX"`) before its EXIT trap deletes it,
not the built `guest.raw`.
