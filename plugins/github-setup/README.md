# github-setup

Sets up a GitHub repository's automation and security posture from
inside Claude Code: a GitHub App for workflows to authenticate as,
workflows that merge and rebase pull requests on their own, a hardened
security and branch-protection baseline, a filtered public mirror of a
private repo, a history rewrite that purges a leaked string, and the
promotion of a private repo to public.

Each skill works on the repository you run it from, shows you what it
resolved before it changes anything, and waits for your approval before
every consequential step.

## What you need first

- `gh`, authenticated as an admin of the target repository. Registering
  an App and setting organization secrets need an organization admin,
  with the `admin:org` scope on the `gh` token; an enterprise-owned App
  needs an enterprise owner.
- `git`.
- A target repository, checked out locally. Run each skill from inside
  it.
- `git-filter-repo`, for `/repo-public-mirror-setup` and
  `/gh-repo-scrub-history`. Neither installs it for you.
- `jq`, for `/gh-repo-setup-protection`.

## The skills

### `/gh-create-app`

Provisions the GitHub App your workflows authenticate as. An App is
owned by an organization or an enterprise and installed on
repositories; there is no per-repo App.

```text
/gh-create-app [--scope=org|enterprise] [--app-name=<slug>]
               [--owner=<org-or-enterprise>] [--target-repo=<owner/repo>]
               [--secret-scope=repository|organization]
               [--app-id-secret=<NAME>] [--app-key-secret=<NAME>]
               [--metadata-path=<path>] [--permissions=starter|custom]
```

What it changes:

- Sets the App ID and the private key as secrets, `WORKFLOW_APP_ID` and
  `WORKFLOW_APP_PRIVATE_KEY` unless you name others, on the target
  repository or on its organization.
- Writes a metadata doc, `docs/github-app.md` by default, recording the
  App's name, ID, owner, permissions and secret names. It leaves the
  file uncommitted for you to review.

It also shows you the workflow snippet that mints a token as the App,
and tells you how to confirm in CI that the token works.

What it asks you for:

- Whether the App belongs to an organization or an enterprise, the
  App's name, and the owner when it is an enterprise.
- To register the App in GitHub's web UI, with the form values it gives
  you, and to generate a private key there.
- The App ID and the path to the downloaded `.pem` file. It takes the
  path only; the key's contents never enter the conversation.
- To install the App on the target repository, and to confirm when that
  is done.
- Under `--permissions=custom`, the permissions you want in place of
  the default set.

Running it again is safe. When a suitable App is already installed on
the repository, it offers to verify the secrets and refresh the
metadata doc instead of registering a second one.

### `/gh-repo-setup-pr-automation`

Installs workflows that keep pull requests moving without you: every PR
to the default branch gets auto-merge enabled, PRs that fall behind the
base branch are rebased, a scheduled sweep catches the ones an event
missed, and a collaborator with write access can comment `/rebase` on a
PR to rebase that one on demand. When the repository has a
required-check workflow, green Dependabot PRs are also merged
unattended.

The workflows run as a GitHub App, because GitHub's default workflow
token cannot enable auto-merge and its pushes do not re-trigger
required checks. The skill uses an App that already exists; when it
finds none, it points you at `/gh-create-app`.

```text
/gh-repo-setup-pr-automation [--app-name <slug>] [--app-private-key <path>]
                             [--secret-prefix <prefix>]
                             [--secret-scope <repository|organization>]
                             [--merge-method <MERGE|SQUASH|REBASE>]
                             [--do-not-merge-label <label>] [--bot-slug <name>]
                             [--required-check-workflow <name>]
                             [--install-gate-workflow <name>]
                             [--install-gate-npm-check <name>]
```

What it changes:

- Adds `.github/workflows/auto-enable-automerge.yml` and
  `.github/workflows/auto-rebase-prs.yml`. When the repository has a
  dependency-install-gate workflow, it also adds a script under
  `.github/scripts/` that regenerates an npm lockfile a Dependabot PR
  left out of step, with that script's self-test.
- Commits those files to a `gh-repo-setup-pr-automation` branch, pushes
  it, and opens a PR against the default branch.
- Sets the App's ID and private key as secrets, `AUTOMERGE_APP_ID` and
  `AUTOMERGE_APP_PRIVATE_KEY` unless you pass another prefix, on the
  repository or on its organization. It skips this when both secrets
  already exist at either level.

What it asks you for:

- To confirm the values it resolved, before it writes a file or sets a
  secret.
- To confirm the required-check workflow it proposes, when you did not
  name one. Without one, the Dependabot merge is left out.
- One approval covering the commit, the push and the PR.
- Where the secrets go, the repository or the organization.
- How the private key is set. By default it prints a `gh secret set`
  command for you to run, so the key never enters the session; or you
  give it the path to the `.pem` file and it sets the secret itself.

A PR labelled `do-not-merge` is left out of both auto-merge and
auto-rebase.

### `/gh-repo-setup-protection`

Brings a repository to a hardened security and merge baseline, and
re-asserts every setting on each run, since an organization-level
change can silently switch a repository setting back off.

```text
/gh-repo-setup-protection [--codeql=on|off|auto] [--ghas=on|off]
                          [--ruleset=on|off] [--dry-run]
```

What it changes on GitHub, directly:

- Security settings: Dependabot alerts and security updates, and, where
  the repository is entitled to them, Code Security, secret scanning
  and push protection. Dependabot malware alerts it only reports:
  GitHub offers no API to switch them on, so that is yours to do in the
  repository's Code security settings.
- Merge settings: merge commits only, with auto-merge, branch-update
  suggestions and automatic deletion of merged branches switched on.
- A `protect-main` ruleset on the default branch: no deletion, no
  force-push, and a pull request with code-owner review, approval of
  the last push and every review thread resolved. Repository admins may
  bypass the pull-request rule, so a sole maintainer is not locked out.

What it adds as files, in a PR from a `gh-repo-setup-protection`
branch:

- A `dependabot.yml` covering every package ecosystem Dependabot
  supports. Dependabot ignores an ecosystem the repository does not
  use, so one that arrives later is covered without a re-run.
- A CodeQL workflow, when CodeQL is on for the repository. It analyzes
  the languages present in each PR.
- A dependency-install-gate workflow, which fails a PR whose npm, pip,
  pnpm or yarn lockfile has drifted from its manifest.
- A dependency-pinned-gate workflow, which fails a PR that declares an
  npm, pip, GitHub Actions, Docker or Go dependency without an exact
  version.
- A no-back-merging-guard workflow, which fails a PR whose branch
  merged the default branch in rather than rebasing onto it.

Each workflow reports through one required check, which the ruleset
requires only when that workflow is present, so a check that can never
report does not block merging.

What it asks you for:

- Which languages and ecosystems to leave out. Everything is on by
  default, and the only edit is to drop one.
- One approval covering the commit, the push and the PR.

`--dry-run` reports what would change and changes nothing.
`--codeql=auto`, the default, never turns CodeQL on for a private
repository that is not entitled to it; `--codeql=on` overrides that.

### `/repo-public-mirror-setup`

Stands up a filtered, read-only public copy of a private repository.
The private repository stays the source of truth: a workflow republishes
the paths you allow, with author emails rewritten, on every push to
`main`.

```text
/repo-public-mirror-setup <ssh-key-path>
```

What it changes:

- Creates a public repository named `<repo>-public` under the same
  owner, with Issues on, and Wiki, Discussions and Projects off.
- Pushes a first commit to the mirror's `main`, with a read-only
  banner `README.md` and, where the source has none of its own, a
  `LICENSE`, `PATENTS` and `PRIOR_ART.md`.
- Adds a `mirror-main-readonly` ruleset to the mirror, which blocks
  pushes and PR merges to its default branch from everyone but
  repository admins and the workflow.
- Uploads the public half of your SSH key to the mirror as a deploy
  key, and stores the private half on the source repository as the
  secret `PUBLIC_MIRROR_DEPLOY_KEY`.
- Writes the filter configuration under `.github/public-mirror/`, the
  workflow `.github/workflows/public-mirror.yml` and a `CONTRIBUTORS`
  file into the source repository, uncommitted. The first filtered
  push happens when you commit and push them.

What it asks you for:

- The path to an SSH keypair you generated yourself with `ssh-keygen`.
  It does not generate one.
- To confirm the names it derived, before it touches anything.
- The owner name and release date for the prior-art notice, when the
  source has no `PATENTS` or `PRIOR_ART.md` of its own.
- To fill in `paths.allowlist` with the paths the mirror may publish.
  Anything not listed stays private.
- To review a local dry run of the filtered tree, before it creates the
  mirror.

It refuses to run on a repository that is not private, or when
`<repo>-public` already exists.

