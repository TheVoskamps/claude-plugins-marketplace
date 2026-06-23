---
name: repo-public-mirror-setup
description: "Bootstrap a filtered, read-only public mirror for the current private repo (paired public repo, deploy key, filter config, mailmap, workflow, read-only enforcement)."
---

You are running the `/repo-public-mirror-setup` skill. Your job is to
bootstrap a filtered, read-only public mirror for the **current
private repo** (the repo `cd`-ed into when this skill was invoked).
The setup is multi-step and partly destructive: it creates a new
public GitHub repo, uploads a deploy key, and stores a repo secret.
It also writes (but does not commit) filter config and a workflow
file in the source repo.

The first instance of this pattern is issue #26 in
`TheVoskamps/global-claude-config` (creating
`TheVoskamps/global-claude-config-public`). This skill codifies
that pattern so it can be applied to other private repos without
re-deriving the plumbing each time.

Follow the steps below in order. There are three explicit **halts**
where you wait for the user before proceeding. Do not skip them.

## Template payload

The starter files this skill installs (the workflow, filter config,
mirror `.gitignore`, `CONTRIBUTORS`, and the public-facing `LICENSE`,
`PATENTS`, `PRIOR_ART.md`, and `README.md`)
live as templates under
`${CLAUDE_PLUGIN_ROOT}/payload/repo-public-mirror-setup/`, following
the bundled-payload convention (see
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` for the placeholder/render/
existence-check contract). The skill reads each template, substitutes
the placeholders below, and writes the rendered result into the source
repo. The skill does **not** carry the file bodies inline — it renders
them from the payload.

Placeholders used by this skill's templates:

- `__GH_ORG__` — owner of the source repo. Inferred:
  `gh repo view --json owner -q .owner.login`.
- `__GH_REPO__` — source repo short name; also the
  `__GH_REPO__-public` mirror name and the `__GH_REPO__.local`
  mailmap domain. Inferred: `gh repo view --json name -q .name`.
- `__GH_OWNER_NAME__` — human owner name in the `PATENTS` /
  `PRIOR_ART.md` prior-art notice. Prompted from the user.
- `__RELEASE_DATE__` — public-release date in the `PATENTS` /
  `PRIOR_ART.md` prior-art notice. Prompted from the user.

Render with simple string substitution (the
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` reference recipe), e.g. read a
template via the `Read` tool, replace each `__PLACEHOLDER__` with its
resolved value, and write the result with `Write`. Never write a
rendered file that still contains a `__...__` placeholder — if any
remains after inference and prompting, abort per the
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` "Resolving placeholder values" rule.

## Workflow-auth identity

This skill uses the **deploy-key** flow (Steps 15–16): a write-enabled
deploy key on the mirror plus the `PUBLIC_MIRROR_DEPLOY_KEY` secret on
the source. That flow is intact and is the supported path; this skill
does **not** resolve a GitHub App identity via `skills/lib/gh-app.md`.
The App resolver is only warranted if a future variant pushes via an
App rather than a deploy key — out of scope here.

---

## Inputs

- **SSH key path** (required): path to the keypair the user
  generated out-of-band with `ssh-keygen`. The agent cannot
  generate SSH keypairs (blocked by `settings.json`), so the user
  must produce the key first and pass the path in.

  If the user did not provide a path when invoking the skill, ask
  for one before doing anything else. The path may be absolute
  (`/Users/<name>/.ssh/<repo>-mirror`) or `~`-prefixed; expand `~`
  to the user's home directory before checking the filesystem.

Everything else is derived by convention (see Step 4).

---

## Step 0: Payload

The template payloads this skill renders ship with the plugin at
`${CLAUDE_PLUGIN_ROOT}/payload/repo-public-mirror-setup/`. Treat that
directory as `$PAYLOAD` for the rest of the skill. Every starter file
the skill writes is rendered from a template under `$PAYLOAD` — the
skill does not carry those file bodies inline. The placeholder/render
convention is documented in `${CLAUDE_PLUGIN_ROOT}/payload/README.md`.

## Step 1: Pre-flight — repo root and visibility

Verify you are inside a git working tree:

```bash
git rev-parse --show-toplevel
```

Treat the path printed by this command as the **repo root** for the
rest of the skill. The skill operates on the source repo (the repo
the user invoked it from), not on `~/.claude`. Do **not** assume
`~/.claude` or any other path.

If the command fails (non-zero exit, "not a git repository"), abort
with:

> `/repo-public-mirror-setup` must be run from inside a git
> repository. The current directory is not a git working tree.

Then verify the source repo is **private**:

```bash
gh repo view --json visibility -q .visibility
```

If the value is anything other than `PRIVATE`, abort with:

> `/repo-public-mirror-setup` is only valid for private source
> repos. The current repo's visibility is `<value>`. A public repo
> doesn't need a filtered public mirror; if you want a different
> kind of mirror, that's out of scope for this skill.

## Step 2: Pre-flight — SSH key path

Resolve `~` in the SSH key path the user gave you, then verify both
halves exist:

- `<path>` (private half) must exist and be a regular file.
- `<path>.pub` (public half) must exist and be a regular file.

If either is missing, abort with a message naming the exact path
that was missing and reminding the user to generate the keypair
with `ssh-keygen`. Use the same `<short>-public` suffix as the
mirror repo so the key→repo mapping is obvious (e.g.
`ssh-keygen -t ed25519 -C '<short>-public'
-f ~/.ssh/<short>-public`). Do not offer to generate the key
yourself — key generation is out of scope and blocked by
`settings.json`.

Do **not** print the private key contents to the conversation at
any point in this skill. Pass it to `gh secret set` via stdin, not
via a shell argument.

## Step 3: Pre-flight — local tooling

Verify `git-filter-repo` is installed locally:

```bash
command -v git-filter-repo
```

If it returns nothing (exit non-zero), abort with:

> `git-filter-repo` is not installed. Install it with
> `brew install git-filter-repo`, then re-run
> `/repo-public-mirror-setup`.

Also verify `gh` is authenticated and has scope to create
repositories under the target org. A quick smoke test:

```bash
gh auth status
```

If `gh` reports the user is not authenticated, abort and instruct
them to run `gh auth login` (with `repo` scope, plus
`admin:public_key` so the deploy-key step in Step 15 works).

## Step 4: Derive names and identifiers

From the source repo, derive the conventional names:

- **Source repo full name**: read with
  `gh repo view --json nameWithOwner -q .nameWithOwner` (e.g.
  `TheVoskamps/global-claude-config`).
- **Source repo short name**: the part after the slash (e.g.
  `global-claude-config`).
- **Mirror repo full name**: `<owner>/<short>-public`.
- **Mailmap domain**: `<short>.local` (the `.local` TLD is
  RFC-reserved and non-routable; embedding the source short name
  makes the mirror's origin obvious to anyone reading the
  rewritten emails).
- **Secret name on source repo**: `PUBLIC_MIRROR_DEPLOY_KEY`
  (constant; not per-repo).
- **Deploy-key title on mirror repo**: `public-mirror-workflow`
  (constant).

## Step 5: Halt #1 — confirm derived values

Present the derived values to the user and ask for explicit
confirmation before doing anything that touches the filesystem or
GitHub. Use this exact shape:

```text
About to set up a public mirror with the following derived values:

  Source repo:    <owner>/<short>
  Mirror repo:    <owner>/<short>-public        (will be CREATED public)
  Mailmap domain: <short>.local
  Source secret:  PUBLIC_MIRROR_DEPLOY_KEY      (will be SET on source)
  Deploy key:     public-mirror-workflow        (will be UPLOADED to mirror)
  SSH key path:   <expanded-path>

