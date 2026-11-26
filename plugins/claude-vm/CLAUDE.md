# claude-vm

`plugins/claude-vm/docs/rules/bash32.md` — read when writing or reviewing
  shell here. Kernel: a construct that differs on bash 3.2 makes a guard
  fail open rather than stop the launch.
`plugins/claude-vm/docs/rules/config-gates.md` — read when adding a config
  key or a load-time gate, or when reading a `@tsv` record. Kernel: the
  merge prunes empty spellings three ways, so presence is never read off a
  merged document.
`plugins/claude-vm/docs/rules/seam-sweeps.md` — read when changing what
  crosses the host→guest seam or inserting a boot-launcher phase. Kernel:
  sweep every restatement across the plugin, not the files the diff touched.
`plugins/claude-vm/docs/rules/claude-vm-verification-playbook.md` — read
  before asserting what a claude-vm launch, image build or guest does.
  Kernel: probe the real hypervisor, kernel and launcher; a green
  fixture-driven suite has measured the fixture.

No secret is written to config, `run.env` or the claude binary cache.
`claude` reaches the guest only through the verified cache; never add a
lower-trust fallback.
Never split a TSV record with `IFS=$'\t' read`.
A launcher logic change bumps `LAUNCHER_LOGIC_REV`.
A new trap-chain link repeats `claude_vm_stop_podman_machine`.
