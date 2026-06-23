---
name: gh-create-app
description: "Create (from scratch) an org- or enterprise-scoped GitHub App for workflow authentication — walk the UI-gated registration with starter PR-automation permissions, install it on the target repo(s), set App ID + private key as secrets, verify a minted installation token, and save a checked-in metadata doc. Idempotent: detects an already-configured App and offers to verify instead of re-creating."
---

You are running the `/gh-create-app` skill. Your job is to provision a
**new** GitHub App for workflow authentication, scoped at the **org or
enterprise** level, and wire it up for the current repo:

1. Walk the user through the **UI-gated** App registration (GitHub
   does not expose an API to create an App from nothing) with the
   right permissions for the intended automation scope.
2. Walk the user through **installing** the App on the target repo(s).
3. **Collect** the App ID and the generated private key.
4. **Set** them as repo (or org) secrets via `gh secret set`.
5. **Document** the standard workflow snippet for minting an
   installation token and exposing it to downstream steps.
6. **Verify** that a minted installation token can call a
   representative API as the App.
7. **Save** App metadata (name, ID, install URL, granted permissions)
   to a checked-in doc.

This skill is the **create-from-scratch path** of
`skills/lib/gh-app.md`. The find/verify path (detecting and validating
an *existing* App) already lives in that library; this skill is what
the library's "no suitable candidates" branch points users at. When an
App already exists, this skill **detects it and offers to verify
rather than re-create** (see "Idempotency").

There is **no such thing as a per-repo GitHub App.** Apps are owned by
an organization or an enterprise and *installed onto* repos. The
`--scope` flag (or the prompt in its absence) chooses org vs.
enterprise ownership.

The skill **does not commit** the metadata doc it writes (global rule
§0: never commit without approval). Remote changes it *does* apply
directly — setting secrets via `gh secret set` — are reported, and
re-running converges (a secret that is already set is overwritten with
the same value, reported as such).

---

## Inputs

All optional; the skill prompts for anything it needs and cannot
infer.

- `--scope=org|enterprise` (no default): ownership scope of the App.
  In its absence the skill **prompts** (org vs. enterprise) before
  the registration walkthrough.
- `--app-name=<slug>`: the intended App name/slug. Used for the
  idempotency check (does an App by this slug already exist and
  resolve via `skills/lib/gh-app.md`?) and recorded in the metadata
  doc. If omitted, the skill asks for it before registration.
- `--owner=<org-or-enterprise-slug>`: the org or enterprise login that
  will own the App. Defaults to the current repo's owner
  (`gh repo view --json owner -q .owner.login`) for `--scope=org`;
  prompted for `--scope=enterprise`.
- `--target-repo=<owner/repo>`: the repo to install the App on and set
  secrets on. Defaults to the current repo
  (`gh repo view --json nameWithOwner -q .nameWithOwner`).
- `--secret-scope=repository|organization` (default `repository`):
  where the App ID and private-key secrets are stored. `organization`
  sets them as org secrets (shared across repos); `repository` sets
  them on `--target-repo` only.
- `--app-id-secret=<NAME>` (default `WORKFLOW_APP_ID`): name of the
  secret that holds the App ID.
- `--app-key-secret=<NAME>` (default `WORKFLOW_APP_PRIVATE_KEY`): name
  of the secret that holds the private key.
- `--metadata-path=<path>` (default `docs/github-app.md`, repo-root
  relative): where the checked-in metadata doc is written.
- `--permissions=<starter|custom>` (default `starter`): the permission
  set requested at registration. `starter` is the PR-automation set
  below; `custom` prompts the user for the scopes.

If the user passed nothing, use the defaults above and prompt for the
non-defaulted required inputs (`--scope`, `--app-name`, and `--owner`
for enterprise scope).

### Starter permission set (PR automation)

The default `--permissions=starter` requests exactly:

| Permission | Access | Why |
| --- | --- | --- |
| Pull requests | Read and write | open / approve / merge / label PRs |
| Contents | Read and write | push branches, create commits |
| Metadata | Read-only | mandatory; GitHub auto-selects it |

**No webhook.** This App mints installation tokens in CI; it does not
receive event deliveries. Leave "Active" under Webhook **unchecked**
during registration.

The corresponding `required_permissions` map (the shape
`skills/lib/gh-app.md` and consuming skills use) is:

```text
{ pull_requests: write, contents: write, metadata: read }
```

For `--permissions=custom`, ask the user which scopes and levels they
need, then carry that map through the walkthrough and the metadata doc
in place of the starter set.

---

## Step 0: Payload

The template payloads this skill renders ship with the plugin at
`${CLAUDE_PLUGIN_ROOT}/payload/gh-create-app/`. The placeholder/render
convention is documented in `${CLAUDE_PLUGIN_ROOT}/payload/README.md`.

## Step 1: Pre-flight — repo root, auth, identifiers, inputs

Confirm you are inside a git working tree and capture the root:

```bash
git rev-parse --show-toplevel
```

If it fails, abort with:

> `/gh-create-app` must be run from inside a git repository. The
> current directory is not a git working tree.

Confirm `gh` is authenticated:

```bash
gh auth status
```

If not authenticated, abort and tell the user to run `gh auth login`.
Setting **org** secrets requires `admin:org`; **enterprise**-scoped
App management requires enterprise-owner rights. Note these in the
abort message when the relevant scope is selected.

Resolve identifiers and inputs:

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # default --target-repo
gh repo view --json owner -q .owner.login             # default --owner (org scope)
gh repo view --json defaultBranchRef -q .defaultBranchRef.name
```

Resolve `--scope` (prompt if absent), `--app-name` (prompt if absent),
and `--owner` (default for org; prompt for enterprise). Echo the
resolved configuration back to the user before proceeding:

```text
gh-create-app — planned configuration
  Scope:            <org|enterprise>
  Owner:            <owner>
  App name:         <app-name>
  Target repo:      <owner/repo>
  Secret scope:     <repository|organization>
  App ID secret:    <APP_ID_SECRET>
  Private-key secret: <APP_KEY_SECRET>
  Permissions:      <starter|custom> → <required_permissions map>
  Metadata doc:     <metadata-path>
```

## Step 2: Idempotency — does a suitable App already exist?

Before walking the UI, run the **find/verify** path of
`skills/lib/gh-app.md` (Steps 1–4) with
`required_permissions` = the resolved permission map and
`target_repo` = `--target-repo`. If an `--app-name` was supplied, use
the "User-supplied App name (skip discovery)" path from that library.

- **A suitable App is found and installed on the target repo** — do
  **not** re-create. Report what was found and offer to **verify**
  instead:

  > GitHub App `<app_slug>` (ID `<app_id>`) already exists, has
  > sufficient permissions, and is installed on `<owner/repo>`.
  > Re-creating would produce a duplicate App. Proceed to verify the
  > secrets and refresh the metadata doc instead? (Steps 4–7.)

  On confirmation, skip Steps 3 (registration) and go to Step 4 using
  the existing App's `app_id` / `app_slug`. The skill still needs the
  private key for the verify step if the secret is not already set —
  ask the user to generate one in the App settings if so.

- **An App exists by the requested name but is missing permissions or
  not installed on the repo** — report the gap (the library's "missing
  permissions" / "not configured for repo" message) and tell the user
  to fix it in the App settings, then re-run. Do **not** create a
  second App with the same intent.

- **No suitable App** — proceed to Step 3 (registration).

This is the create branch's half of the idempotency contract; the
find/verify half is owned by `skills/lib/gh-app.md`.

## Step 3: Walk the UI-gated registration

GitHub gates App **creation** behind the web UI; there is no API to
create an App from nothing (see "Out of scope"). The skill therefore
**guides** the user and waits. Print the steps and **halt** for the
user to complete them.

### 3a. Open the right "New GitHub App" page

- **Org scope:**
  `https://github.com/organizations/<owner>/settings/apps/new`
