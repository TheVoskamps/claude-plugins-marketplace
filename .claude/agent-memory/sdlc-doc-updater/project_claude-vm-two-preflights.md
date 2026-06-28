---
name: claude-vm-two-preflights
description: claude-vm launcher has TWO distinct preflights; docs must describe both separately or the trust-path one gets missed.
metadata:
  type: project
---

The `claude-vm.sh` launcher runs two separate preflights, in order, and
the docs (payload/README.md, skills/claude-vm/SKILL.md) must describe
both — they are easy to conflate.

- **Trust-path preflight** (`claude_vm_preflight_trust_path`): runs
  FIRST, before image build / network / Keychain. Checks gpg-on-PATH,
  `claude.signing_key_fingerprint` pinned, that fingerprint present in
  the gpg keyring, and python3-on-PATH. Each failure prints exact
  remediation.
- **Dependency preflight** (`claude_vm_preflight_toolchain`): runs
  after, checks the VM toolchain (gvproxy/vfkit/podman/tinyproxy).

**Why:** a prior doc pass documented only the dependency preflight and
omitted the trust-path one, and left python3 off the verified-cache /
credential host-requirement lists. The trust-path gate is the one that
saves a cold boot from building an image + 3 network fetches before
aborting on a knowable condition.

**How to apply:** when claude-vm preflight or host-requirement code
changes, check BOTH preflights are reflected, and that python3 + gpg
are both listed as required host tools (python3 for credential
selection in lib/credential.sh, gpg for the verified cache).
