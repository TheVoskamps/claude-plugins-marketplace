# claude-vm config key meanings

What each claude-vm config key means, and what the launcher rejects. The
set of keys, the file type each may sit in, its type, whether it merges
as a list or a scalar, and its default come from `claude-vm-config-keys`,
which prints the launcher's own key table, one key per line, as the
tab-separated fields key, file (`bake`, `boot` or `both`), type, `list` or
`scalar`, and default. Run it rather than recalling the schema; this file
states none of those fields.

## The two file types

A key that changes bytes in the guest `.raw` image lives in a **bake**
file; a key applied at run time lives in a **boot** file. The image's
cache key and filename are a whole-file, raw-byte hash of the bake files,
so editing a bake file — list order, whitespace, even only its trailing
newline — rebuilds the image on the next launch, and editing a boot file
never does. A repo that ships a `.claude-vm/config-bake.yml` gets its own
image, named `guest+global<hash>+<reponame>-<repohash>.raw`; a repo
without one shares `guest+global<hash>.raw`.

A key whose file is `both` may sit in either file type and means
something different in each; its entry below says what each file type
does with it.

Placement is enforced for a `claude.plugins` sub-key whose file is `bake`
or `boot`, and for an `env` sub-key whose file is `boot`: one written into
the file type that never reads it aborts the launch, naming the file.
That is a presence test, so a misplaced sub-key written empty —
valueless, `[]`, `""` or `{}` — aborts exactly like a populated one.
Never write a placeholder sub-key into the file it does not belong in.

No config file holds a secret. The host's claude.ai OAuth credential is
extracted from the macOS Keychain at launch, and a third-party API key
reaches the guest by name through `env.copy` or by path through
`env.files`, never by value.

## Layering

The launcher merges the two bake files into one document and the two boot
files into another, by each key's shape:

- A **scalar** in a repo file overrides the global value; the default
  applies only when neither tier sets it.
- A scalar whose type is a **map** merges repo-over-global per key, so a
  repo can change one entry without restating the global map. A per-repo
  `env.set` name that repeats a global one silently wins, by design.
- A **list** is the union of global and repo entries, de-duplicated,
  global entries first. A repo file cannot remove a global entry; that
  edit belongs in the global file.

`apt_sources` and `claude.marketplaces` dedupe by `name` across both file
types. The same name with differing content — `{repo, key_url}` or `url` —
aborts the launch rather than letting one shadow the other.

A legacy single-file `config.yml` in either tier is not read: the launcher
aborts with a migration message, and the keys it held split into the
bake/boot pair by the rule above.

## VM resources and image

- `cpus` and `mem` (MiB) size the VM. Memory is the real ceiling: it is
  committed, while vCPUs time-slice.
- `guest_image`, when set, names the image to boot, used verbatim and
  exempt from identity derivation. Unset, the image path is derived from
  the bake-file hash as above.
- `image.root_headroom_mb` is the free space, in MiB, the guest root
  filesystem is sized to above its base content, so the boot-time apt
  working set and session growth do not hit ENOSPC.

## Repo

- `repo.mount` is how the repo reaches the guest: `clone` makes a
  `git clone --no-hardlinks` worktree in the run dir and mounts that
  read-write, leaving the live tree and `.git` untouched; `live` mounts
  the live repo read-write, more convenient and less isolated.
- `repo.copy_back` is what happens after the guest exits in clone mode:
  `local` copies the guest's changes back to the local source, and `none`
  leaves extraction to `/claude-vm-diff`, `/claude-vm-apply-local` and
  `/claude-vm-apply-remote`.

## Proxy and egress

- `egress.allow` lists the hosts the guest may reach through the forward
  proxy. It must include `api.anthropic.com`: Remote Control and the
  in-guest claude reach the Anthropic API on 443. `github.com` is needed
  for git and for an `owner/repo` marketplace shorthand, and `claude.ai`
  and `downloads.claude.ai` for a cold claude fetch.
- `proxy.cmd` is the forward-proxy launch command; a default given as a
  relative path is resolved against the payload directory, where the
  bundled tinyproxy launcher lives. An override must read the allowlist from the
  file `$CLAUDE_VM_EGRESS_ALLOWLIST` names and bind
  `$CLAUDE_VM_PROXY_PORT`, never carry a hand-maintained list of its own.
- `proxy.port` is the port the proxy binds, and `proxy.host_alias` the
  gvproxy host address the guest reaches it on.

## Mounts

`mounts` adds virtio-fs shares beyond the repo. Each entry takes a
`source:` (a host directory or a single file; a leading `~` expands to
`$HOME`), a `tag:`, and an optional absolute `path:`, the guest
mountpoint, defaulting to `/mnt/<tag>`.