- **Enterprise scope:**
  `https://github.com/enterprises/<owner>/settings/apps/new`

### 3b. Fill the registration form

Tell the user to set:

- **GitHub App name:** `<app-name>` (must be globally unique; if taken,
  pick a variant and tell the skill the final slug).
- **Homepage URL:** the repo URL is fine
  (`https://github.com/<owner/repo>`).
- **Webhook → Active:** **uncheck.** No webhook is needed for
  token-minting.
- **Permissions → Repository permissions:** set exactly the resolved
  map. For the starter set:
  - Pull requests: **Read and write**
  - Contents: **Read and write**
  - Metadata: **Read-only** (auto-selected; leave it)
- **Where can this GitHub App be installed?** "Only on this account"
  is the right choice for an internal automation App.

Then **Create GitHub App**.

### 3c. Capture the App ID and generate a private key

After creation, on the App's settings page:

- Note the **App ID** (a number near the top).
- Scroll to **Private keys** → **Generate a private key.** The browser
  downloads a `.pem` file. **Halt** and ask the user for:
  - the **App ID** (number), and
  - the **filesystem path** to the downloaded `.pem` file.

Do **not** ask the user to paste the private-key *contents* into the
conversation. Only the *path* is collected; the key material is piped
straight into `gh secret set` via stdin in Step 4 and never printed.

### 3d. Install the App on the target repo(s)

Direct the user to the App's **Install App** tab, install it on
`<owner>`, and under "Repository access" select **Only select
repositories** → `<target-repo>` (or "All repositories" if that is the
intent). **Halt** until the user confirms the install is done.

Then verify the installation programmatically via the user-token path
from `skills/lib/gh-app.md` Step 4:

```bash
gh api "/user/installations" --paginate --jq \
  '.installations[] | select(.app_slug == "<app-slug>") | .id'
```

```bash
gh api "/user/installations/<installation_id>/repositories" \
  --paginate --jq \
  '.repositories[] | select(.full_name == "<owner/repo>") | .full_name'
```

If the repo is not listed, report the "installed on org but not
configured for this repo" gap from the library and halt for the user
to fix the App's repository access, then re-check.

## Step 4: Set the App ID and private key as secrets

Set both secrets with `gh secret set`. Pick the org-vs-repo target
from `--secret-scope`.

App ID (a value, safe to pass on the command line):

```bash
# repository scope (default)
gh secret set <APP_ID_SECRET> --repo <owner/repo> --body "<app-id>"
# organization scope
gh secret set <APP_ID_SECRET> --org <owner> --visibility selected \
  --repos <repo> --body "<app-id>"
```

Private key (read from the `.pem` path via stdin — never expanded into
argv or the conversation):

```bash
# repository scope (default)
gh secret set <APP_KEY_SECRET> --repo <owner/repo> < "<pem-path>"
# organization scope
gh secret set <APP_KEY_SECRET> --org <owner> --visibility selected \
  --repos <repo> < "<pem-path>"
```

The redirect target is quoted so paths with spaces work. `gh secret
set` overwrites an existing secret of the same name, so re-running is
convergent. Report each secret as `set` (and, when it already existed,
`overwritten`).

## Step 5: Document the token-minting workflow snippet

Read the reference snippet from the payload:

```text
${CLAUDE_PLUGIN_ROOT}/payload/gh-create-app/app-auth-snippet.yml
```

