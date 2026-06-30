---
name: claude-vm-config-global
description: Interactively create the global claude-vm config at ~/.config/claude-vm/config.yml from the resolved defaults (cpus 2, mem 4096, bundled-tinyproxy proxy default, podman-mkosi provisioner, egress.allow incl. api.anthropic.com, claude.version). Idempotent — detects an existing file and offers to merge or leave rather than clobber.
---

# claude-vm-config-global

You are running the `/claude-vm-config-global` skill. Your job is to
create the **global** claude-vm config file at
`~/.config/claude-vm/config.yml` (expand `~` to the user's home
directory) from the resolved defaults.

This file is the machine-wide layer of claude-vm's two-tier config (the
per-repo layer at `<repo>/.claude-vm/config.yml`, written by
`/claude-vm-config-repo`, overrides it). The
config surface, layering semantics, and key meanings are documented in
the sibling `claude-vm` skill (`skills/claude-vm/SKILL.md`) and the
annotated `payload/config.example.yml`. This skill writes the global
layer with the resolved defaults rather than the example's illustrative
placeholders.

It is the first slice of the claude-vm completion work: everything
downstream resolves against this global config, so writing it correctly
comes first.

## Idempotent — detect and offer, never clobber

This skill is **idempotent**. Before writing anything it checks whether
`~/.config/claude-vm/config.yml` already exists:

- **If it does not exist**: this is the create path. Propose the full
  default file, get approval, write it.
- **If it already exists**: **do not clobber it.** Read it, show the
  user what is there, and offer two choices:
  1. **Leave** the existing file untouched (the default, safe choice).
  2. **Merge** the resolved defaults in for any keys the existing file
     is missing, preserving every key the user already set.

  Never overwrite a key the user already set on the "merge" path, and
  never delete a key. A merge only *fills gaps*. If the existing file
  already has every key the defaults provide, report that it is already
  complete and leave it untouched.

Writing the file requires explicit user approval in every case.

## Resolved defaults

These are the values this skill writes, drawn from the parent issue's
verified analysis. They deliberately **override** the illustrative
values in `payload/config.example.yml`.

