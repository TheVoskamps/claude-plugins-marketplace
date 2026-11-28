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
- `git`, `yq` (mikefarah v4.54.3 or a later v4), `python3`, `gpg`,
  `vfkit`, `podman` and `tinyproxy`. On a clean host
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
  config file, as "Pinning the signing key" below describes. A launch
  with no pin aborts before any download.

Every missing piece fails a preflight up front, before any image build
or network fetch.

## Configuration

Config is four YAML files, all optional:

| Tier | Bake file | Boot file |
| --- | --- | --- |
| global | `~/.config/claude-vm/config-bake.yml` | `~/.config/claude-vm/config-boot.yml` |
| per-repo | `<repo>/.claude-vm/config-bake.yml` | `<repo>/.claude-vm/config-boot.yml` |

A **bake** file holds keys that change bytes in the guest image, and a
**boot** file holds keys applied at run time. `claude-vm-config-keys`, a
command the plugin puts on PATH, prints every key with the file it
belongs in, its type, whether it is a `list` or a `scalar`, and its
default. The launcher enforces the file for some keys, and one of those
written in the wrong file aborts the launch, naming the file.

The effective config is all four files merged. A `list` key takes the
entries of both tiers. A `scalar` key takes the per-repo value over the
global one, except one whose type is a map, which merges per entry with
the per-repo entry winning.

The guest image is keyed on the raw bytes of the bake files, so editing
a bake file rebuilds the image on the next launch and editing a boot
file never does. Nothing is normalized before hashing, which makes a
bake file's trailing newline the way to force a rebuild: add or remove
it and the next launch builds a fresh image.

With no config at all the launcher runs on built-in defaults.
`/claude-vm-config-global` writes the global pair from those defaults
and `/claude-vm-config-repo` writes a per-repo pair holding only the
keys the repo overrides; both leave an existing file alone unless you
choose to merge. `payload/config-bake.example.yml` and
`payload/config-boot.example.yml` show what populated entries look like.

### What the launcher refuses in a config file

The launcher checks the four files as you wrote them, before it merges
them, and aborts the launch on anything it would otherwise misread:

- A value of the wrong type for its key. A boolean key takes a bare
  `true` or `false`, so a quoted `"true"` aborts; a string or path key
  refuses a bare YAML boolean, which has to be quoted to mean the
  string; an enumeration key takes one of its listed values, never
  several joined with `|`; and an empty map (`{}`) is no value for a
  key that takes a single value. The message names the key. A key left
  out or left valueless is unset and takes its default, and so is a
  key that takes a single value written as `""`.
- A `claude.plugins.enabled` entry whose value is not a boolean.
- A YAML alias (`*name`) anywhere in a file. The launcher does not
  resolve aliases; write the value out in full.
- More than one YAML document in a file.
- A key nested under a parent that is not a map, such as `repo: 5`
  where `repo.mount` is expected.
- A newline in any string, a map key included, other than an `env.set`
  value.

### Pinning the signing key

The launcher downloads `claude` on the host and accepts it only when
its release manifest is signed by the key whose fingerprint you pinned.
A valid signature by any other key in your keyring is rejected, and
with no pin nothing is fetched at all. Import the key and read its
fingerprint:

```bash
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc | gpg --import
gpg --fingerprint claude-code
```

Confirm that fingerprint against the published value through a channel
other than the download itself, then pin it in a boot file:

```yaml
claude:
  signing_key_fingerprint: "AAAA BBBB CCCC DDDD EEEE  FFFF 0000 1111 2222 3333"
```

The fingerprint is compared case-insensitively with spaces ignored, so
the `gpg --fingerprint` form pastes in as it stands. A verified binary
is cached by version, and a later launch that resolves to a cached
version neither downloads nor verifies the binary again.

### Extra mounts

Every entry under `mounts` in a boot file is shared **read-write**, and
there is no read-only option: the hypervisor's file sharing cannot
enforce one, and the guest session runs as root. A write in the guest
lands on the host path immediately, with no copy-back step, no review
and no undo — `repo.copy_back` governs the repo alone. Each mount opens
the VM's isolation for that one path, so mount only what the session
should be able to change. An entry that sets `mode:` — `mode: ro`, say
— aborts the launch rather than leaving you believing a share is
read-only.