Proceed? (y to continue, or tell me what to change)
```

Wait for explicit approval (`y`, `yes`, `go`, `do it`). If the user
asks for a different mirror name, mailmap domain, or secret name,
update the derived values and re-display this halt — do not
proceed without confirmation.

The remaining steps perform real work. Do not skip this halt.

## Step 6: Render `.github/public-mirror/` config in the source repo

Create the directory `<repo-root>/.github/public-mirror/` if it does
not exist, then render the files below **from the payload**
(`$PAYLOAD`, set in Step 0). Each is a template under
`$PAYLOAD/<file>`; read it, substitute the placeholders, and write the
result to the target path. These files are **not** committed by the
skill — the user reviews the diff and commits manually, per global
rule §0 ("never write/commit without approval").

### `paths.allowlist`

Render `$PAYLOAD/paths.allowlist` (no placeholders) to
`<repo-root>/.github/public-mirror/paths.allowlist` verbatim. It is the
required-files starting set with an empty `--- repo-specific (add
below) ---` section the user fills in at Halt #2. `CONTRIBUTORS` ships
like any other allowlisted path (a static tracked file in the source
repo — see below), and `.github/public-mirror/` is not wholesale on the
allowlist: only `gitignore.mirror` survives, renamed to root
`.gitignore` by the rename directive at the bottom of the template.
Shipping both `CONTRIBUTORS` and the mirror `.gitignore` through
`git-filter-repo` (rather than synthesizing them as commits on top of
filter-repo's output) is what keeps the mirror fast-forwarding on
routine runs instead of diverging and force-pushing.

### `mailmap`

Render `$PAYLOAD/mailmap` to
`<repo-root>/.github/public-mirror/mailmap`, substituting
`__GH_REPO__` with the source short name, then **seed the author
entries** from the source repo's unique authors:

```bash
git log --format='%aN <%aE>' | sort -u
```

For each unique `Name <local@domain>` line, append a mailmap entry that
preserves the localpart and rewrites the domain to `<short>.local`:

```text
<Name> <local@<short>.local> <local@<original-domain>>
```

The template provides only the comment header (with `__GH_REPO__`
already substituted). If `git log` returns zero authors (empty repo),
write the header alone. Do not invent entries.

### `CONTRIBUTORS` (static, at the source repo root)

Render `$PAYLOAD/CONTRIBUTORS.template` to `$REPO_ROOT/CONTRIBUTORS`,
substituting `__GH_REPO__` with the source short name. `CONTRIBUTORS`
is a **static tracked file** at the source repo root; it ships to the
mirror like any other allowlisted path and is NOT synthesized at
runtime (an earlier design regenerated it as a commit stacked on top of
filter-repo's output, which sat outside filter-repo's persisted state
and made every source-change run diverge from the previous mirror tip
and force-push, breaking consumers' `git pull`). The source repo must
**track** this file — if the source `.gitignore` ignores root-level
files by default, add an explicit `!/CONTRIBUTORS` un-ignore so it is
committed and therefore ships.

### `gitignore.mirror` (the mirror's root `.gitignore`)

Render `$PAYLOAD/gitignore.mirror` (no placeholders) to
`<repo-root>/.github/public-mirror/gitignore.mirror`: the **static**
root `.gitignore` for the mirror. The rename directive in
`paths.allowlist` selects it and renames it to repo-root `.gitignore`
on the mirror, so it ships inside `git-filter-repo`'s own commit — not
as a synthesized post-filter commit.

The mirror needs its OWN `.gitignore` rather than the source repo's:
the source `.gitignore` un-ignores paths that exist privately but are
deliberately excluded from the mirror, so shipping it would leave a
consumer's `git status` referencing rules for paths absent from their
clone. The template un-ignores exactly the required shipped set plus
the `.gitignore` itself. Keep it in sync **by hand** with
`paths.allowlist`: when the user adds a repo-specific shipped path at
Halt #2, add or remove the matching `!/<path>` line here (and a
recursive `!/<dir>**` line for directories). It is part of the input
fingerprint (see Step 7), so editing it correctly triggers a refilter.

### `replacements.txt` (optional identifier scrubbing)

Render `$PAYLOAD/replacements.txt` (no placeholders) to
`<repo-root>/.github/public-mirror/replacements.txt`. The template
ships with no concrete rules — redaction rules are inherently
repo-specific. A mirror with no sensitive identifiers in history may
leave it rule-free; the allowlist filter is the primary fail-safe.

## Step 7: Render `.github/workflows/public-mirror.yml`

Create the workflow file. It triggers on `push` to `main` and on
`workflow_dispatch` for manual reruns. Steps: checkout full
history, install `git-filter-repo`, clone a fresh bare copy, fetch
the persisted `filter-repo-state` and `filter-repo-meta` branches
from the mirror, fetch the mirror's `main` and `filter-repo-blobs`
into local anchor refs (so all target-side objects referenced in
`target-marks` are present for incremental runs), run the filter
with `--paths-from-file`, `--mailmap`, `--replace-text`,
`--replace-message`, `--state-branch`, `--prune-empty=never`, and
`--refs refs/heads/main` (with a fingerprint check that triggers a
full refilter when `paths.allowlist`, `mailmap`, `gitignore.mirror`,
or the `replacements.txt` rule set changes), build a
blob-anchor commit for unreachable replacement blobs, and push to the
mirror's `main` (skipped when the new local tip already equals the
mirror's current tip; force-pushed only on from-scratch refilters,
fast-forwarded on incremental runs) plus the three bookkeeping
branches (always force-pushed). `CONTRIBUTORS` ships as a static
tracked file and `gitignore.mirror` is renamed to root `.gitignore` —
both through `git-filter-repo` itself, so there are no post-filter
synth steps.

Render the workflow from `$PAYLOAD/public-mirror.yml` to
`<repo-root>/.github/workflows/public-mirror.yml`, substituting
`__GH_ORG__` with the owner and `__GH_REPO__` with the source short
name. Those two placeholders appear in the `MIRROR_URL` env of the
filter step (`git@github-mirror:__GH_ORG__/__GH_REPO__-public.git`)
and `__GH_REPO__` also in the bot identity
(`public-mirror@__GH_REPO__.local`). After rendering, confirm no
`__...__` placeholder remains in the written file.

Notes on the template:

- There are **no post-filter synth steps**. `CONTRIBUTORS` ships as a
  static tracked file at the source repo root (on `paths.allowlist`),
  and the mirror's root `.gitignore` is renamed in from
  `gitignore.mirror` by the rename directive in `paths.allowlist`.
  Both land inside `git-filter-repo`'s own commit. An earlier design
  synthesized these two files as commits stacked on top of
  filter-repo's output; those commits sat outside filter-repo's
  `--state-branch` marks and made every source-change run diverge from
  the previous mirror tip and force-push, breaking consumers'
  `git pull`. Shipping both through filter-repo means nothing is
  stacked on its output, so routine runs fast-forward.
- The meta-index temp file lives under `${RUNNER_TEMP}` (the
  GitHub-recommended runner temp dir). The bare clone
  (`WORK=$(mktemp -d)`) and the blob-type scratch file
  (`TYPES_FILE=$(mktemp)`) use the runner's system default temp dir,
  which on GitHub-hosted runners already resolves under the runner's
  workspace — neither writes to the repo tree.
- The `user.email` bot identity (`public-mirror@__GH_REPO__.local`) and
  the mirror remote URL / `MIRROR_URL`
  (`git@github-mirror:__GH_ORG__/__GH_REPO__-public.git`) carry the
  `__GH_REPO__` / `__GH_ORG__` placeholders in the template; the render
  step in Step 7 substitutes them. No hand-editing of the written file
  is needed.
- The bot git identity is set **once**, repo-locally, on the bare
  clone (`git config user.name` / `user.email` right after the
  `cd "$WORK/src.git"`), and every commit-creating path inherits it:
  the meta-branch commit, the blob-anchor commit, and filter-repo's
  own internal `--state-branch` mark-saving commit
  (`git_filter_repo.py`'s `git -C . commit-tree`, which carries no
  identity flags). Do not re-decorate individual `commit-tree` calls
  with inline `-c user.name=… -c user.email=…` — that per-commit
  pattern structurally cannot cover filter-repo's internal commit and
  reintroduces issue #147 (`fatal: empty ident name`). Local scope
  (not `--global`) is deliberate: filter-repo runs `commit-tree` with
  cwd inside the clone, so git reads identity from the clone's local
  `config`, and nothing outside the clone needs the identity. The
  `.local` email is intentionally unverifiable — the `mailmap` pass
  rewrites these bookkeeping commits' identities anyway.
- `concurrency: public-mirror` prevents overlapping force-pushes if
  two pushes land on `main` close together.
- `CONTRIBUTORS` is a static tracked file in the source repo, shipped
  by filter-repo like any other allowlisted path. Refresh it by hand
  (regenerate `git shortlog -sne` against the rewritten history,
  excluding the mirror bot) when desired. Because it is a normally
  tracked source file, editing it is a source commit handled by
  filter-repo's normal incremental path — it is deliberately NOT in
  the input fingerprint.
- `gitignore.mirror` becomes the mirror's root `.gitignore` via the
  rename directive in `paths.allowlist`. It un-ignores exactly the
  shipped set plus the `.gitignore` itself (with a recursive
  `!/<dir>**` line for each shipped directory), so a user who clones
  the mirror underneath `~/.claude` gets a clean `git status`. It is
  kept in sync with `paths.allowlist` BY HAND and is part of the input
  fingerprint, so editing it triggers a refilter — without that, the
  mirror's `.gitignore` could go silently stale relative to
  `gitignore.mirror`.
- The `Filter into a fresh bare clone with persisted marks` step
  uses `git filter-repo --state-branch filter-repo-state` so the
  fast-import marks (source-commit → public-commit SHA mapping)
  persist between runs on a dedicated mirror branch. Unchanged
  source commits keep their previously-computed public SHAs across
  runs, which is what makes a consumer's `git pull` fast-forward
  cleanly after a genuine source change instead of seeing the entire
  public history rewritten. `--refs refs/heads/main` scopes
  fast-export to walk only the source branch, not the fetched
  anchor/blob refs; without it, filter-repo's default `--all` would
  walk every ref in the clone, including the anchor refs whose
  commits are target-side. A sibling `filter-repo-meta` branch
  holds a `inputs.sha256` fingerprint over `paths.allowlist`,
  `mailmap`, `gitignore.mirror`, and the cleaned `replacements.txt`
  rule set; on each run the live fingerprint
  is compared to the stored one,
  and a mismatch triggers a full refilter (which is logged with a
  GitHub `::warning::` annotation so the operator notices). A third
  `filter-repo-blobs` branch anchors unreachable replacement blobs
  created by `--replace-text` so they survive between runs. The
  three bookkeeping branches are pushed alongside `main` on every
  run (the blob-anchor push is conditional on blobs existing in
  target-marks).
- `--prune-empty=never` is paired with `--state-branch` deliberately:
  filter-repo's source warns that `--state-branch` does not work
  well with empty-commit pruning. The trade-off is that source
  commits which touch only excluded paths show up in the mirror as
  empty commits with their original commit messages intact. For
  this skill's use case (private repo → public mirror) leaking
  both the timing AND the commit-message contents for changes
  touching only excluded paths is acceptable; the excluded diff
  payload itself stays excluded. Operators with commit messages
  that themselves contain sensitive content should weigh this
  carefully before adopting the skill.
- The `Push to mirror` step compares the new local tip to the
  mirror's current `refs/heads/main` (`git ls-remote`) and skips the
  `main` push when they match. Because nothing is stacked on
  filter-repo's output, the local tip IS filter-repo's output —
  together with `--state-branch` this makes both no-source-change runs
  AND genuine-source-change runs (where new commits add to the public
  tip without rewriting history below) consumer-friendly. When the
  tips differ, the step
  checks `REFILTER_REASON`: on a from-scratch refilter (non-empty
  reason) it force-pushes main (history was rewritten); on an
  incremental run (empty reason) it pushes without `--force` so
  consumers see a clean fast-forward. Before either push, a
  strict-ancestor safety guard fails the run fast if the local
  `main` is a strict ancestor of the remote `main` (local is behind,
  remote has commits local lacks) — pushing in that state would
  regress the mirror, so the step refuses rather than emit git's
  ambiguous non-fast-forward hint. The state, meta, and
  blob-anchor branches are always pushed (force) so the next run
  can read them back; when the fingerprint is unchanged the
  meta-branch SHA is stable, and when the blob set is unchanged the
  blob-anchor SHA is stable, so those pushes are true no-ops. The
  blob-anchor push is conditional on the ref existing (it may not
  exist on the first run or when target-marks contains no blobs).

## Step 8: Halt #2 — user populates `paths.allowlist`

Tell the user that the three config files and the workflow now
exist on disk (uncommitted), and that the **allowlist's
repo-specific section is empty**. The mirror will be nearly empty
on first run if the user does not add paths.

Suggest a starting place: re-read the source repo's `.gitignore`
(if it uses a whitelist style) or list the top-level entries with
`ls -A` so the user can decide which directories belong in the
mirror. Then ask:

> Edit `.github/public-mirror/paths.allowlist` now, adding any
> repo-specific paths under the `--- repo-specific (add below) ---`
> marker. Tell me when you're done.

Wait for explicit confirmation that the file is ready. Do not
advance to Step 9 until the user says so.

## Step 9: Dry-run the filter locally

In a sandbox directory under `.claude/tmp/repo-public-mirror-setup/`
(per the `<repo-root>/.claude/tmp/` convention — never `/tmp/`),
run the filter against a fresh bare clone of the source repo.
Print the resulting tree so the user can see exactly what would
land in the mirror.

```bash
# Capture the absolute repo root BEFORE cd-ing, so the filter
# config paths resolve correctly regardless of cwd depth.
REPO_ROOT="$(git rev-parse --show-toplevel)"
mkdir -p "$REPO_ROOT/.claude/tmp/repo-public-mirror-setup"
WORK="$REPO_ROOT/.claude/tmp/repo-public-mirror-setup/dryrun"
rm -rf "$WORK"
# --no-local forces a real object copy instead of hardlinking into the
# source repo's object store. git-filter-repo aborts on a clone whose
# objects are hardlinked back to the original, so a plain --bare clone
# (which hardlinks for a local path) would fail here.
git clone --no-local --bare "$REPO_ROOT" "$WORK"
( cd "$WORK" \
  && git filter-repo \
       --paths-from-file "$REPO_ROOT/.github/public-mirror/paths.allowlist" \
       --mailmap "$REPO_ROOT/.github/public-mirror/mailmap" \
  && git ls-tree -r --name-only HEAD | sort )