| key | default | rationale |
|-----|---------|-----------|
| `cpus` | `2` | RAM-bound sizing; vCPUs time-slice, 2 covers git/build/test bursts |
| `mem` | `4096` | the real ceiling — RAM is committed, ~8–12 VMs fit at 4 GB on a 64 GB host |
| `proxy.cmd` | omitted (bundled tinyproxy launcher is the launcher-side default) | tinyproxy is the chosen forward proxy; the launcher runs the bundled `payload/proxy/tinyproxy-launch.sh` when `proxy.cmd` is unset |
| `proxy.port` | `3128` | matches the launcher default |
| `proxy.host_alias` | `192.168.127.254` | the gvproxy host alias the guest reaches the proxy on |
| `provisioner` | `podman-mkosi` | the bundled provisioner: mkosi in a throwaway rootless podman container |
| `egress.allow` | `api.anthropic.com`, `github.com`, `claude.ai`, `downloads.claude.ai` | `api.anthropic.com` is required for Remote Control; the rest cover git + claude install/fetch |
| `claude.version` | `stable` | which `claude` binary the host-side verified cache fetches |
| `claude.renderer` | omitted (claude's own default) | terminal renderer on the interactive console: `classic` \| `fullscreen` \| unset |

Notes on the forward-looking keys:

- **`proxy.cmd` is omitted from the written config.** tinyproxy is the
  chosen forward proxy, and the launcher already defaults to the bundled
  `payload/proxy/tinyproxy-launch.sh` when `proxy.cmd` is unset (it reads
  the egress allowlist from `$CLAUDE_VM_EGRESS_ALLOWLIST` and binds
  `$CLAUDE_VM_PROXY_PORT`). So the resolved global config leaves
  `proxy.cmd` unset rather than pinning a brittle invocation. Write a
  `proxy.cmd` only if the user wants to override the bundled launcher;
  any override must read `$CLAUDE_VM_EGRESS_ALLOWLIST` rather than a
  hand-maintained list baked into the command.
- **`provisioner: podman-mkosi`** names the bundled provisioner that
  produces the raw EFI-bootable Linux guest. `build-guest-image.sh`
  already defaults to it (`payload/provisioners/podman-mkosi.sh`) when
  `CLAUDE_VM_IMAGE_PROVISIONER` is unset; writing the key documents the
  intent. The env var still overrides the bundled default.
- **`claude.version: stable`** selects which `claude` binary the
  host-side GPG-verified cache fetches. It is consumed by
  `payload/lib/claude-cache.sh`: the host resolves the channel/pin to a
  concrete version, downloads that version's GPG-signed manifest,
  verifies the signature against the operator's pinned key,
  checksum-verifies the binary, caches it keyed on the version, and
  mounts it RO into the guest. `stable` (default) tracks the conservative
  stable channel; `latest` tracks the latest channel; a dotted version
  like `2.1.172` pins one concrete release with no channel resolution.
- **`api.anthropic.com` must stay in `egress.allow`.** Remote Control is
  outbound-HTTPS-only and connects to the Anthropic API on 443; dropping
  this host breaks every in-guest Remote Control session. Treat it as
  load-bearing, not optional.
- **`claude.renderer` is omitted by default.** It selects the in-guest
  claude's terminal renderer on the interactive console (`classic` →
  `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`; `fullscreen` →
  `CLAUDE_CODE_NO_FLICKER=1`); unset passes nothing so claude uses its
  own default. Both renderers work over the byte-pipe console, so leaving
  it unset is a fine default — write a value only if the user asks for
  one. An unrecognized value aborts the launch.

## Steps

Follow these in order. Do not write the file until the user has
explicitly approved the proposed content.

### Step 1: Resolve the target path

Expand `~` to the user's home directory:

```text
~/.config/claude-vm/config.yml
```

Respect `XDG_CONFIG_HOME` if set: the path is
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-vm/config.yml`, matching the
launcher's `CLAUDE_VM_GLOBAL_CONFIG` default in
`payload/lib/config.sh`. The parent directory may not exist yet; the
`Write` tool creates it.

### Step 2: Detect an existing config

Check whether the target file exists.

- **Absent** → create path. The proposed content is the full default
  file from Step 3.
- **Present** → idempotent path. Read its full contents, parse the YAML,
  and show the user what is already there. Then ask (via
  `AskUserQuestion`) whether to:
  - **Leave it untouched** (recommended default), or
  - **Merge** the resolved defaults into any keys it is missing.

  On "leave", stop here and report that nothing was changed. On "merge",
  compute the gap-fill (Step 3, merge variant) and continue to Step 4.

### Step 3: Compose the proposed content

**Create variant** (no existing file): the full default file is:

```yaml
# claude-vm global config (machine-wide defaults).
#
# The per-repo layer at <repo>/.claude-vm/config.yml overrides this for
# scalars and unions with it for lists (egress.allow, mounts). See the
# claude-vm skill (skills/claude-vm/SKILL.md) and
# payload/config.example.yml for the full schema and layering rules.
#
# NO SECRETS HERE. The host claude.ai OAuth credential is mounted into
# the guest at runtime by the launcher; it is never read from or written
# to this file.

cpus: 2
mem: 4096

proxy:
  # proxy.cmd is intentionally OMITTED: tinyproxy is the chosen forward
  # proxy, and the launcher defaults to the bundled tinyproxy launcher
  # (payload/proxy/tinyproxy-launch.sh) when proxy.cmd is unset. It reads
  # the egress allowlist from $CLAUDE_VM_EGRESS_ALLOWLIST and binds
  # $CLAUDE_VM_PROXY_PORT. Set proxy.cmd only to override that default.
  port: 3128
  host_alias: 192.168.127.254