Every extra mount is read-write and pierces the VM isolation boundary for
that path: guest writes land on the host path live, with no copy-back and
no undo. There is no read-only option and no `mode:` key — vfkit's
virtio-fs device has no read-only export and the guest session is root —
so a config that sets `mode:` aborts the launch. Never offer a mount of
anything the operator would mind an autonomous agent rewriting.

A single-file `source:` is hard-linked into a per-entry directory in the
run dir and bind-mounted onto `path:`, so writes reach the host file. A
hard link cannot cross volumes, so a file on another volume than the run
dir aborts the launch. The kernel refuses `rename(2)` onto a file bind
mount, so such a mount takes in-place edits but not the
write-a-temp-then-rename pattern `git config`, `sed -i` and most editors
use; mount the containing directory when the guest must replace the file.

The launcher aborts at config load on:

- a missing `source:` or `tag:`;
- a `source:` that is not on the host, or a directory `source:` whose
  path carries a `,`, which vfkit reads as a further device option;
- a `tag:` that is reserved (`repo`, `runconfig`, `claudebin`,
  `claudecreds`), outside `[A-Za-z0-9._-]`, repeated, `.` or `..`, or
  beginning with `-`, since the tag is also a path component and a bare
  argument to the guest's `mount` (`...`, `a..b` and `a-b` pass);
- a `mode:` key;
- a `path:` that is relative, carries a `..` segment, overlaps one of
  claude-vm's own guest mountpoints — on one, above one (`/mnt`, `/`) or
  inside one (`/mnt/repo/sub`) — shadows a guest OS path, or duplicates
  another entry's mountpoint.

Those checks run on the `path:` after repeated slashes, a trailing slash
and `.` segments are collapsed, so a respelling (`/./etc`, `/mnt/./repo`)
cannot slip past them. They run over the merged global and repo list, so a
per-repo entry can collide with a global one, and a diagnostic numbers the
entry by its position in that merged list, global entries first.

The guest OS paths are `CLAUDE_VM_GUEST_SYSTEM_PATHS` in
`payload/lib/config.sh`, and the rule is by shape: a directory source may
not land on, above or inside one — offer `/mnt/<tag>`, `/srv` or `/opt` —
while a single file may not land on or above one and may sit inside only
`/root`, `/home` or `/tmp`. So `path: /root/.gitconfig` for a file is
legal and `path: /root` for a directory is not. The guest checks again at
boot and skips, with a warning, a mountpoint that exists and is non-empty
or a single-file target that exists at all.

## Packages

- `packages` in a bake file is baked into the image, present with no
  boot-time network. In a boot file it is installed at boot, through the
  proxy, before claude starts, so a package that changes often stays fresh
  without a rebuild. A failed boot install warns and continues.
- `update_at_boot` runs `apt-get update` and `apt-get upgrade` at boot,
  through the proxy, before claude starts; a failure warns and continues.
- `add_apt_uris_to_allowlist` decides whether `deb.debian.org`,
  `security.debian.org` and every `apt_sources` host join the guest's
  egress allowlist. `auto` adds them only when boot-time apt work is
  configured — a nonempty boot `packages` list or `update_at_boot` true —
  so an all-baked config leaves package repos unreachable; `always` adds
  them regardless, so an in-session `apt-get install` works. Every derived
  addition is logged.
- An `apt_sources` entry is `{name, repo, key_url}`: `key_url` is fetched
  into a keyring and `repo`, a raw apt one-line source that may carry its
  own `[options]` block, is added signed by that key. A block that already
  pins `signed-by=` is kept verbatim. In a bake file the source is
  rendered into the image at build time; in a boot file it is rendered
  into the guest's live `/etc/apt` at boot, for a boot-time install,
  skipping any name already baked.
- A null or empty `packages` entry is dropped rather than installed as a
  package named `None`.

## The claude binary

- `claude.version` selects the `claude` binary the host fetches, verifies
  and caches: `stable`, `latest`, or a pinned version such as `2.1.172`.
- `claude.signing_key_fingerprint` is the claude-code signing key the
  manifest signature must verify under. It is required: unset, the launch
  aborts before fetching anything. It is compared case-insensitively with
  spaces stripped, so the `gpg --fingerprint` output pastes verbatim. The
  operator imports the key with
  `curl -fsSL https://downloads.claude.ai/keys/claude-code.asc | gpg --import`,
  reads it with `gpg --fingerprint claude-code`, and verifies that
  fingerprint out of band before pinning it.

## The session

- `claude.renderer` picks the in-guest terminal renderer: `classic` sets
  `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`, `fullscreen` sets
  `CLAUDE_CODE_NO_FLICKER=1`, and unset leaves claude's own renderer. Both
  work over the console; a value outside its type aborts the launch.
- `claude.remote_control`, when `true`, adds `--remote-control` to the
  in-guest claude unless the arguments already carry it, and a
  date-stamped `--name` such as `Jul10-14:30` when none was given. A
  user-supplied `--name` is never overridden. A value outside its type
  aborts the launch.