```

Print the sorted list of file paths from `git ls-tree -r
--name-only HEAD`. Group it by top-level directory for legibility
if the list is long.

If `tree` is installed, an alternative second display is helpful:

```bash
( cd "$WORK" \
  && git archive --format=tar HEAD | tar -tf - | sort \
       | sed 's#[^/]##g;s#/#  #g' )
```

Either form is fine — the point is the user can audit the contents
before any remote push.

Cleanup of the sandbox is deferred to after Step 16 succeeds, so
the user can re-run the listing if they want.

## Step 10: Halt #3 — user confirms the dry-run tree

Ask explicitly:

> Does this look right? Check for two things:
>
> 1. No leaked sensitive paths (anything you don't want published).
> 2. All expected paths present (every file the mirror needs).
>
> Reply `y` to proceed with creating the mirror repo, or tell me
> what to change in the allowlist.

Wait for explicit `y`/`yes`/`go`. If the user asks for changes,
loop back to Step 8 — they edit the allowlist, you re-run the
dry-run, you re-display the tree, you ask again.

After this halt the skill proceeds through repo creation, deploy
key, and secret upload **without further halts** — those are the
plumbing steps that are safe once the tree has been approved.

## Step 11: Create the mirror repo

```bash
DESC="Read-only public mirror of <owner>/<short> (private)."
gh repo create <owner>/<short>-public \
  --public \
  --description "$DESC" \
  --disable-wiki