# The bundled provisioner that produces the raw EFI-bootable Linux guest
# image: mkosi running inside a throwaway rootless podman container.
# build-guest-image.sh already defaults to it when
# CLAUDE_VM_IMAGE_PROVISIONER is unset; this key documents the intent.
provisioner: podman-mkosi

egress:
  allow:                # outbound hosts permitted through the proxy
    - api.anthropic.com # REQUIRED for Remote Control (outbound 443)
    - github.com
    - claude.ai
    - downloads.claude.ai

claude:
  version: stable       # which claude binary the host-side GPG-verified
                        # cache fetches: stable (default) | latest | <pinned>
  # renderer: classic   # terminal renderer on the interactive console:
                        # classic (no alt-screen) | fullscreen | unset
                        # (claude's own default). Omitted by default.
```

> On `proxy.cmd`: the bundled tinyproxy launcher
> (`payload/proxy/tinyproxy-launch.sh`) is the launcher-side default, so
> the resolved global config leaves `proxy.cmd` unset. The launcher runs
> the bundled script when `proxy.cmd` is absent; the script renders a
> tinyproxy conf from `$CLAUDE_VM_EGRESS_ALLOWLIST` and binds
> `$CLAUDE_VM_PROXY_PORT`. If the user wants their own forward proxy,
> capture their `proxy.cmd` verbatim — the only hard requirement is that
> it honor the launcher-provided allowlist (`$CLAUDE_VM_EGRESS_ALLOWLIST`)
> rather than a baked-in one.

**Merge variant** (existing file): start from the existing parsed YAML
and add **only** the keys from the default file that are absent. Keep
every existing key and value verbatim, including any the user
customized and any this skill does not recognize. For list keys
(`egress.allow`), union the default entries in (do not drop the user's
extras, do not duplicate). Render the merged result preserving the
user's existing comments where practical.

### Step 4: Show the proposed file and get approval

Render the **full proposed file** exactly as it will land on disk. For
the merge variant, also show a short summary: which keys this run adds,
which it preserves untouched.

Then ask explicitly:

> Write `~/.config/claude-vm/config.yml` as shown? (y to proceed, or
> tell me what to change)

Wait for explicit approval. If the user asks for changes, adjust and
re-render here.

### Step 5: Write the file

On approval, use the `Write` tool to write the full content in one
call. The parent directory is created if needed.

### Step 6: Verify and summarize

After the `Write`, re-read the file and confirm it parses as YAML and
contains the expected keys (`cpus: 2`, `mem: 4096`, `proxy.port`,
`provisioner: podman-mkosi`, `egress.allow` including `api.anthropic.com`,
`claude.version`). `proxy.cmd` is intentionally absent — the launcher
defaults to the bundled tinyproxy launcher when it is unset. This is
content verification — `Write` already errors if the bytes did not land;
the re-read confirms the *intended content*.

Report back:

- The absolute path written (or "left untouched" / "already complete").
- For a merge, which keys were added vs. preserved.
- A reminder that the per-repo layer
  (`<repo>/.claude-vm/config.yml`, written by `/claude-vm-config-repo`)
  overrides scalars and unions lists, and that no secret is ever written
  here.

## Hard constraints

- **Idempotent.** Never clobber an existing config. Detect it, and offer
  leave (default) or gap-fill merge. A merge fills gaps only — it never
  overwrites or deletes a key the user set.
- **`api.anthropic.com` stays in `egress.allow`.** It is required for
  Remote Control. Never drop it from the defaults.
- **No secrets in this file.** The host OAuth credential is mounted at
  runtime, never written to config.
- **Never write without explicit approval** in Step 4.
- **Write exactly one file**: `~/.config/claude-vm/config.yml`. This
  skill touches no repo, edits no `.gitignore`, and runs no git
  commands.
