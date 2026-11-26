# claude-vm

Runs an interactive Claude Code session inside an isolated Linux
micro-VM on macOS, with the repo you launched from made available to
the guest and every egress, mount and resource knob set by YAML config.

## Why

A Claude Code session on the host runs with the host's filesystem,
network and credentials in reach. This plugin moves the session into a
throwaway guest instead: the guest's outbound traffic goes through a
forward proxy that only passes the hosts you allow, the guest sees the
repo and the extra mounts you declare, and by default it works on a
clone of your repo rather than the live working tree. Each launch boots
its own copy of an immutable base image, so two sessions running at once
share no state and nothing a session did survives into the next one.

You stay logged in the way you already are: the launcher takes the
host's live claude.ai login from the macOS Keychain and seeds the
guest's identity from your host `~/.claude.json`, so the in-guest
session comes up onboarded and logged in with no token variable and
no browser paste. Those are the sources of a launch without `--as`;
`--as <name>` launches as another account logged in on the host, as
"Launching as a named account" below describes. The `claude` binary the
guest runs is fetched and GPG-verified on the host against a signing-key
fingerprint you pin, and shared into the guest read-only.

## Prerequisites

- macOS. The launcher reads the Keychain with `security` and boots the
  guest with Apple's virtualization stack; it refuses to run elsewhere.
- Logged in to Claude Code on the host: run `claude` once and complete
  the claude.ai login. The launcher aborts if the Keychain holds no
  credential or `~/.claude.json` carries no usable identity. A launch
  with `--as <name>` needs that account logged in instead:
  `CLAUDE_CONFIG_DIR=$HOME/.claude.<name> claude`.
- `git`, `yq` (mikefarah v4+), `python3`, `gpg`, `vfkit`, `podman` and
  `tinyproxy`. On a clean host
  `brew install yq git gnupg vfkit podman tinyproxy` covers them in one
  go; the launcher itself names each missing piece with its own
  install hint rather than that line. `tinyproxy` is
  only needed by the bundled default proxy; a custom `proxy.cmd` brings
  its own. `podman` is what a guest-image build runs, and its formula
  is also where the launcher finds `gvproxy`, which need not be on
  PATH. No started podman machine is required: the launcher starts one
  when a build needs it and stops it again afterwards.
- The claude-code signing key imported into your gpg keyring and its
  fingerprint pinned as `claude.signing_key_fingerprint` in a boot
  config file. A launch with no pin aborts before any download; the
  abort message carries the import and pin commands.

Every missing piece fails a preflight up front, before any image build
or network fetch.

## Configuration

Config is four YAML files, all optional:

| Tier | Bake file | Boot file |
| --- | --- | --- |
| global | `~/.config/claude-vm/config-bake.yml` | `~/.config/claude-vm/config-boot.yml` |
| per-repo | `<repo>/.claude-vm/config-bake.yml` | `<repo>/.claude-vm/config-boot.yml` |

A **bake** file holds keys that change bytes in the guest image —
packages baked in, apt sources, plugins installed into the image,
environment literals written into it. A **boot** file holds keys
applied at run time — cpus and memory, the egress allowlist, mounts,
the proxy, the repo mount strategy, environment variables forwarded
from the host, and the claude version and signing-key pin. The
placement is the classification, and only some misplacements are
diagnosed: a `claude.plugins` sub-key in the wrong file, or `env.copy`
or `env.files` in a bake file, aborts the launch. Any other key in the
wrong file is silently ignored — `cpus: 8` in a bake file merges
without complaint and the guest boots with the default. The effective
config is the union of all four, with per-repo scalars overriding
global ones and lists unioned.

The guest image is keyed on the raw bytes of the bake files, so editing
a bake file rebuilds the image on the next launch and editing a boot
file never does.

With no config at all the launcher runs on built-in defaults.
`/claude-vm-config-global` writes the global pair from those defaults
and `/claude-vm-config-repo` writes a per-repo pair holding only the
keys the repo overrides; both leave an existing file alone unless you
choose to merge. The full key schema is in the `claude-vm` skill, and
`payload/config-bake.example.yml` and `payload/config-boot.example.yml`
are annotated starting points.

## Skills

- `/claude-vm` — the launch skill: the config schema, the launcher's
  behavior, and everything a launch does from image build to exit.
- `/claude-vm-config-global` — interactively write the global bake and
  boot pair from the resolved defaults.
- `/claude-vm-config-repo` — interactively write the per-repo bake and
  boot pair, holding only what this repo overrides on top of the global
  config.
- `/claude-vm-diff` — read-only: show what a run changed in its guest
  worktree versus the local source.
- `/claude-vm-apply-local` — apply a run's guest-worktree changes onto
  the local source working tree; never pushes.
- `/claude-vm-apply-remote` — push a run's committed guest-worktree
  changes to the remote, only with explicit approval and never with
  force.