```

Only `--disable-wiki` is passed at creation time. **Issues stay
ON** — this mirror's posture is `issues-allowed`: external users
may report problems on the mirror, which we triage and fix in the
upstream private repo. Do **not** pass `--disable-issues`. `gh repo
create` does not have a `--disable-discussions` flag, so Discussions
are handled in Step 13.

Then set merge methods and the merge-cleanup flag with `gh repo
edit`. The mirror's gold-standard posture is **merge-commit on,
squash off, rebase off**, with `deleteBranchOnMerge=true`:

```bash
gh repo edit <owner>/<short>-public \
  --enable-merge-commit \
  --enable-squash-merge=false \
  --enable-rebase-merge=false \
  --delete-branch-on-merge
```

Note: PRs are **not** blocked by disabling merge methods — the
mirror keeps merge-commit ON. PR-blocking comes from the
`mirror-main-readonly` ruleset's `update` rule applied in Step 14.
The merge-method setting here just mirrors the live gold-standard
repo's configuration; it is not the PR guard.

If the repo already exists, abort with a clear message rather than
overwriting. This skill is for green-field setup — migration of an
existing public mirror to this pattern is out of scope.

## Step 12: Push the initial commit to establish `main`

Create the bootstrap content locally in
`.claude/tmp/repo-public-mirror-setup/bootstrap/` and push it as
the first commit on the mirror's `main`. This establishes `main`
so the read-only ruleset in Step 14 can apply. The workflow will
overwrite this commit's history on the first real filter run; the
purpose here is purely to create a default branch.

Files in the bootstrap commit:

- `README.md` — read-only banner (rendered from `$PAYLOAD/README.md`).
  The banner welcomes issues and states PRs are not accepted; it
  carries **no link to the private upstream repo**.
- `LICENSE`, `PATENTS`, `PRIOR_ART.md`, `CODEOWNERS`, `CONTRIBUTORS`:
  the source repo's own copy if it exists; otherwise the payload
  starter (`$PAYLOAD/LICENSE`, `$PAYLOAD/PATENTS`,
  `$PAYLOAD/PRIOR_ART.md`). `CODEOWNERS` has no payload starter — copy
  it only if the source has it. `CONTRIBUTORS` was rendered to
  `$REPO_ROOT/CONTRIBUTORS` in Step 6; copy that.
- The mirror's root `.gitignore` from
  `.github/public-mirror/gitignore.mirror` (copied to `$BOOT/.gitignore`).
  Do NOT copy the source repo's own root `.gitignore` — the mirror
  ships `gitignore.mirror` instead, and the first real workflow run
  will produce the same `.gitignore` via the rename directive.

The `README.md` payload starter carries the read-only banner; render
`$PAYLOAD/README.md` (substitute `__GH_REPO__`). The banner welcomes
issues and states PRs are not accepted, with no upstream link.

The `PATENTS` and `PRIOR_ART.md` payload starters carry the
`__GH_OWNER_NAME__` and `__RELEASE_DATE__` placeholders. These are
**only** needed when the source repo lacks its own copy of those files.
If a starter is needed, prompt the user for the owner name and the
public-release date before rendering, per the
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` "Resolving placeholder values"
rule (these two cannot be inferred). If the source already has the
file, copy it verbatim and skip the prompt.