## Permissions

- `claude.permission_mode` becomes the guest `settings.json`'s
  `permissions.defaultMode`; a value outside its type aborts the launch.
  `bypassPermissions` treats the VM as the isolation boundary, with the
  deny list as backstop, and `default` prompts as claude does on a host.
- `claude.permissions.allow`, `.ask` and `.deny` are copied verbatim into
  the guest `settings.json`'s `permissions`. The deny list is enforced
  even under `bypassPermissions`.

The guest's permission and plugin surface comes from the claude-vm config
alone; the host's `~/.claude/settings.json` is never read.

## Marketplaces and plugins

- A `claude.marketplaces` entry is `{name, url}`. `name` is mandatory and
  must match the marketplace's own manifest name: it is what a
  `plugin@marketplace` ref resolves against, and an entry with a url and
  no name aborts the launch. Prefer an explicit `https://` url: the
  launcher derives the guest's marketplace egress host from it, and an
  `owner/repo` shorthand yields none, so `github.com` must then stay in
  `egress.allow` by hand. In a bake file the marketplace must register
  during the image build or the build aborts, so its url has to be
  reachable from the build container. In a boot file it only has to be
  reachable from the guest: a guest-local path such as `/mnt/repo`, or a
  private source needing host-only credentials, belongs there, where a
  build that cannot add it warns and the guest adds it at boot.
- `claude.plugins.bake` lists `plugin@marketplace` refs installed into the
  image at build time; a failed install fails the build.
- `claude.plugins.install_at_boot` lists refs the guest installs at boot,
  blocking, before claude starts.
- `claude.plugins.update_at_boot` refreshes the marketplaces and updates
  the installed plugins at boot. It is the freshness path for baked
  plugins, which are frozen at build time.
- `claude.plugins.add_marketplace_uris_to_allowlist` is the marketplace
  counterpart of `add_apt_uris_to_allowlist`. Under `auto` the marketplace
  hosts join the allowlist only when boot-side plugin work can run: a
  nonempty `install_at_boot`, a marketplace declared in a boot file and
  not in a bake file, or `update_at_boot` true with any marketplace
  configured.
- `claude.plugins.enabled` maps a plugin ref to its enabled state and
  overrides, per ref, the rule that every baked and boot-installed ref is
  enabled; `false` ships a plugin installed but disabled. Every key must
  name an installed ref and every value must fit the type, or the launch
  aborts.

Baking a plugin with a compiled hook, such as `guardrails@thevoskamps`,
needs nothing in `packages`: its binaries are prebuilt and committed per
platform.

## GitHub

- `github.auth` selects whether the guest is seeded with a GitHub token
  derived from the host: `host-token` asks for one and `none` for none.
  Nothing consumes it yet.

## Environment

`env` is how a variable reaches the in-guest claude: a non-secret setting
or a third-party API key for a tool, MCP server or model provider other
than Anthropic or GitHub. The tier a sub-key may sit in follows from how
its value is obtained.

- `env.set` maps a name to an explicit literal. Its values are committed
  config, and in a bake file image bytes too, so it never holds a secret.
  In a bake file it is written into the image and persists across every
  run of it; in a boot file it applies to one launch and is shredded on
  exit, overriding the bake value for the same name.
- `env.copy` lists names read from the environment claude-vm is launched
  from. The value is never written anywhere: never ask for it, and never
  read one out to echo it back.
- `env.files` lists host `.env` files parsed at launch. Blank lines and
  `#` comments are skipped, a leading `export` is dropped, a value in
  matching quotes is unwrapped, and there is no expansion or escape
  processing.

Precedence, lowest to highest, is bake `env.set`, then boot `env.files`,
then boot `env.copy`, then boot `env.set`; within `env.files` a later file
wins.

Forwarding a key does not make its service reachable: the guest is
egress-confined, so pair every `env.copy` entry with its provider's host
in `egress.allow` (`openrouter.ai` for `OPENROUTER_API_KEY`). Nothing is
derived from a variable name.

The launcher aborts on a misplaced `env` sub-key, even empty; an
`env.copy` name unset or empty where claude-vm is launched; an
`env.files` path not on the host or that does not parse; a name outside
`[A-Za-z_][A-Za-z0-9_]*`; an `env.set` value that is a map or a list, or a
key left valueless (write `NAME: ""` for the empty string); and a name the
launcher composes itself — every `run.env` name (the proxy variables,
`CLAUDE_ARGS`, the `*_TAG` mount variables, `IS_SANDBOX`,
`DISABLE_AUTOUPDATER`, the renderer `CLAUDE_CODE_*` variables, the
terminal geometry, the `CLAUDE_VM_*_UPDATE_AT_BOOT` flags) plus
`CLAUDE_VM_LAST_CLAUDE_STATUS`. No diagnostic prints a value.