A single file can be a mount source, and in-place writes to it reach the
host file. Two things differ from a directory mount:

- The guest cannot **replace** the file. `git config`, `sed -i` and most
  editors write a temporary file and rename it over the original, and
  on a single-file mount that rename fails with "Resource busy",
  leaving the file unchanged. Mount the file's directory instead when
  the guest needs to replace the file rather than edit it in place.
- The file has to be on the same volume as the runs root that "Where
  state lives" names. A file on another volume aborts the launch and
  names its directory as the mount to declare instead.

The launcher shares a single file through a hard link inside the run's
directory. That link outlives the session, so the file's contents stay
on disk under the run directory after you delete the original, until
you remove the run directory too.

## Skills

- `/claude-vm` — the launch skill: what each config key means, the
  launcher's behavior, and everything a launch does from image build to
  exit.
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
— lives under one host-wide runs root, never inside your repo, as
"Where state lives" below lays out. A run
whose launcher exited keeps its clone on disk until reaped: a normal
exit discards it, but a launcher killed outright (`kill -9`, a crash, a
closed terminal) leaves it, and its VM is stopped by a watcher the
launcher left behind. Run `claude-vm-cleanup`, a second command on the
same PATH, to reap every such run across all your repos at once: it
stops any of the run's processes still running, removes the clone and
credential files, and keeps the worktree so the companion skills still
find the run. It tells a live run from a dead one by a lock the kernel
releases on the launcher's death, so it never touches a running VM.

## Where state lives

Your config files are the only thing under `~/.config/claude-vm/`.
Everything the launcher writes for itself sits under one state root:
`$XDG_STATE_HOME/claude-vm` when that variable is set,
`~/.local/state/claude-vm` otherwise, or wherever you point
`CLAUDE_VM_STATE_DIR`. Under it:

- `images/` — the built guest images.
- `cache/` — the verified `claude` binaries, one per version.
- `runs/<run-id>/` — each launch's run directory, for every repo on the
  host. `CLAUDE_VM_RUNS_DIR` moves this one directory on its own.
- `logs/<run-id>/` — each launch's console capture, proxy logs and
  egress capture, kept apart from the run directory so reaping a run
  leaves its diagnostics.

Images and cached binaries can be deleted at any time: the next launch
rebuilds the image and fetches `claude` again. A run directory is not
rebuilt, because it holds the run's result.

The launcher migrates nothing into the state root. An `images/`,
`cache/` or `logs/` directory under `~/.config/claude-vm/`, and a run
directory under a repo's `.claude/tmp/`, is read by nothing —
`claude-vm-cleanup` included — and is yours to delete.

The `guardrails` plugin's permission gate treats the config home and
the state home as separate roots. A carve-out that lists `claude-vm/**`
under the config home alone opens your config files and nothing under
the state root, so list it under the state home as well when a
session's tool calls should read the cached binary or the images. A
launch from your own terminal, and anything inside the guest, is not a
tool call and needs no listing.

## When the launcher tells you to log in again

The Keychain can hold a login whose tokens are empty while your host
sessions go on working from tokens held in memory. A guest booted from
that entry would come up at "Not logged in", so the launcher checks the
tokens first and aborts when they are empty. Repair the entry on the
**host**: run `claude` and then `/login`, or restart Claude Code, and
launch again. For a launch with `--as <name>`, the `claude` to run is
`CLAUDE_CONFIG_DIR=$HOME/.claude.<name> claude`. Never run `/login`
inside the guest instead — a login retried there can revoke your other
live sessions.

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
Each of those refusals names the account and the missing piece. Nothing
is copied in place of a missing file and no launch falls back to another
account, so a guest never runs one account's identity with another's
login. Log the account in with
`CLAUDE_CONFIG_DIR=$HOME/.claude.<name> claude` and launch again.

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
