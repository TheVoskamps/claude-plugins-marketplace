# GitHub App resolver (`skills/lib/gh-app.md`)

This file is the single source of truth for how a skill resolves a
GitHub App to use for automated operations (workflow dispatch, branch
protection bypass, commit signing, etc.). It is **reference prose**,
not an executable script: a skill reads it and follows the patterns
documented here. Individual skill files reference this doc rather than
re-deriving the discovery, prompting, or verification logic inline.

The analogous libraries are the `/issues:repo-config` skill (repo-config
reader contract), the `/issues:user-config` skill (the per-user config
reader contract), and the `/issues:issue-view` skill (`/issue-*` shared
reference); this file plays the same role for GitHub App resolution.

## Two paths: find/verify and create-from-scratch

The resolver has two branches:

1. **Find/verify** (this file) -- detect an existing suitable App (or
   ask the user for a name), confirm it has the needed permissions and
   is installed on the target repo, and return the App identity for
   the caller to use.
2. **Create-from-scratch** -- provision a new App when none exists.
   This path is **not implemented here**. It is the domain of the
   `/gh-create-app` skill. The create branch points the user at
   `/gh-create-app`, which walks the UI-gated registration, installs
   the App, sets the secrets, verifies a minted token, and saves a
   metadata doc. See "Create-from-scratch path" below for the handoff.

This split lets setup skills (`/repo-public-mirror-setup`,
`/pr-automation-setup`, `/protection-setup`) run against an
already-existing App without waiting for `/gh-create-app` to be built.

## When to use this library

A skill that needs a GitHub App identity calls the find/verify
sequence documented below as part of its own setup flow. Typical
callers:

- `/repo-public-mirror-setup` -- needs an App to push to the mirror
  repo (deploy key alternative, or for workflow dispatch).
- `/pr-automation-setup` -- needs an App to create PRs, approve, and
  merge on behalf of automation.
- `/protection-setup` -- needs an App identity to list as a bypass
  actor in branch-protection rulesets.

The caller passes:

- **`required_permissions`** -- a map of permission scope to access
  level (e.g. `{ contents: write, pull_requests: write,
  workflows: write }`). The verifier checks these against the App's
  declared permissions.
- **`target_repo`** (optional) -- the `owner/repo` to verify
  installation on. Defaults to the current repo
  (`gh repo view --json nameWithOwner -q .nameWithOwner`).

## Find/verify sequence

### Step 1: Discover candidate Apps

List GitHub Apps installed on the target repo's organization or user
account. The approach differs by owner type because the API
endpoints and auth models differ.

**Organization-owned repos** -- use the org installations endpoint
(works with the user's `gh` token when the user has `admin:read`
scope and is an org owner):

```bash
gh api "/orgs/__GH_ORG__/installations" --jq \
  '.installations[] |
   {id, app_slug, app_id, permissions}'
```

If the org endpoint returns a 404 (owner is a user account, not an
org), fall back to the **authenticated-user installations endpoint**:

```bash
gh api "/user/installations" --paginate --jq \
  '.installations[] |
   select(.account.login == "__GH_ORG__") |
   {id, app_slug, app_id, permissions}'
```

The `/user/installations` endpoint lists every GitHub App
installation the authenticated user has explicit permission to
access. The `select` filter narrows results to the target owner.
This endpoint works with the standard `gh` user token -- no App JWT
is needed.

> **Note:** there is no `/users/{username}/installations` endpoint
> in the GitHub REST API. The singular
> `/users/{username}/installation` exists but requires App JWT
> auth, which is not available at discovery time. The
> `/user/installations` endpoint above is the correct user-token
> alternative for personal accounts.

Parse the JSON output into a list of candidate installations.

If neither endpoint returns any installations, proceed to Step 3
(no candidates).

### Step 2: Filter by permissions

For each candidate, check that every entry in `required_permissions`
is satisfied:

```text
for each (scope, level) in required_permissions:
  candidate.permissions[scope] must be >= level
  ("read" < "write" < "admin" for comparison purposes)
```

Candidates that pass all checks are **suitable**. Keep track of which
candidates fail and why (the missing/insufficient permission) for the
report in Step 3.

### Step 3: Select or prompt

Three cases:

- **Exactly one suitable candidate** -- use it. Print the selection
  for the user:

  > Using GitHub App `<app_slug>` (ID `<app_id>`,
  > installation `<installation_id>`).

- **Multiple suitable candidates** -- present the list and ask the
  user to pick one:

  > Found multiple GitHub Apps with sufficient permissions:
  >
  > 1. `<app_slug_1>` (ID `<app_id_1>`)
  > 2. `<app_slug_2>` (ID `<app_id_2>`)
  >
  > Which App should this skill use?

  Use the user's choice for the rest of the flow.

- **No suitable candidates** -- two sub-cases:

  - **Candidates exist but none have sufficient permissions** --
    report what was found and what was missing:

    > No installed GitHub App has sufficient permissions for this
    > skill. Required: `<required_permissions>`.
    >
    > Found Apps:
    > - `<app_slug>`: missing `<scope>: <level>` (has `<actual>`
    >   or not granted)
    >
    > Create a suitable App with `/gh-create-app`, or create one
    > manually and re-run this skill.

  - **No installations at all** -- report and point at the create
    path:

    > No GitHub Apps installed on `<org>`. Create one with
    > `/gh-create-app`, or create one manually and re-run this skill.

  In both sub-cases, abort the calling skill. The user needs to
  create or reconfigure an App before the skill can proceed.