Strip its leading comment block, substitute `__APP_NAME__`,
`__APP_ID_SECRET__`, and `__APP_PRIVATE_KEY_SECRET__`, and **show** the
rendered snippet to the user. This skill does **not** write a workflow
file — consuming skills (e.g. `/gh-repo-setup-pr-automation`) own their
workflows. The snippet is the canonical pattern those workflows embed:
mint a short-lived installation token with
`actions/create-github-app-token`, expose it as `GH_TOKEN` (or pass
`steps.app-token.outputs.token` to a token input), and do the
privileged work as the App.

Never show the snippet with unresolved `__...__` placeholders; if any
remain, abort per the `${CLAUDE_PLUGIN_ROOT}/payload/README.md`
unresolved-placeholder rule.

## Step 6: Verify a minted token acts as the App

Confirm the secrets actually mint a working installation token. Two
paths, preferred first:

**Preferred — local mint with the collected private key.** If the
`.pem` path is still available this run, mint an installation token
locally and call a representative API as the App. Use the App JWT →
installation-token exchange:

```bash
# Mint a JWT (App auth), exchange for an installation token, call an API.
# gh supports App auth via `gh api` with a generated JWT; if the local
# tooling to sign a JWT is not available, fall back to the CI path below.
```

Because signing an App JWT locally requires a JWT tool that may not be
present, treat the local mint as best-effort. If it succeeds, report
the representative call's result (e.g. the repo `full_name`).

**Fallback — CI verification.** If a local mint is not feasible, tell
the user to run a one-off workflow (or the snippet from Step 5 in any
workflow) and confirm the `Mint App installation token` step succeeds
and the representative `gh api` call returns. Report the expected
success signal:

> The `Mint App installation token` step prints a masked token and the
> `gh api` call returns `<owner/repo>`. A failure here means the
> secrets are wrong or the App is not installed on the repo.

Do not block the skill on the CI run; surface it as the verification
step the user performs.

## Step 7: Save the App metadata doc

Render the metadata doc from the payload and write it to
`--metadata-path` (default `docs/github-app.md`, repo-root relative).

1. Read `${CLAUDE_PLUGIN_ROOT}/payload/gh-create-app/app-metadata.md`.
2. Strip its leading HTML comment block (the placeholder documentation).
3. Substitute every placeholder:

   | Placeholder | Value |
   | --- | --- |
   | `__APP_NAME__` | resolved App slug |
   | `__APP_ID__` | the App ID |
   | `__APP_OWNER__` | `<owner>` |
   | `__APP_SCOPE__` | `organization` or `enterprise` |
   | `__APP_INSTALL_URL__` | the App settings URL from Step 3a (minus `/new`) |
   | `__APP_PERMISSIONS__` | comma-separated granted permissions (see note) |
   | `__APP_ID_SECRET__` | `<APP_ID_SECRET>` |
   | `__APP_PRIVATE_KEY_SECRET__` | `<APP_KEY_SECRET>` |
   | `__SECRET_SCOPE__` | `repository` or `organization` |
   | `__CREATED_DATE__` | today's date (ISO `YYYY-MM-DD`) |

   The `__APP_PERMISSIONS__` value is an inline, comma-separated string
   (e.g. `Pull requests: write, Contents: write, Metadata: read`), not a
   markdown list — the template renders it inside a sentence.

4. **Converge** like the other setup skills: if the target file is
   absent, write it; if present and **semantically equal** to the
   render, do nothing and report "metadata doc already converged"; if
   present and different, show the diff and **halt** before
   overwriting (the doc may carry hand-added notes the render would
   drop). Whole-file replace, never append.

Never write the doc with unresolved `__...__` placeholders.

The doc is written **uncommitted**; the user reviews and commits.

## Step 8: Report and next steps