Push sequence (run from the source repo root):

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
BOOT="$REPO_ROOT/.claude/tmp/repo-public-mirror-setup/bootstrap"
mkdir -p "$BOOT"
cd "$BOOT"
git init -b main
```

Then populate the bootstrap directory as explicit, separate
actions (do not bundle into a comment):

1. Render `$PAYLOAD/README.md` (substitute `__GH_REPO__`) to
   `$BOOT/README.md`.
2. For each of `LICENSE`, `PATENTS`, `PRIOR_ART.md`, `CODEOWNERS`,
   `CONTRIBUTORS`: if the file exists at `$REPO_ROOT/<name>`, copy it
   to `$BOOT/<name>`. Otherwise, for `LICENSE` / `PATENTS` /
   `PRIOR_ART.md`, render the payload starter
   (`$PAYLOAD/<name>` — `PATENTS` and `PRIOR_ART.md` need the
   `__GH_OWNER_NAME__` / `__RELEASE_DATE__` prompt above) to
   `$BOOT/<name>`. `CODEOWNERS` has no starter; skip silently when
   absent. `CONTRIBUTORS` always exists (rendered in Step 6).
3. Copy `$REPO_ROOT/.github/public-mirror/gitignore.mirror` to
   `$BOOT/.gitignore` (the mirror's root `.gitignore`). Do NOT copy
   the source repo's own `$REPO_ROOT/.gitignore`.

Then commit and push:

```bash
git add .
git -c user.name='public-mirror-setup' \
    -c user.email='public-mirror-setup@<short>.local' \
    commit -m 'Bootstrap mirror; real history follows from workflow'