### Step 4: Verify installation on the target repo

Confirm the chosen App is installed on the specific target repo (not
just the org). There are two approaches depending on available auth.

**Preferred (user-token path)** -- query the authenticated user's
installations and check repository access. This works with the
standard `gh` token:

```bash
gh api "/user/installations/{installation_id}/repositories" \
  --paginate --jq \
  '.repositories[] |
   select(.full_name == "__GH_ORG__/__GH_REPO__") |
   .full_name'
```

Where `{installation_id}` is the `id` from the candidate selected in
Step 3. If the output is empty, the App is installed on the org but
not configured for this specific repo.

**Alternative (App JWT path)** -- if the skill has App JWT auth
available (e.g. after `/gh-create-app` provisions the App), it can
use the repo-specific endpoint:

```bash
gh api "/repos/__GH_ORG__/__GH_REPO__/installation" \
  --jq '{id: .id, app_id: .app_id, app_slug: .app_slug}'
```

> **Auth note:** this endpoint requires GitHub App JWT
> authentication. A standard `gh` CLI call (which uses a user
> token) returns 401. Only use this path when App JWT auth is
> available. For discovery flows using user tokens, use the
> preferred path above.

If the repo is not covered by the installation, report:

> GitHub App `<app_slug>` is installed on `<org>` but not configured
> for `<org>/<repo>`. Update the App's repository access settings to
> include this repo, then re-run the skill.

Abort the calling skill.

### Step 5: Return the resolved identity

Return to the caller:

```text
app_slug:        <app_slug>
app_id:          <app_id>
installation_id: <installation_id>
```

The caller uses these values to configure workflows, branch-protection
bypass actors, or any other integration that needs the App identity.

## User-supplied App name (skip discovery)

A skill may accept an App name as an explicit input (e.g.
`--app-name <slug>`). When provided, the skill skips the
multi-candidate discovery (Steps 1-3) and goes directly to
verification:

1. Look up the App by slug using the authenticated user's
   installations (works with the standard `gh` token):

   ```bash
   gh api "/user/installations" --paginate --jq \
     '.installations[] |
      select(.app_slug == "__APP_SLUG__") |
      {id, app_slug, app_id, permissions}'
   ```

   Where `__APP_SLUG__` is the user-supplied name (lowercase).
   If no matching installation is returned, abort:

   > No installation found for GitHub App `<slug>`. Verify the
   > App name and that it is installed on an account you have
   > access to.

2. Verify the App is installed on the target repo using the
   user-token path from Step 4:

   ```bash
   gh api "/user/installations/{installation_id}/repositories" \
     --paginate --jq \
     '.repositories[] |
      select(.full_name == "__GH_ORG__/__GH_REPO__") |
      .full_name'
   ```

   If the output is empty, the App exists but is not configured
   for this repo. Abort:

   > GitHub App `<slug>` is not configured for `<org>/<repo>`.
   > Update the App's repository access settings to include this
   > repo, then re-run the skill.

3. Check that the App's permissions satisfy `required_permissions`
   using the same logic as Step 2 of the find/verify sequence. If
   insufficient, abort with the same "missing permissions" report.

4. Return the resolved identity (Step 5).

## Placeholder values derived from an App

When a resolved App identity is used in template rendering (see
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` for the placeholder
convention), the following placeholders map to the resolved values:

| Placeholder | Source |
| --- | --- |
| `__APP_NAME__` | `app_slug` |
| `__APP_ID__` | `app_id` |

## Create-from-scratch path

The create path is owned by the `/gh-create-app` skill
(`skills/gh-create-app/SKILL.md`). This library does **not** create an
App itself — App creation is UI-gated by GitHub and involves
registration, private-key handling, and secret-setting that need a
dedicated skill with its own approval gates and halts.

The handoff works as follows:

- A skill that reaches the "no suitable candidates" branch in Step 3
  prints the pointer message shown there (which now names
  `/gh-create-app`) and aborts. The user runs `/gh-create-app`
  separately, then re-runs the original skill.
- `/gh-create-app` itself **calls this library's find/verify path
  first** (its Step 2) with the resolved `required_permissions` map.
  That makes the create skill idempotent: a suitable, already-installed
  App short-circuits registration and the skill offers to verify and
  refresh its metadata doc instead of creating a duplicate.
- After `/gh-create-app` registers and installs the App, it continues
  from this library's Step 4 (verify installation) and Step 5 (return
  the resolved identity) shape — App slug, App ID, installation ID —
  so downstream consumers see the same identity regardless of whether
  the App was found or freshly created.

Skills must not attempt to create a GitHub App programmatically from
this library; route users to `/gh-create-app`.

## Conventions for callers

When writing a skill that consumes this library:

- Open with a statement of which permissions the skill requires
  (the `required_permissions` map).
- Reference this file: "See `skills/lib/gh-app.md` for the
  find/verify sequence."
- Do not duplicate the find/verify logic inline -- reference the
  steps by number ("run Steps 1-5 from `skills/lib/gh-app.md`
  with `required_permissions = { ... }`").
- Do not invent alternative discovery mechanisms. If the `gh api`
  endpoints documented here are insufficient for a new use case,
  update this library rather than working around it in the caller.