## A typical run

The entry point is the `claude-vm` command, which the plugin puts on
PATH for the Bash tool. Run it from a real terminal, anywhere inside
the repo you want the guest to work on:

```bash
claude-vm [--as <name>] [claude args...]
```

With no config on the host, the first launch runs on built-in defaults
and tells you to run `/claude-vm-config-global` to write the global
pair; it also builds the guest image, and later launches reuse that
image until a bake file changes. Before boot the launcher clones your
repo into the run's own directory — or, under `repo.mount: live`,
shares the live working tree instead. Once the guest boots, your
terminal becomes the guest's console and the session is the ordinary
Claude Code REPL, running inside the VM on that clone or share.

Arguments after `claude-vm` reach the in-guest `claude` unchanged,
except for a leading `--as <name>`, which `claude-vm` takes for itself,
and a `--name`: whenever you pass none, the launcher adds one
made of your arguments — or a date stamp when there are none —
followed by the repo name. A `--name` you pass yourself is kept as is.
`claude.remote_control: true` in a boot file additionally adds
`--remote-control` unless your command line already carries it.

When the session exits the launcher copies the worktree's changes back
onto your local source by default. Set `repo.copy_back: none` to keep
that manual, and use `/claude-vm-diff`, `/claude-vm-apply-local` and
`/claude-vm-apply-remote` to inspect and extract the run's work.

Every run's directory — its worktree, guest-image clone and `run.meta`
— lives under one host-wide runs root, `runs/` under the state root
(`~/.local/state/claude-vm/` unless `XDG_STATE_HOME` or
`CLAUDE_VM_RUNS_DIR` says otherwise), never inside your repo; the run's
logs and egress capture sit beside it under `logs/<run-id>/`. A run
whose launcher exited keeps its clone on disk until reaped: a normal
exit discards it, but a launcher killed outright (`kill -9`, a crash, a
closed terminal) leaves it, and its VM is stopped by a watcher the
launcher left behind. Run `claude-vm-cleanup`, a second command on the
same PATH, to reap every such run across all your repos at once: it
stops any of the run's processes still running, removes the clone and
credential files, and keeps the worktree so the companion skills still
find the run. It tells a live run from a dead one by a lock the kernel
releases on the launcher's death, so it never touches a running VM.

## Launching as a named account

```bash
claude-vm --as <name> [claude args...]
```

A leading `--as <name>` launches the guest as the host Claude Code
account whose config directory is `$HOME/.claude.<name>` — the account
you run on the host as `CLAUDE_CONFIG_DIR=$HOME/.claude.<name> claude`.
A name holds only ASCII letters, digits, `_` and `-`, and is not
`backup`.

Every host source follows from that directory, and no config key
selects an account:

- the login comes from the Keychain item whose service is
  `Claude Code-credentials-<h>`, where `<h>` is the first 8 lowercase
  hex characters of the SHA-256 of the directory's absolute path — the
  item Claude Code itself keeps for a session run with
  `CLAUDE_CONFIG_DIR` set to that directory;
- the identity comes from the directory's `.claude.json`;
- the working rules the launcher copies into the guest come from the
  directory.

Without `--as` those are the `Claude Code-credentials` item,
`~/.claude.json` and `~/.claude`. The account comes from `--as` alone:
a `CLAUDE_CONFIG_DIR` set in the shell you launch from decides nothing.

`--as` counts only as the first argument, because the account has to be
known before the launcher reads any host state. Anywhere later it
reaches the in-guest `claude` like any other argument. It is not part
of the session name the launcher computes.

Before any image build or boot, the launcher refuses an invalid name, a
missing account directory, a `.claude.json` that is missing or carries
no usable identity, and a Keychain item that is missing or unusable.
Each refusal names the account and the missing piece. Nothing is copied
in place of a missing file and no launch falls back to another account,
so a guest never runs one account's identity with another's login. Log
the account in with `CLAUDE_CONFIG_DIR=$HOME/.claude.<name> claude` and
launch again.

## Limits

- macOS hosts only.
- Interactive sessions only. The launching terminal is the guest's
  console; a headless one-shot run is not what the plugin does, and the
  console has no live window resize.
- The guest's network is confined. It reaches only the egress hosts the
  config allows, and the plugin never pushes a run's work to a remote on
  its own.
- One trusted path for `claude`: a signature or checksum that fails to
  verify aborts the launch rather than falling back to a less-verified
  install.
- No secret is written to config. The login credential and identity
  seed travel to the guest on a transient mount that is shredded on
  exit, and third-party API keys are forwarded by name from the host
  environment, never by value.
- A legacy single-file `config.yml` is not read; the launcher stops
  with migration instructions instead.

Implementation detail — the launcher, its libraries, the image build,
the proxy and the test suite — lives in
[`payload/README.md`](payload/README.md).