git remote add origin git@github.com:<owner>/<short>-public.git
git push -u origin main
```

This commit will be replaced on the first real workflow run. Its
only purpose is to give `main` a SHA so the read-only ruleset can
attach to it.

## Step 13: Set Issues / Discussions / Wiki / Projects on the mirror

```bash
gh repo edit <owner>/<short>-public \
  --enable-issues=true \
  --enable-discussions=false \
  --enable-wiki=false \
  --enable-projects=false
```

**Issues stay ON** (`--enable-issues=true`) — this is the
gold-standard `issues-allowed` posture: external users report
problems on the mirror, which we triage and fix upstream. Wiki,
Discussions, and Projects are off. `--enable-wiki=false` is
redundant with the `--disable-wiki` passed at create time, but
stating it here keeps the intent explicit and makes this step
self-contained if re-run.

## Step 14: Create the `mirror-main-readonly` ruleset on the mirror

Apply a **repository ruleset** (not legacy branch protection) that
makes `main` read-only to everyone except repo admins. This is the
PR-and-push guard: the ruleset's `update` rule is what blocks PRs
and direct pushes, while the admin bypass is what still lets the
workflow force-push. PR-blocking does **NOT** come from disabling
merge methods (the mirror keeps merge-commit on — see Step 11).

Do **not** create legacy branch protection
(`/branches/main/protection`); the live gold-standard mirror has
none (that REST endpoint returns 404 there — it was superseded by
this ruleset). Use `gh api` to POST the ruleset:

```bash
gh api \
  --method POST \
  -H 'Accept: application/vnd.github+json' \
  /repos/<owner>/<short>-public/rulesets \
  --input - <<'JSON'
{
  "name": "mirror-main-readonly",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "update" }
  ],
  "bypass_actors": [
    {
      "actor_type": "RepositoryRole",
      "actor_id": 5,
      "bypass_mode": "always"
    }
  ]
}
JSON
```

Notes:

- **`actor_id: 5` is the built-in `admin` RepositoryRole.** The
  bypass is the **admin role**, not a per-deploy-key bypass,
  because deploy keys cannot be named as ruleset bypass actors —
  ruleset `bypass_actors` accept org teams, GitHub Apps, and the
  built-in RepositoryRole IDs (1 maintain, 2 write, 4 triage, 5
  admin, etc.), but not deploy keys. A deploy key authenticates as
  the repository itself and inherits **admin-equivalent** write
  access to the repo it is attached to, so it lands inside the
  admin bypass and can force-push `main`. Granting the bypass to
  the admin role (rather than, say, the write role) keeps the set
  of identities that can push `main` as small as possible: repo
  admins and the workflow's deploy key, nobody else.
- **The three rules together** make `main` read-only for non-admins:
  `update` blocks ref updates (this is what rejects PRs and direct
  pushes), `non_fast_forward` blocks force-pushes, and `deletion`
  blocks branch deletion. The admin bypass (`bypass_mode: always`)
  lets the workflow's deploy key do all three when it needs to —
  the workflow force-pushes `main` on the first run and on any
  filter-input change, and always force-pushes the bookkeeping
  branches (`filter-repo-state`, `filter-repo-meta`,
  `filter-repo-blobs`). The ruleset only targets `~DEFAULT_BRANCH`
  (`main`), so the bookkeeping branches are unrestricted regardless.
- **`~DEFAULT_BRANCH`** is the ref-name macro for the repo's default
  branch; using it (rather than a literal `refs/heads/main`) keeps
  the ruleset correct if the default branch is ever renamed.
- Admins are intentionally **not** locked out — leaving the admin
  RepositoryRole in `bypass_actors` means a human admin can
  intervene if the workflow gets stuck, the same rationale as the
  old `enforce_admins: false` posture.
- If the target org enforces stricter org-level rulesets, this POST
  may conflict or be rejected. In that case surface the error to
  the user and stop — the user resolves the conflict at the org
  level, then asks the skill to retry.

## Step 15: Upload the public half as a deploy key on the mirror

```bash
gh repo deploy-key add <expanded-path>.pub \
  --repo <owner>/<short>-public \
  --title public-mirror-workflow \
  --allow-write
