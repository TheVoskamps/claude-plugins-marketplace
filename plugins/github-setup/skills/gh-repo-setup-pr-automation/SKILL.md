---
name: gh-repo-setup-pr-automation
description: "Install PR-automation workflows (auto-merge, auto-rebase, scheduled rebase sweep, /rebase responder) into the current repo, rendered from templates and backed by a GitHub App identity stored as repo or org secrets, committing + PR-ing its own rendered files on a single approval and skipping the secret set when both App-identity secrets already exist."
---

You are running the `/gh-repo-setup-pr-automation` skill. Your job is to
install PR-automation GitHub Actions workflows into the **current repo**
(the repo `cd`-ed into when this skill was invoked):

- **auto-merge enablement** — every PR to the default branch gets
  auto-merge turned on so it merges once required checks and approvals
  are green.
- **auto-rebase** — open PRs that fall behind the base branch are
  rebased automatically on every push to the base branch.
- **scheduled rebase sweep** — a cron backstop catches PRs that the
  event-driven path missed (GitHub's lazy `mergeStateStatus` race).
- **`/rebase` responder** — a write/admin collaborator comments
  `/rebase` on a PR to rebase just that PR on demand.

The workflows are rendered from templates in
`${CLAUDE_PLUGIN_ROOT}/payload/gh-repo-setup-pr-automation/` using the placeholder
mechanism in `${CLAUDE_PLUGIN_ROOT}/payload/README.md`. They run as a **GitHub
App**, not the default `GITHUB_TOKEN` — the default token gets
`FORBIDDEN: Resource not accessible by integration` on
`enablePullRequestAutoMerge`, and pushes made with `GITHUB_TOKEN` do not
re-trigger downstream required checks. The App is resolved via
`skills/lib/gh-app.md`.

Follow the steps in order. There are explicit **halts** where you wait
for the user (the resolved-values confirmation, the commit/push/PR
approval, and the secret-setting prompts — see "Halts and approval
gates" below). Do not skip them.

---

## Required GitHub App permissions

This skill resolves an App that satisfies this `required_permissions`
map (passed to `skills/lib/gh-app.md`):

```text
contents:      write    # force-push rebased PR branches
pull_requests: write    # enable auto-merge, read PR state
```

`contents: write` covers the auto-rebase force-push;
`pull_requests: write` covers `enablePullRequestAutoMerge` and reading
PR / merge state. No `workflows` scope is needed — the skill installs
workflow files via a normal commit, it does not write them through the
App at runtime.

---

## Step 0: Payload

The workflow template payloads this skill renders ship with the plugin
at `${CLAUDE_PLUGIN_ROOT}/payload/gh-repo-setup-pr-automation/`. The
placeholder/render convention is documented in
`${CLAUDE_PLUGIN_ROOT}/payload/README.md`.

## Step 1: Pre-flight — repo root and tooling

Verify you are inside a git working tree:

```bash
git rev-parse --show-toplevel
```

Treat the printed path as the **repo root** for the rest of the skill.
If the command fails, abort with:

> `/gh-repo-setup-pr-automation` must be run from inside a git
> repository. The current directory is not a git working tree.

Verify `gh` is authenticated:

```bash
gh auth status
```

If `gh` reports the user is not authenticated, abort and tell them to
run `gh auth login` (with `repo` and `admin:read` scope so App
discovery in `skills/lib/gh-app.md` works). Setting **org** secrets
(`--secret-scope organization`, Step 7) additionally requires the
`admin:org` scope; note this in the abort message when org scope is
selected. The org-level **read** in Step 7a's already-exists pre-check
(`gh secret list --org`) also benefits from `admin:org`, but it is
best-effort: without that scope the org list is simply unavailable and
the pre-check falls back to the repo-level names — it never hard-fails on
a missing org scope.

## Step 2: Resolve environment-inferred placeholders

Per the resolution order in `${CLAUDE_PLUGIN_ROOT}/payload/README.md`, infer the
environment placeholders from the target repo:

```bash
gh_org="$(gh repo view --json owner -q .owner.login)"
gh_repo="$(gh repo view --json name -q .name)"
default_branch="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
```

These resolve `__GH_ORG__`, `__GH_REPO__`, and `__DEFAULT_BRANCH__`.

## Step 3: Resolve the GitHub App

Run the find/verify sequence in `skills/lib/gh-app.md` (Steps 1–5) with:

```text
required_permissions = { contents: write, pull_requests: write }
target_repo          = <gh_org>/<gh_repo>
```

If the user passed `--app-name <slug>`, follow the
"User-supplied App name (skip discovery)" path in `skills/lib/gh-app.md`
instead of the multi-candidate discovery.

Do **not** duplicate the discovery, prompt, or verification logic here —
follow the lib by step number. The lib handles all selection and
abort-on-no-candidate cases, including the "no suitable candidate"
branch that points the user at `/gh-create-app`. This skill does
**not** create an App; it only consumes an existing one.

On success the lib returns:

```text
app_slug:        <app_slug>
app_id:          <app_id>
installation_id: <installation_id>
```

Map per `skills/lib/gh-app.md` → "Placeholder values derived from an
App":

- `__APP_NAME__` ← `app_slug`
- `__APP_ID__`   ← `app_id`

## Step 4: Resolve the remaining placeholders

The two workflow templates use these additional placeholders. Resolve
each before rendering:

| Placeholder | Default | Meaning |
| --- | --- | --- |
| `__APP_ID_SECRET__` | `AUTOMERGE_APP_ID` | Repo secret name holding the App ID. Derived as `<secret_prefix>_APP_ID` from the secret prefix (default `AUTOMERGE`, override with `--secret-prefix`). |
| `__APP_PRIVATE_KEY_SECRET__` | `AUTOMERGE_APP_PRIVATE_KEY` | Repo secret name holding the App private key. Derived as `<secret_prefix>_APP_PRIVATE_KEY` from the secret prefix. |
| `__MERGE_METHOD__` | `MERGE` | GraphQL merge method: `MERGE`, `SQUASH`, or `REBASE`. Must be an enabled merge method on the repo. |
| `__DO_NOT_MERGE_LABEL__` | `do-not-merge` | Label that opts a PR out of auto-merge and auto-rebase. |
| `__BOT_SLUG__` | `<gh_repo>-auto-rebase[bot]` | Git identity used for rebase commits. |
| `__REQUIRED_CHECK_WORKFLOW__` | (none) | Name of the repo's required-check workflow whose completion should trigger a rebase pass. |

Discover the exact placeholder set each template needs with the scan
from `${CLAUDE_PLUGIN_ROOT}/payload/README.md`:

```bash
grep -ohE '__[A-Z][A-Z0-9_]*__' \
  ${CLAUDE_PLUGIN_ROOT}/payload/gh-repo-setup-pr-automation/*.yml \
  | sort -u
```

`__MERGE_METHOD__`, `__DO_NOT_MERGE_LABEL__`, and `__BOT_SLUG__` take
the defaults above unless the user passed an override flag
(`--merge-method`, `--do-not-merge-label`, `--bot-slug`).

`__APP_ID_SECRET__` and `__APP_PRIVATE_KEY_SECRET__` are the App-identity
secret names, derived from a single secret prefix (default `AUTOMERGE`,
override with `--secret-prefix`):
`__APP_ID_SECRET__` = `<secret_prefix>_APP_ID` and
`__APP_PRIVATE_KEY_SECRET__` = `<secret_prefix>_APP_PRIVATE_KEY`. The
prefix and the suffix are joined when computing each secret name (see
the render recipe in Step 6), so the templates carry no bare
`__SECRET_PREFIX__` placeholder that would abut the suffix.

`__REQUIRED_CHECK_WORKFLOW__` has no default. Resolve it as follows:

1. If the user passed `--required-check-workflow <name>`, use it.
2. Otherwise, list the repo's workflows
   (`gh workflow list` / inspect `.github/workflows/`) and, if exactly
   one looks like a required PR check (e.g. a `no-back-merging-guard` or
   similar PR-gate workflow), propose it and ask the user to confirm.
3. If none is found or the user declines, **drop the `workflow_run`
   trigger entirely** when rendering `auto-rebase-prs.yml` (remove the
   two `workflow_run:` lines and the `workflows:`/`types:` sub-lines).
   The remaining triggers (push, schedule, dispatch, `/rebase`) still
   give full coverage; `workflow_run` is an optimisation that fires a
   rebase pass the instant a required check completes.

A template must never render with an unresolved placeholder. If any
remain after this step, abort per `${CLAUDE_PLUGIN_ROOT}/payload/README.md`:

> Unresolved placeholder `__NAME__` in template
> `gh-repo-setup-pr-automation/<file>`. Pass a value or add inference
> logic.

## Step 5: Halt #1 — confirm resolved values

Present the resolved values and ask for explicit confirmation before
writing any files or touching GitHub secrets. Use this shape:

```text
About to install PR-automation workflows with:

  Repo:               <gh_org>/<gh_repo>
  Default branch:     <default_branch>
  GitHub App:         <app_slug> (ID <app_id>, install <installation_id>)
  Secret prefix:      <secret_prefix>   (sets <prefix>_APP_ID + <prefix>_APP_PRIVATE_KEY)
  Secret scope:       <repository | organization (--visibility all)>
  Merge method:       <merge_method>
  do-not-merge label: <do_not_merge_label>
  Rebase bot identity:<bot_slug>
  Required-check wf:   <required_check_workflow | (none — workflow_run dropped)>

Will RENDER into the repo, then COMMIT + PUSH + PR on a single
approval (Step 6b — branch gh-repo-setup-pr-automation, targeting
<default_branch>):
  .github/workflows/auto-enable-automerge.yml
  .github/workflows/auto-rebase-prs.yml

Will SET (at the <repository | organization> scope; org requires admin:org):
  secret <prefix>_APP_ID            (set by the skill)
  secret <prefix>_APP_PRIVATE_KEY   (Step 7 offers: you run the command,
                                     or the skill pipes in your .pem)
  — Step 7 skips the scope prompt and the set entirely if both
    <prefix>_APP_ID and <prefix>_APP_PRIVATE_KEY already exist at the
    repo or org level.

Proceed? (y to continue, or tell me what to change)
```

This halt confirms the resolved values; the commit + push + PR of the
rendered files is a **second**, separate single approval at Step 6b, and
the private-key path is a further prompt at Step 7 (unless skipped per
Step 7a). Approving here does not imply approving the commit/push.

Wait for explicit approval (`y`, `yes`, `go`, `do it`). If the user
asks to change a value, update it and re-display this halt.

## Step 6: Render and write the workflow files

For each template in
`${CLAUDE_PLUGIN_ROOT}/payload/gh-repo-setup-pr-automation/`, perform
the string substitution from `${CLAUDE_PLUGIN_ROOT}/payload/README.md`
("Rendering a template") and write the result into the repo under
`.github/workflows/`.

Reference render recipe (one substitution per discovered placeholder):

```bash
src=${CLAUDE_PLUGIN_ROOT}/payload/gh-repo-setup-pr-automation
dst="$(git rev-parse --show-toplevel)/.github/workflows"
mkdir -p "$dst"
# Compute the two App-identity secret names from the single prefix, then
# substitute the fully-formed names. The templates carry distinct
# __APP_ID_SECRET__ / __APP_PRIVATE_KEY_SECRET__ placeholders rather than
# a bare __SECRET_PREFIX__ abutting "_APP_ID", so the discovery scan never
# reports a spurious __SECRET_PREFIX___ token.
app_id_secret="${secret_prefix}_APP_ID"
app_private_key_secret="${secret_prefix}_APP_PRIVATE_KEY"
for f in auto-enable-automerge.yml auto-rebase-prs.yml; do
  rendered="$(cat "$src/$f")"
  rendered="${rendered//__GH_ORG__/$gh_org}"
  rendered="${rendered//__GH_REPO__/$gh_repo}"
  rendered="${rendered//__DEFAULT_BRANCH__/$default_branch}"
  rendered="${rendered//__APP_NAME__/$app_slug}"
  rendered="${rendered//__APP_ID__/$app_id}"
  rendered="${rendered//__APP_ID_SECRET__/$app_id_secret}"
  rendered="${rendered//__APP_PRIVATE_KEY_SECRET__/$app_private_key_secret}"
  rendered="${rendered//__MERGE_METHOD__/$merge_method}"
  rendered="${rendered//__DO_NOT_MERGE_LABEL__/$do_not_merge_label}"
  rendered="${rendered//__BOT_SLUG__/$bot_slug}"
  rendered="${rendered//__REQUIRED_CHECK_WORKFLOW__/$required_check_workflow}"
  printf '%s\n' "$rendered" > "$dst/$f"
done
```

If `__REQUIRED_CHECK_WORKFLOW__` was dropped (Step 4 case 3), strip the
`workflow_run:` trigger block from `auto-rebase-prs.yml` after rendering
rather than substituting a value — leaving an empty `workflows: []`
would make the workflow file invalid.

The leading `__APP_ID__` substitution is harmless even though neither
template currently references `__APP_ID__` (the App ID lives only in the
repo secret, not in the YAML). Keeping it in the recipe means the render
still works if a future template version inlines the App ID.

After rendering, verify no placeholder survived:

```bash
grep -nE '__[A-Z][A-Z0-9_]*__' "$dst"/auto-*.yml && \
  echo "UNRESOLVED PLACEHOLDER — abort" || echo "clean"
```

These files are written to the working tree here; Step 6b commits,
pushes, and PRs them on a single approval.

## Step 6b: Commit, push, and open a PR for the rendered files

After rendering its files (Step 6), the skill **commits, pushes, and
opens a PR** for those files — **always**, on a **single approval**.
There is no flag to disable this and no "am I being orchestrated?" knob:
the skill always produces a PR for its own rendered files. Only the
**rendered workflow files** go through this branch → commit → push → PR
flow. The **secret operations** (Step 7) are not file edits and cannot
live in a PR, so they continue to apply **directly** to the repo (or org)
as they do now.

### Skip cleanly when there is nothing to commit

If neither rendered file changed (a re-run against a repo whose workflow
files are already byte-for-byte identical), there is **nothing to
commit**: skip this step entirely, report "no file changes to commit; no
PR opened", and proceed to Step 7. A no-op re-run must not produce an
empty PR. Check with:

```bash
git status --short -- .github/workflows/auto-enable-automerge.yml \
                      .github/workflows/auto-rebase-prs.yml
```

If that prints nothing, the working tree already matches; skip to Step 7.

### Present the changes and get one approval

Show the operator the rendered file changes (the diff) and ask for a
single approval that covers commit + push + PR together — **not** three
separate prompts:

```bash
git status --short -- .github/workflows/
git diff -- .github/workflows/auto-enable-automerge.yml \
            .github/workflows/auto-rebase-prs.yml
```

```text
gh-repo-setup-pr-automation rendered these files:
  .github/workflows/auto-enable-automerge.yml
  .github/workflows/auto-rebase-prs.yml

On approval I will, in one go:
  1. Commit them on a branch named after this skill
     (gh-repo-setup-pr-automation).
  2. Push that branch.
  3. Open a PR targeting the default branch (<default_branch>).

The App-identity secrets (Step 7) are not file edits and are applied
directly to the repo/org, NOT as part of this PR.

Proceed with commit + push + PR? (y to do all three, or no to leave the
files uncommitted for you to handle)
```

If the operator declines, leave the rendered files uncommitted in the
working tree and report "files left uncommitted at operator's request;
no PR opened". Do not partially commit. The single approval still
satisfies global rule §0 — the operator explicitly approves before any
commit / push.

### Commit, push, and open the PR

On approval, do all three with no further prompts:

```bash
# Branch named after the skill. Create it from the current default-branch
# tip if it does not exist; reuse it if a prior run left it.
git switch -c gh-repo-setup-pr-automation \
  || git switch gh-repo-setup-pr-automation

git add -- .github/workflows/auto-enable-automerge.yml \
           .github/workflows/auto-rebase-prs.yml
git commit -m "Install PR-automation workflows (gh-repo-setup-pr-automation)"

git push -u origin gh-repo-setup-pr-automation

gh pr create --base "$default_branch" \
  --head gh-repo-setup-pr-automation \
  --title "Install PR-automation workflows" \
  --body "Rendered by /gh-repo-setup-pr-automation: the auto-merge
enablement and auto-rebase workflows. The App-identity secrets are
applied directly to the repo/org and are not part of this PR."
```

Capture and report the PR URL. If a PR already exists for the branch
(`gh pr create` reports it), report that URL instead of failing.

This branch name (`gh-repo-setup-pr-automation`, the skill's own name)
and PR are what the `/gh-repo-setup-public` orchestrator detects
generically (its Step 2a/2b) so it can offer to merge this skill's PR —
no orchestrator change is needed; the detection is branch-name-by-
sub-skill-name and was written to anticipate this skill.

## Step 7: Set the App-identity secrets

Set the two secrets the workflows consume. A workflow reading
`${{ secrets.FOO }}` resolves an **org-level** secret and a
**repo-level** secret identically — GitHub does the resolution — so the
scope choice below changes only the `gh secret set` target, never the
rendered workflow YAML.

### 7a. Skip the whole step when both secrets already exist

Before resolving the secret scope, prompting, or setting anything, check
whether both App-identity secret **names** already exist — at **either**
the repo or the org level. If they do, the workflows already resolve them
(GitHub resolves `${{ secrets.FOO }}` from org or repo identically), so
there is **nothing to decide or set**: skip the scope resolution
(below), skip the private-key path prompt, and skip every `gh secret set`
call.

The only signal available — and the only one needed — is **name
existence**. The GitHub API exposes secret **names** but never their
**values**, so the skill **cannot** read or validate a secret's value;
name-existence is the whole check. Do not attempt to verify the value.

List the secret names at both scopes and look for both
`<prefix>_APP_ID` and `<prefix>_APP_PRIVATE_KEY`:

```bash
# Repo-level secret names (always available to a repo admin).
gh secret list --repo "$gh_org/$gh_repo"
# Org-level secret names (requires admin:org; treat a permission error
# as "no org secrets visible" rather than a hard failure).
gh secret list --org "$gh_org" 2>/dev/null || true
```

Both names are `${secret_prefix}_APP_ID` and
`${secret_prefix}_APP_PRIVATE_KEY` (the same names rendered into the
workflows in Step 6). The check passes when **both** names appear at the
**org** level, **or both** appear at the **repo** level, **or** the two
names are split such that each appears at one level or the other — in
short, when each of the two names exists at **either** scope.

- **If both names already exist** (at either scope): treat the secrets as
  set. **Skip the scope resolution, the private-key prompt, and all
  `gh secret set` calls in the rest of Step 7.** Report:

  > App-identity secrets already present (`<prefix>_APP_ID`,
  > `<prefix>_APP_PRIVATE_KEY` found at `<repo | org | repo+org>`);
  > skipping scope resolution and secret set.

  Existence at the **org** level is sufficient — an org-level secret
  resolves fine for the workflow, so there is **no** need to also place a
  repo-level copy. Do not "upgrade" or "mirror" an org secret to the repo.

- **If one or both names are missing**: fall through to the existing
  scope-resolution + set flow below. Only the missing secret(s) actually
  need setting, but re-running the set for an already-present name is
  harmless (`gh secret set` overwrites), so the flow below may set both;
  the point of this pre-check is to avoid the scope prompt and the set
  entirely in the common already-configured case.

### Resolve the secret scope

The secrets can be stored at the **repository** level (default — set on
the current repo only) or at the **organization** level (set once for
the whole org with `--visibility all`, so every repo in `<gh_org>` can
read them — set and rotate the key once instead of once per repo). Org
secrets require the `admin:org` scope on the `gh` token; repo secrets
only need repo admin.

If the user passed `--secret-scope <repository|organization>`, use it.
Otherwise offer the choice and default to **repository**:

```text
Where should the App-identity secrets be stored?

  1. Repository (default) — set on <gh_org>/<gh_repo> only.
  2. Organization — set once on the <gh_org> org with --visibility all,
     so every repo in the org can read them. Requires admin:org.

[1]:
```

In the commands below, `<scope-target>` stands for the chosen scope's
`gh secret set` target flags:

- **repository** → `--repo "$gh_org/$gh_repo"`
- **organization** → `--org "$gh_org" --visibility all`

`gh secret set` overwrites an existing secret of the same name at the
chosen scope, so re-running remains convergent.

### App ID

The App ID is non-secret, so the skill sets it directly either way (it
is stored as a secret for symmetry with the private key). Use the
scope's `<scope-target>` flags:

```bash
# repository scope (default)
gh secret set "${secret_prefix}_APP_ID" \
  --repo "$gh_org/$gh_repo" \
  --body "$app_id"
# organization scope
gh secret set "${secret_prefix}_APP_ID" \
  --org "$gh_org" --visibility all \
  --body "$app_id"
```

### Private key

The private key is sensitive, and some users do not want the agent
reading their `.pem` or running a command against it in-session. So,
before setting `<prefix>_APP_PRIVATE_KEY`, **offer two paths** and
default to command-only. This command-only-vs-skill-sets-it choice is
independent of the repo-vs-org scope chosen above: the scope decides the
`<scope-target>` flags, the path decides who runs the command.

```text
How do you want to set the <prefix>_APP_PRIVATE_KEY secret?

  1. Hand me the command (default, recommended) — I print the exact
     `gh secret set ... < /path/to/key.pem` command and you run it in
     your own terminal. Your private key never enters this session.
  2. I set it for you — give me the path to the .pem and I pipe it into
     `gh secret set` via stdin.

[1]:
```

If the user passed `--app-private-key <path>`, treat that as an explicit
choice of path 2 and skip the prompt. Otherwise the default (empty
answer or `1`) is **path 1**.

### Path 1 — command-only (default)

Print the exact command for the user to run in their own terminal.
Always use a stdin redirect (`< path`), never `--body` — `--body` would
put the key in argv (and shell history). Substitute the real
`<prefix>`, the chosen scope's `<scope-target>` flags, but leave the
`.pem` path as a placeholder for the user to fill in (the key path never
needs to enter this session). Print the line matching the chosen scope:

```text
Run this in your terminal, with the path to your App's .pem:

  # repository scope (default)
  gh secret set <prefix>_APP_PRIVATE_KEY \
    --repo <org>/<repo> \
    < /path/to/your-app.private-key.pem

  # organization scope
  gh secret set <prefix>_APP_PRIVATE_KEY \
    --org <org> --visibility all \
    < /path/to/your-app.private-key.pem

Then verify it landed (run the line matching the chosen scope):

  # repository scope (default)
  gh secret list --repo <org>/<repo>

  # organization scope
  gh secret list --org <org>

Tell me `done` once the secret is set.
```

Wait for the user to confirm `done`. Optionally confirm the secret is
present yourself, using the chosen scope's listing target (`--repo
"$gh_org/$gh_repo"` for repo scope, `--org "$gh_org"` for org scope):

```bash
# repository scope (default)
gh secret list --repo "$gh_org/$gh_repo"
# organization scope
gh secret list --org "$gh_org"
```

### Path 2 — skill sets it

The user supplies the path to the App's `.pem` private-key file (via
`--app-private-key <path>` or interactively). If `--app-private-key
<path>` was **not** passed, ask for the path before running the stdin
pipe:

```text
Path to the App's .pem private-key file:
```

Then pipe the file to `gh secret set` via stdin — never expand the key
into the conversation or into shell argv. Use the chosen scope's
`<scope-target>` flags:

```bash
# repository scope (default)
gh secret set "${secret_prefix}_APP_PRIVATE_KEY" \
  --repo "$gh_org/$gh_repo" \
  < "<expanded-private-key-path>"
# organization scope
gh secret set "${secret_prefix}_APP_PRIVATE_KEY" \
  --org "$gh_org" --visibility all \
  < "<expanded-private-key-path>"
```

### No private-key file yet

If the user does not have the private-key file (e.g. they only just
created the App), tell them: the App's owner generates a private key in
the App settings (`Settings → Developer settings → GitHub Apps →
<app> → Private keys → Generate a private key`), downloads the `.pem`,
and re-runs this skill (with `--app-private-key <path>` to pick path 2,
or with no key flag to get the command-only path 1). The
`<prefix>_APP_ID` secret is already set at the chosen scope, so a re-run
only needs to set the key secret — pass the same `--secret-scope` on the
re-run so the key lands at the same scope as the ID.

## Step 8: Print the next-steps checklist

If the user took the command-only path for the private key (Step 7
path 1), word the private-key line as "set by you" rather than implying
the skill set it. Word the secret lines to match what Step 7 actually
did: "already present (skipped)" when Step 7a short-circuited, otherwise
"set by the skill" / "set by you". Word the PR line to match Step 6b:
the PR URL when one was opened, "no file changes to commit" on a no-op
re-run, or "left uncommitted at operator's request" if the operator
declined the Step 6b approval.

```text
PR-automation install complete.

App-identity secrets — set at the <repository | organization> scope
(<gh_org>/<gh_repo> for repo scope; the <gh_org> org for org scope):
  - secret <prefix>_APP_ID            (set by the skill | already present (skipped))
  - secret <prefix>_APP_PRIVATE_KEY   (set by the skill, or by you via
                                       the command-only path |
                                       already present (skipped))

Rendered-files PR (branch gh-repo-setup-pr-automation, Step 6b):
  <PR URL | no file changes to commit | left uncommitted at operator's request>
  - .github/workflows/auto-enable-automerge.yml
  - .github/workflows/auto-rebase-prs.yml

Next steps:
  1. Review and merge the rendered-files PR above (if one was opened);
     the workflows take effect once on the default branch.
  2. Verify end-to-end (operational, see "Live verification" below).
```

## Live verification (operational — the human runs this)

The "verified end-to-end" acceptance criterion needs live secrets, an
installed App, and a real PR. It cannot be exercised inside a worktree.
After the rendered-files PR (Step 6b) is merged and the workflows are on
the default branch, the human:

1. **Auto-merge**: open a non-draft PR against the default branch. The
   `auto-enable-automerge` workflow should run and the PR should show
   "auto-merge enabled" in the GitHub UI. Confirm with:

   ```bash
   gh pr view <num> --json autoMergeRequest -q .autoMergeRequest
   ```

2. **`/rebase` responder**: on a PR that is behind the base branch,
   a write/admin collaborator comments `/rebase`. The `auto-rebase-prs`
   workflow should run, authorize the commenter, rebase the branch, and
   force-push. Confirm the PR head moved and the run logged
   `rebased and force-pushed`.

3. **Scheduled sweep**: leave a behind PR and wait for the `*/20` cron
   tick (or trigger manually with
   `gh workflow run auto-rebase-prs.yml`). Confirm the behind PR is
   rebased.

If the first run fails at "Mint App installation token", the secrets
are missing or the App is not installed on this repo — re-check Step 7
and `skills/lib/gh-app.md` Step 4 (installation on the target repo).

---

## Halts and approval gates (summary)

- **Halt #1 (Step 5)** — confirm all resolved values (including the
  secret scope) before any file render or secret set.
- **The Step 6b commit/push/PR approval** — a single approval that
  covers commit + push + PR of the rendered workflow files (on the
  `gh-repo-setup-pr-automation` branch, targeting the default branch).
  This is separate from Halt #1; approving the resolved values does not
  imply approving the commit/push. Declining leaves the files
  uncommitted. A no-op re-run (no file changes) skips this and opens no
  PR.
- The secret-scope prompt in Step 7 (skipped when `--secret-scope` was
  passed, or when Step 7a finds both secrets already present):
  repository (default) or organization with `--visibility all`.
- The private-key path prompt in Step 7 (also skipped by Step 7a when
  both secrets already exist): the skill asks how to set
  `<prefix>_APP_PRIVATE_KEY` (command-only, default; or skill-sets-it).
  Command-only then waits for the user to confirm `done`; skill-sets-it
  waits for the `.pem` path when `--app-private-key` was not supplied.

---

## Inputs (flags)

All optional except where the skill prompts:

- `--app-name <slug>` — skip App discovery; verify this App directly
  (see `skills/lib/gh-app.md`).
- `--app-private-key <path>` — path to the App's `.pem` private key.
  Passing this selects the **skill-sets-it** path in Step 7 (the skill
  pipes the file into `gh secret set` via stdin). Omit it to get the
  Step 7 prompt, which defaults to the **command-only** path where the
  skill prints a `gh secret set ... < path` command for you to run
  yourself and your key never enters the session.
- `--secret-prefix <prefix>` — prefix for the App-identity secret names
  `<prefix>_APP_ID` and `<prefix>_APP_PRIVATE_KEY`, which fill the
  `__APP_ID_SECRET__` / `__APP_PRIVATE_KEY_SECRET__` placeholders
  (default `AUTOMERGE`).
- `--secret-scope <repository|organization>` (default `repository`) —
  where the App-identity secrets are stored. `repository` sets them on
  the current repo only. `organization` sets them as **org** secrets
  with `--visibility all` so every repo in the org can read them — set
  and rotate the key once for the whole org instead of once per repo. A
  workflow's `${{ secrets.FOO }}` resolves an org-level and a repo-level
  secret identically, so no workflow-template change is involved. Org
  secrets require the `admin:org` scope on the `gh` token (repo admin is
  enough for repo secrets). Omit the flag to get the Step 7 prompt,
  which defaults to **repository**. Note: if both App-identity secrets
  already exist at the repo or org level, Step 7a skips the scope
  resolution and the set entirely, so this flag has no effect on that
  run.
- `--merge-method <MERGE|SQUASH|REBASE>` — override `__MERGE_METHOD__`
  (default `MERGE`).
- `--do-not-merge-label <label>` — override `__DO_NOT_MERGE_LABEL__`
  (default `do-not-merge`).
- `--bot-slug <name>` — override `__BOT_SLUG__` (default
  `<repo>-auto-rebase[bot]`).
- `--required-check-workflow <name>` — name of the required-check
  workflow whose completion triggers a rebase pass. Omit to have the
  skill propose one or drop the `workflow_run` trigger.

---

## Hard constraints

- **Never run before the payload existence check (Step 0) and
  pre-flight (Step 1) pass.** Each abort message names what failed and
  what to do.
- **Never create a GitHub App.** This skill consumes an existing App via
  the find/verify path in `skills/lib/gh-app.md`. The "no suitable
  candidate" branch points at `/gh-create-app`; do not implement
  App creation here.
- **Never duplicate `skills/lib/gh-app.md` logic.** Reference its steps
  by number.
- **Commit + push + PR the rendered files on a single approval, always.**
  After rendering its files (Step 6), the skill commits, pushes, and
  opens a PR for them on a branch named after the skill
  (`gh-repo-setup-pr-automation`), targeting the default branch — on
  **one** approval covering all three (Step 6b). There is no `--commit`
  flag, no opt-out, no "am I being orchestrated?" knob: the skill always
  produces a PR for its own rendered files. The single approval still
  satisfies global rule §0 (the operator explicitly approves before any
  commit / push). A no-op re-run with no file changes opens no PR. This
  supersedes the old "writes them uncommitted; the user reviews and
  commits" stance for this skill's own rendered files. The **secret
  operations** (Step 7) are not file edits and cannot live in a PR, so
  they continue to apply directly.
- **Skip the secret-scope work when both secrets already exist (Step
  7a).** Before resolving the secret scope, prompting, or setting
  anything, check whether both `<prefix>_APP_ID` and
  `<prefix>_APP_PRIVATE_KEY` **names** already exist at the repo **or**
  org level (`gh secret list`). If both do, skip the scope prompt and
  every `gh secret set` call — existence at the org level alone is
  sufficient (an org secret resolves fine for the workflow). The skill
  **cannot** read a secret's value (the API exposes names, never values),
  so name-existence is the whole check; never attempt to validate the
  value.
- **Never print private key material to the conversation.** On the
  skill-sets-it path, pipe the `.pem` into `gh secret set` via stdin
  (Step 7 path 2). On the command-only path (Step 7 path 1, the
  default), print a `gh secret set ... < path` command with a
  placeholder `.pem` path and let the user run it — never `--body`,
  which would put the key in argv. Either way the key never enters the
  session.
- **Never fall back to `GITHUB_TOKEN`.** The workflows require the App
  identity; the default token cannot enable auto-merge and its pushes
  do not re-trigger required checks. This is by design and reflected in
  the template comments.
- **Never edit anything outside the current repo.** The skill writes
  under `<repo-root>/.github/workflows/`; the remote changes are the
  rendered-files PR on the `gh-repo-setup-pr-automation` branch (Step 6b
  — a normal push of files under `.github/workflows/` to this repo) and
  the two App-identity secrets, set either on the current repo
  (repository scope, default) or on the current repo's owning org
  (organization scope) per Step 7's `--secret-scope`. Org scope writes
  org-level secrets for `<gh_org>` and touches no other repo's files.

---

## Out of scope

- **GitHub App creation.** Owned by the `/gh-create-app` skill. This
  skill runs against an existing App.
- **The required-check / no-back-merging guard workflow itself.** That
  is a branch-protection concern owned by `/gh-repo-setup-protection`,
  which installs the `no-back-merging-guard` workflow (and its script +
  self-test) unconditionally and registers it as a required check; this
  skill only optionally references such a workflow via the
  `workflow_run` trigger.
- **Branch-protection rulesets.** Auto-merge only merges once required
  checks pass, but configuring which checks are required is out of
  scope.
- **The live end-to-end verification.** The skill installs everything so
  the human can verify; performing the live PR test requires real
  secrets and a real PR and is the human's operational step (see "Live
  verification").