### `/gh-repo-scrub-history`

Rewrites a repository's entire history so that one string is replaced
by another in every commit, then force-pushes the result. Use it to
purge a leaked secret or name before a private repository goes public.

```text
/gh-repo-scrub-history
```

You may pass the string to replace and its replacement; it prompts for
whichever is missing and has you confirm both. With no replacement
given it writes `***REMOVED***`.

What it changes:

- Every commit from the first match onward gets a new SHA, on every
  branch and tag. Existing clones and forks stop matching, and open PRs
  need recreating.
- The remote's history is overwritten.

Your working clone is not touched: the rewrite happens in a scratch
copy, and after the push the skill tells you how to bring your clone
into line.

What it asks you for:

- Approval of the strings and the exact command, before the rewrite.
- A second, separate approval before the force-push, after it has shown
  you whether the string was found and is now gone.

On a repository that is already public it warns you, loudly, and
proceeds if you say so.

### `/gh-repo-setup-public`

Promotes a private repository to public, with the posture a public
repository needs settled before the switch.

```text
/gh-repo-setup-public
```

What it changes:

- Runs `/gh-repo-setup-protection` and `/gh-repo-setup-pr-automation`
  on the repository.
- Writes a `CODEOWNERS` file assigning the whole repository to
  `@evoskamp`, and checks that code-owner review and conversation
  resolution are required before merge.
- Enables Issues, and leaves issues and PRs open to outside
  contributors.
- Adds a "Contributing" section to `README.md` and a `CONTRIBUTORS`
  file, and a `LICENSE`, `PATENTS` and `PRIOR_ART.md` where the
  repository has none. These and `CODEOWNERS` are left uncommitted for
  you to review.
- Renames the repository on GitHub, when you accept a new name.
- Switches the repository's visibility to public.

What it asks you for:

- For each PR `/gh-repo-setup-protection` or
  `/gh-repo-setup-pr-automation` opened, whether it should merge the PR
  once its checks pass or leave it to you.
- Whether to remove any collaborator it does not expect. It lists them
  and removes no one on its own.
- The owner name and release date for the prior-art notice, when the
  repository has no `PATENTS` or `PRIOR_ART.md` of its own.
- Whether the history holds anything that must not become public. A
  yes stops the run and sends you to `/gh-repo-scrub-history`.
- A new name. It proposes the current one with suffixes such as
  `-private` stripped, and you accept it, give another, or keep the
  name.
- A final, separate approval of the switch to public.

## What it deliberately does not do

- **It does not register a GitHub App for you.** GitHub allows
  registration only through its web UI, so `/gh-create-app` walks you
  through the form and waits.
- **It does not read or print a private key.** Skills take the path to
  a key file and pipe the file into `gh secret set`; the contents never
  enter the conversation.
- **It does not rotate a credential.** `/gh-create-app` leaves App key
  rotation to you, and a history rewrite does not un-leak a secret that
  was ever public. Rotate it.
- **It does not generate an SSH key or install `git-filter-repo`.** You
  do both yourself, beforehand.
- **It does not commit files without your approval.**
  `/gh-repo-setup-protection` and `/gh-repo-setup-pr-automation` commit
  and open a PR on one approval; every other skill leaves its files
  uncommitted.
- **It does not write outside the repository you ran it from.** Beyond
  that repository's files, the only changes are the GitHub settings,
  secrets and repositories each skill names above.
- **It does not buy a GitHub Advanced Security entitlement.** Where a
  repository lacks one, `/gh-repo-setup-protection` reports the
  settings it skipped.
- **It does not delete an existing CodeQL workflow** when you pass
  `--codeql=off`. It reports the workflow and leaves it in place.
- **It does not make the PR-automation App a bypass actor.** Unattended
  merging of a Dependabot PR on a code-owned path needs the App listed
  as a bypass actor in the branch ruleset, and no skill here adds it.
  Without it, such a PR waits for a human.
- **It does not scrub file names or commit messages.**
  `/gh-repo-scrub-history` rewrites file contents only, and reports
  when the string survives elsewhere.
- **It does not migrate or retire an existing mirror.**
  `/repo-public-mirror-setup` is for a new mirror only, and
  `/gh-repo-setup-public` never runs it: one publishes a copy of a repo
  that stays private, the other makes the repo itself public.
- **It does not touch your local clone after a rename.** The rename is
  on GitHub only; updating your remote URL is yours to do.