```

`--allow-write` is required because the workflow force-pushes to
the mirror.

## Step 16: Store the private half as a secret on the source repo

Read the private-key file and pipe it to `gh secret set`. Do not
expand the contents into the conversation or into shell argv.

```bash
gh secret set PUBLIC_MIRROR_DEPLOY_KEY \
  --repo <owner>/<short> \
  < "<expanded-path>"
```

The redirect target is quoted so paths containing spaces (e.g.
`/Users/Alice Smith/.ssh/repo-mirror`) work correctly.

The secret name `PUBLIC_MIRROR_DEPLOY_KEY` matches the
`${{ secrets.PUBLIC_MIRROR_DEPLOY_KEY }}` reference in the
workflow written in Step 7.

## Step 17: Print the next-steps checklist

Print this checklist to the user. The skill does **not** commit
the source-repo files — the user reviews and commits manually
(global rule §0).

```text
Public mirror bootstrap complete.

Created on GitHub:
  - <owner>/<short>-public (public, Issues ON; Wiki/Projects/
    Discussions off; merge-commit only, delete-branch-on-merge on)
  - Ruleset mirror-main-readonly on main (deletion +
    non_fast_forward + update; admin RepositoryRole bypass, so the
    workflow's deploy key can still force-push)
  - Deploy key: public-mirror-workflow (write-enabled)
  - Source secret: PUBLIC_MIRROR_DEPLOY_KEY

Uncommitted in this repo (review and commit when ready):
  - .github/public-mirror/paths.allowlist
  - .github/public-mirror/mailmap
  - .github/public-mirror/gitignore.mirror
  - .github/public-mirror/replacements.txt
  - CONTRIBUTORS
  - .github/workflows/public-mirror.yml

Next steps:
  1. Review the diff:    git diff --stat .github/
  2. Commit and push:    triggers the first real workflow run.
  3. Watch the run:      gh run watch (on push to main)
  4. Verify the mirror:  the contents on
     <owner>/<short>-public should match the dry-run tree.
     The first run logs a `::warning::Refiltering from scratch:
     first run (no state branch on mirror)` annotation; this is
     expected. The state, meta, and blob-anchor branches
     (`filter-repo-state`, `filter-repo-meta`,
     `filter-repo-blobs`) appear on the mirror after this run;
     subsequent runs reuse them.
  5. Verify no-op runs:  re-trigger the workflow via
     `gh workflow run public-mirror.yml --ref main` with no
     intervening source changes. The `Push to mirror`
     step should log `Mirror refs/heads/main already at
     <sha>; nothing to push to main.` and a consumer clone's
     `git pull` should report `Already up to date.`
  6. Verify source-change runs are fast-forward:  land one new
     commit on the source's `main`, watch the workflow, then on
     the consumer clone run `git pull`. It should fast-forward
     by exactly one commit (the new tip), NOT report a forced
     update. The previous public history's SHAs are unchanged
     because `--state-branch` reused them.

When you later edit the filter config (paths.allowlist, mailmap, or
gitignore.mirror), the next workflow run detects the input change via
the fingerprint stored on filter-repo-meta, logs a warning
"Refiltering from scratch: filter inputs changed", and
force-pushes a rebuilt main. Tell consumers of the mirror to do
a one-time `git fetch && git reset --hard origin/main` after a
config-change run. (Editing the static CONTRIBUTORS file is NOT a
config change — it is a normal source commit that the incremental
path fast-forwards.)

If the first real workflow run fails, common causes:
  - paths.allowlist references a path that doesn't exist in
    history (filter-repo treats this as fatal — fix the path
    or drop the entry)
  - mailmap has malformed entries (filter-repo logs the bad line)
  - deploy key lacks write scope (re-run gh repo deploy-key add
    with --allow-write); the deploy key also needs write scope
    to push the filter-repo-state, filter-repo-meta, and
    filter-repo-blobs bookkeeping branches alongside main.
```

Then clean up the sandbox if the run succeeded:

```bash
rm -rf .claude/tmp/repo-public-mirror-setup
```

Leave the sandbox in place if any step from 11 onward failed, so
the user can inspect it.

---

## Halts and approval gates (summary)

The skill **must** halt and wait for explicit user confirmation at:

- **Halt #1 (Step 5)** — derived values (mirror name, mailmap
  domain, secret name, deploy-key title).
- **Halt #2 (Step 8)** — user populates `paths.allowlist` with
  repo-specific paths.
- **Halt #3 (Step 10)** — dry-run tree review before any
  destructive remote action.

After Halt #3, Steps 11–16 run without further halts — those are
the plumbing steps that are safe once the tree has been approved.

---

## Hard constraints

- **Never run before all pre-flight checks (Steps 0–3) pass.**
  Each abort message must name the exact thing that failed and
  what the user should do about it. Step 0 aborts with the standard
  `${CLAUDE_PLUGIN_ROOT}/payload/README.md` existence-check message if the
  payload directory is missing.
- **Never write or commit the source-repo files for the user.**
  Step 6 and Step 7 create the files on disk uncommitted; the user
  reviews the diff and commits manually. (Global rule §0: never
  commit without approval.)
- **Never edit anything outside the source repo.** The skill
  writes files under `<repo-root>/.github/public-mirror/`,
  `<repo-root>/.github/workflows/`, and
  `<repo-root>/.claude/tmp/repo-public-mirror-setup/`. It **reads**
  templates from
  `${CLAUDE_PLUGIN_ROOT}/payload/repo-public-mirror-setup/`
  (read-only — never written to). Nothing outside the source repo
  gets touched on disk; the only remote changes are on the
  newly-created mirror and the `PUBLIC_MIRROR_DEPLOY_KEY` secret on
  the source.
- **Never skip a halt.** All three halts (Steps 5, 8, 10) are
  required. A "looks fine, proceeding" response without explicit
  user confirmation is not approval.
- **Never print private key material to the conversation.** Pipe
  the private key file directly into `gh secret set` via stdin.
  The `gh secret set ... < <path>` form is required.
- **Never run on a public source repo.** Step 1 aborts if the
  source visibility is anything other than `PRIVATE`.
- **Never proceed if `git-filter-repo` is missing.** Step 3 aborts
  with the install command. Do not attempt to install it yourself
  — the user runs `brew install git-filter-repo`.
- **All scratch work done by the skill on the user's machine goes
  under `.claude/tmp/...`** in the source repo, never `/tmp/`,
  never the user's home directory, never a path outside the repo.
  Clean up on success; leave in place on failure. (This constraint
  applies to the **skill**. The generated workflow runs on
  GitHub-hosted Actions runners, a separate execution context with
  its own conventions — there the meta-index uses `${RUNNER_TEMP}`,
  the GitHub-recommended runner temp dir, while the bare clone and
  blob-type scratch file use the runner's default temp dir. Neither
  writes to the repo tree.)
- **Keep Issues ON on the mirror** (`issues-allowed` posture).
  Pass only `--disable-wiki` at create time (Step 11); do **not**
  pass `--disable-issues`. Discussions and Projects are turned off
  via the follow-up `gh repo edit` in Step 13 because `gh repo
  create` does not expose `--disable-discussions` / a Projects
  flag.
- **Block PRs via the `mirror-main-readonly` ruleset, not by
  disabling merge methods.** Step 11 keeps merge-commit ON to match
  the live gold-standard mirror; Step 14's ruleset `update` rule is
  the actual PR-and-push guard. Do **not** create legacy branch
  protection on the mirror.

---

## Out of scope

- **SSH keypair generation.** Blocked by `settings.json`. The user
  generates the key out-of-band and passes the path in.
- **The first real filtered push.** The skill establishes `main`
  with a bootstrap commit (Step 12) so the read-only ruleset can
  apply, but the first filtered history push only happens when the
  user commits the source-repo files (Steps 6–7) and pushes,
  triggering the workflow.
- **Repo-specific allowlist contents** beyond the required-files
  starting set. The user fills these in at Halt #2.
- **Migration of an existing public mirror to this pattern.** This
  skill is for green-field setup only. If `<owner>/<short>-public`
  already exists, Step 11 aborts.
- **Auditing the contents of the source repo for sensitive data
  before publishing.** The allowlist-only filter is fail-safe for
  *new* files added later, but the user is responsible for
  reviewing the dry-run tree at Halt #3 to confirm nothing
  currently in history leaks.
