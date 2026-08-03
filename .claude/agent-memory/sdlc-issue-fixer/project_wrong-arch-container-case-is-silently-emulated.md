---
name: wrong-arch-container-case-is-silently-emulated
description: A "wrong GOARCH binary" test case run under podman on this host is transparently emulated by binfmt_misc and adjudicates normally — use a wrong-GOOS binary (Mach-O vs ELF) to actually get ENOEXEC
metadata:
  type: project
---

Planting a `linux-amd64` ELF at the `linux-arm64` path inside a
`--platform linux/arm64` podman container on this Mac does **not** produce
an exec failure. The podman machine has qemu `binfmt_misc` handlers
registered, so the amd64 binary runs under emulation and returns a correct
decision, exit 0. The case looks like it passed while testing nothing.

The reliably-unrunnable case is a wrong **GOOS**: the darwin `Mach-O`
binary at a `linux-*` path (or vice versa) has no `binfmt_misc` handler
and gives `Exec format error` / `cannot execute binary file` → exit 126.
Cross-checked both directions: darwin-arm64 native and linux-arm64
container.

**Why:** the guardrails permission-gate's fail-closed wrapper (PR #217)
had to be verified against "present, exec bit set, but not runnable". A
wrong-GOARCH case would have silently under-tested it, and the emulation
is invisible unless you print the raw exit status per case.

**How to apply:** whenever a test needs a genuinely unrunnable binary,
swap the **OS**, not the architecture — or `head -c` truncate it, or use a
zero-byte file. Print the raw exit status of every doctored case rather
than only asserting the wrapper's verdict; that is what exposes an
"unrunnable" case that actually ran. See
[[negative-control-the-approved-snippet]] for the discipline this fell out
of, and [[real-build-verification-not-unit-tests]] for the wider habit.