```text
gh-create-app — <app-name> (ID <app-id>), <scope> scope, owner <owner>

Created / configured on GitHub:
  App:           <app-name> (ID <app-id>)        <created|reused existing>
  Installed on:  <owner/repo>                     <verified>
  Secrets (<repository|organization>):
    <APP_ID_SECRET>            <set|overwritten>
    <APP_KEY_SECRET>           <set|overwritten>

Uncommitted in this repo (review and commit when ready):
  <metadata-path>                                 <written|unchanged>

Granted permissions: <list>

Next steps:
  1. Review the metadata doc:  git diff --stat <metadata-path>
  2. Commit and push when ready (this skill does not commit).
  3. Use the App in a workflow with the snippet from Step 5
     (or run /gh-repo-setup-pr-automation, which wires it in).
  4. Verify in CI: trigger a workflow using the snippet and confirm
     the token mints and the representative API call succeeds.
  5. Re-run /gh-create-app any time — it detects the existing App and
     converges (verify + refresh metadata) instead of re-creating.
```

---

## Idempotency (summary)

Re-running this skill on an already-configured App must **detect and
converge**, never duplicate:

- **App detection via the library.** Step 2 runs the find/verify path
  of `skills/lib/gh-app.md`. A suitable, installed App short-circuits
  registration; the skill offers to verify and refresh the metadata
  doc instead of creating a second App.
- **Secrets overwrite, not duplicate.** `gh secret set` replaces a
  secret of the same name, so re-running with the same key is a
  convergent overwrite.
- **Metadata doc semantic-compare before write.** An unchanged doc is
  reported "unchanged"; a changed doc halts for review before a
  whole-file replace, so hand-added notes are never silently dropped.
- **No second App, ever, by accident.** When an App by the requested
  name exists but is misconfigured, the skill reports the gap and
  tells the user to fix the existing App — it does not register a
  duplicate.

---

## Hard constraints

- **Never attempt to create the App via API.** GitHub gates App
  creation behind the UI (manifest flow excepted, which is out of
  scope here). The skill walks the user through the UI and halts; it
  does not automate creation.
- **Never print private-key material to the conversation.** Collect
  only the `.pem` path and pipe it into `gh secret set` via stdin. The
  `gh secret set <NAME> ... < "<pem-path>"` form is required.
- **Never commit or push.** The skill writes the metadata doc
  uncommitted and applies remote changes (secrets, the user's UI
  actions). The user reviews and commits the doc manually (global rule
  §0).
- **Never create a duplicate App.** Run the `skills/lib/gh-app.md`
  find/verify path first (Step 2); a suitable existing App
  short-circuits registration.
- **Never skip a halt.** The registration walkthrough (Step 3) has
  explicit halts for the UI work and the App-ID / key-path collection.
  A "looks fine, proceeding" without explicit user confirmation is not
  approval.
- **Never write a file (metadata doc) or show a snippet with
  unresolved `__...__` placeholders.** Abort per the
  `${CLAUDE_PLUGIN_ROOT}/payload/README.md` unresolved-placeholder rule.
- **Never edit anything outside the current repo.** The only on-disk
  write is the metadata doc under `<repo-root>/<metadata-path>`.
  Templates are **read** from
  `${CLAUDE_PLUGIN_ROOT}/payload/gh-create-app/` (never written).
  Scratch work, if any, goes under
  `<repo-root>/.claude/tmp/gh-create-app/`, never `/tmp/`, never the
  user's home directory, never a path outside the repo.

---

## Out of scope

- **Auto-creating the App via API.** GitHub does not expose an API to
  create a GitHub App from nothing; the App-manifest flow that exists
  is a separate, heavier mechanism. This skill walks the UI and
  automates the automatable parts (secrets, verification, metadata).
- **Rotation automation.** Rotating the App's private key on a
  schedule is a follow-up concern. The metadata doc documents the
  manual rotation steps; automating them is out of scope.
- **The per-user Claude identity App.** A GitHub App that mints a
  per-user Claude commit identity is a separate sub-issue / design
  doc, not this skill.
- **Branch-protection bypass wiring.** Listing the App as a
  bypass actor in a ruleset is `/gh-repo-setup-protection`'s / a
  protection skill's concern; this skill only provisions the App
  identity and secrets.
