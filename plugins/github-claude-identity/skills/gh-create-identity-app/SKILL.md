---
name: gh-create-identity-app
description: "Provision the per-user Claude Code GitHub App identity — a dedicated bot account that Claude's commits, pushes, PRs, and issue comments are attributed to, distinct from your personal identity. Walks the UI-gated App registration, deploys the un-mirrored per-machine token-minting + credential-helper scripts to ~/.config/claude-github-app/, renders the config from your App identifiers, applies the per-repo bot-identity override, and verifies the bot acts correctly. Idempotent: detects an already-configured machine/repo and converges instead of re-doing."
---

You are running the `/gh-create-identity-app` skill. Your job is to set
up the **per-user Claude Code GitHub App identity** so that everything
Claude Code does on GitHub — commits, pushes, PRs, issue comments — is
attributed to a dedicated bot account with the `[bot]` badge, **not** to
the user's personal account. The user's `~/.gitconfig` is left
untouched; the override is per-repo and local.

The full design is `designs/claude-code-github-app-setup.md` in the
`global-claude-config` repo (also inlined in issue #156). That doc is
the source of truth for every script's exact contents, the bot-email
format, the hook deny logic, and the secret boundary. This skill
**automates the automatable parts** of that design and **halts** at the
steps GitHub gates behind its web UI.

## This is NOT `/gh-create-app`

`/gh-create-app` provisions an **org/enterprise** App for **workflow**
auth (CI mints a token from repo secrets). This skill provisions a
**per-user local identity** App: token-minting on your machine, a
`gh_wrapper`, a per-repo git credential helper, and a PreToolUse hook
that denies naked `gh` in App repos. The two are separate concerns; do
not conflate them. If the user wants CI workflow auth, point them at
`/gh-create-app` instead.

## The secret boundary (read first — design §8)

Be deliberate about what is safe to ship in this plugin (and its
public mirror, if the repo is mirrored) versus what must stay
per-machine. The rule is: generic/template artifacts ship; rendered
secret-bearing artifacts never do.

| Artifact | Ships in plugin? | Note |
| --- | --- | --- |
| `gh_wrapper` (`${CLAUDE_PLUGIN_ROOT}/bin/`, on PATH) | **Yes** | generic, no secrets |
| `git_wrapper` (`${CLAUDE_PLUGIN_ROOT}/bin/`, on PATH) | **Yes** | generic, no secrets |
| Helper-script payloads (the three `.sh`) | **Yes** | verbatim, no secrets |
| `config.template` (placeholders) | **Yes** | placeholders only |
| Deployed helper scripts | **No** | per-machine, by cohesion |
| Rendered `config` (real `APP_ID` etc.) | **No** | identifies your install |
| `private-key.pem` | **No — never** | full App impersonation |
| `.token-cache` | **No — never** | holds a live ≤1h token |

The deployed helper scripts, rendered `config`, `private-key.pem`, and
`.token-cache` all live in the un-mirrored `~/.config/claude-github-app/`
(design §8).

**Hard rule: nothing that is or contains a live secret may be written
into this repo or mirrored.** The skill deploys the helper scripts and
the *rendered* config to the un-mirrored `~/.config/claude-github-app/`,
never into the repo. The PEM and `.token-cache` are produced and stay
there. The only repo-side artifacts are the ones the plugin already
ships (the two wrappers, the hook rule in the other repo, and the
templates) — this skill writes no new repo files.

---

## Inputs

All optional; the skill prompts for anything it needs and cannot infer.

- `--app-name=<slug>`: the intended App name/slug (e.g. `claude-bot` or
  an org-scoped `myorg-claude`). Used in the registration walkthrough
  and the bot identity. Prompted if absent.
- `--owner=<org-or-user>`: the GitHub org (or user) that will own the
  App. Defaults to the current repo's owner
  (`gh repo view --json owner -q .owner.login`).
- `--config-dir=<path>` (default `~/.config/claude-github-app`): the
  un-mirrored per-machine directory the helper scripts and secrets live
  in. Changing it is unusual; the `gh_wrapper`, `git_wrapper`,
  credential helper, and hook all assume the default path, so only
  override it if you know why.
- `--repo=<path>` (default: the current repo): the repo to apply the
  per-repo bot-identity override to. Multiple repos: re-run per repo, or
  run `init-repo.sh` directly (see "Multi-repo").

If the user passed nothing, use the defaults and prompt for
`--app-name` and `--owner` if they cannot be inferred.

---

## Step 0: Payload existence check

Confirm the payload directory the plugin ships exists before doing
anything:

```text
${CLAUDE_PLUGIN_ROOT}/payload/gh-create-identity-app/
```

It must contain `get-token.sh`, `credential-helper.sh`, `init-repo.sh`,
and `config.template`. If the directory or any of those files is
missing, abort with:

> Payload directory
> `${CLAUDE_PLUGIN_ROOT}/payload/gh-create-identity-app/` not found (or
> incomplete). Reinstall the `github-claude-identity` plugin from the
> marketplace and try again.

The placeholder/render convention for these templates is documented in
`${CLAUDE_PLUGIN_ROOT}/payload/README.md`.

## Step 1: Pre-flight — repo root, auth, inputs

Confirm you are inside a git working tree and capture the root:

```bash
git rev-parse --show-toplevel
```

If it fails, abort: `/gh-create-identity-app` must be run from inside a
git repository.

Confirm `gh` is authenticated (`gh auth status`); if not, tell the user
to run `gh auth login`. Resolve `--owner` and `--repo` from the current
repo when not supplied:

```bash
gh repo view --json nameWithOwner -q .nameWithOwner
gh repo view --json owner -q .owner.login
```

Resolve `--app-name` (prompt if absent). Echo the resolved plan back:

```text
gh-create-identity-app — planned configuration
  App name:    <app-name>
  Owner:       <owner>
  Config dir:  <config-dir>            (un-mirrored, per-machine)
  Repo:        <owner/repo>            (per-repo bot override target)
```

## Step 2: Idempotency — is the machine / repo already configured?

Check three independent layers; each converges rather than re-doing:

1. **Machine config present?**
   `[[ -f <config-dir>/config && -f <config-dir>/private-key.pem ]]`.
   If yes, the App identity is already bootstrapped on this machine —
   skip the UI walkthrough (Step 3) and the config render (Step 5),
   re-deploying only the helper scripts if they are missing or stale
   (Step 4). Tell the user it found an existing config and is
   converging.
2. **Helper scripts present and current?** Compare each deployed script
   in `<config-dir>` against the payload template. Re-deploy any that
   are missing or differ (Step 4). Report `deployed` / `updated` /
   `unchanged` per file.
3. **Repo already overridden?** `git config --local user.email` in
   `--repo`. If it is already the bot address, report "repo already
   configured for <BOT_NAME>" and skip Step 6's git writes (still run
   the verify in Step 7).

If layer 1 shows no machine config, proceed to Step 3 to bootstrap it.

## Step 3: Walk the UI-gated App registration (halt)

GitHub gates App **creation** behind the web UI. Print the steps and
**halt** for the user to complete them. (This mirrors `/gh-create-app`
Step 3 but for a per-user identity App.)

### 3a. Register the App

Open **Org settings → Developer settings → GitHub Apps → New GitHub
App** for `<owner>` (for a user-owned App, the user's
**Settings → Developer settings → GitHub Apps → New GitHub App**). Set:

- **GitHub App name:** `<app-name>` (globally unique; if taken, pick a
  variant and tell the skill the final slug).
- **Homepage URL:** the org/repo URL is fine.
- **Webhook → Active:** **uncheck** — no webhook is needed for local
  token-minting.
- **Repository permissions** (starter set):
  - Contents: **Read & write**
  - Pull requests: **Read & write**
  - Issues: **Read & write**
  - Metadata: **Read** (auto-selected)
  - Checks: **Read** (lets Claude see CI status)
  - Workflows: **Read & write** *only if* Claude should edit
    `.github/workflows/`.
- **Where can this GitHub App be installed?** **Only on this account.**

Then **Create GitHub App**.

### 3b. Capture identifiers and generate the private key

On the App's settings page, note the **App ID** (numeric) and the
**slug** (from the settings URL). Then **Generate a private key** —
this downloads a `.pem` file you cannot re-download. **Halt** and ask
the user for:

- the **App ID** (number),
- the **slug**, and
- the **filesystem path** to the downloaded `.pem` file.

Do **not** ask the user to paste the private-key *contents* into the
conversation. Only the *path* is collected; the key file is moved into
`<config-dir>` in Step 4 and never printed.

### 3c. Install the App on the target repo(s) (halt)

Direct the user to the App's **Install App** tab → install on `<owner>`
→ **Only select repositories** → pick `<repo>` (and any other repos
Claude should work on). **Halt** until the user confirms. The install
URL ends with `/installations/<id>` — ask the user for that
**Installation ID** (or query it later via the API).

## Step 4: Deploy the per-machine helper scripts (un-mirrored)

Create the config dir with tight perms and deploy the three helper
scripts from the payload templates. **These go to `<config-dir>`, never
into any repo.**

```bash
mkdir -p <config-dir>
chmod 700 <config-dir>
```

For each of `get-token.sh`, `credential-helper.sh`, `init-repo.sh`:
copy the payload template
(`${CLAUDE_PLUGIN_ROOT}/payload/gh-create-identity-app/<file>`) to
`<config-dir>/<file>` and `chmod 700` it. The templates contain no
secret text and no placeholders, so they deploy verbatim. Report each
as `deployed` / `updated` / `unchanged` (compare before writing so
re-runs are convergent).

Move the private key into place (from the path collected in Step 3b):

```bash
mv "<pem-path>" <config-dir>/private-key.pem
chmod 600 <config-dir>/private-key.pem
```

Never print the key. If the machine config already existed (Step 2
layer 1) and the user did not regenerate a key, skip this move.

## Step 5: Render the config from the App identifiers

Render `config.template` into `<config-dir>/config`, substituting the
identifiers collected in Step 3b. The bot email **must** be exactly:

```text
<APP_ID>+<APP_SLUG>[bot]@users.noreply.github.com
```

— this exact format is what earns the `[bot]` commit badge and is the
signal the hook keys on. Placeholder map:

| Placeholder | Value |
| --- | --- |
| `__APP_ID__` | the App ID |
| `__INSTALLATION_ID__` | the Installation ID from Step 3c |
| `__APP_SLUG__` | the App slug |
| `__BOT_NAME__` | `<APP_SLUG>[bot]` |
| `__BOT_EMAIL__` | `<APP_ID>+<APP_SLUG>[bot]@users.noreply.github.com` |

Strip the template's leading comment block, write the result to
`<config-dir>/config`, and `chmod 600` it. Never write the config with
unresolved `__...__` placeholders (abort per the
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` unresolved-placeholder rule).
The rendered config holds your App identifiers and **stays in the
un-mirrored `<config-dir>`** — it is never written into a repo.

Smoke-test the token mint:

```bash
<config-dir>/get-token.sh
# → ghs_xxxxxxxxxxxxxxxxxxxx
```

A `ghs_…` token means the App ID, installation ID, and private key all
line up. A failure means one of them is wrong — re-check before
continuing.

## Step 6: Apply the per-repo bot-identity override

In `--repo`, run the deployed `init-repo.sh` to set the local bot
identity, wire the credential helper, and switch an SSH origin to HTTPS
(so the helper is consulted):

```bash
cd <repo> && <config-dir>/init-repo.sh
```

This sets `user.name`/`user.email` (local only — `~/.gitconfig`
untouched), `credential.helper`, and an HTTPS origin. Verify:

```bash
git config --local --get-regexp '^(user|credential|remote\.origin\.url)\.'
```

You should see the bot name/email, the helper, and an `https://`
origin. Setting the bot `user.email` here is also what flips the
PreToolUse hook's naked-`gh` deny on for this repo.

Note: the `git_wrapper` this plugin ships injects the same bot identity
and credential helper per-invocation, so it works even in a repo that
was never run through `init-repo.sh`. One caveat: git ignores a
credential helper on SSH remotes, so on an SSH-origin repo the wrapper's
injected helper is bypassed and git authenticates with the user's SSH
key, not the bot (the identity injection still applies; only the
token/credential path is bypassed). Bot-attributed git on such a repo
requires running `init-repo.sh` first, which switches the origin to
HTTPS. `init-repo.sh` is also the right move when you want plain `git`
(without the wrapper) to act as the bot in that repo.

## Step 7: Verify the bot identity acts correctly

Confirm three things:

1. **`gh_wrapper` acts as the bot.** Run
   `${CLAUDE_PLUGIN_ROOT}/bin/gh_wrapper api /user --jq .login` in
   `<repo>`; it should report the App's bot login, not the user's.
   With this plugin enabled the wrapper is also on PATH, so
   `gh_wrapper api /user --jq .login` works without the full path.
2. **Naked `gh` is denied by the hook in this repo.** This is the
   headless/subagent guard from design §7.2; in an interactive session
   the deny falls through to a prompt, so just confirm the local
   `user.email` is the bot address (the hook's trigger condition).
3. **A commit is attributed to the bot.** Optionally make a trivial
   commit and push (with `git_wrapper`, or plain `git` after
   `init-repo.sh`), then open it on GitHub: the author should show
   `<slug>[bot]` with the bot badge. If it shows a plain string with no
   badge, the bot email format is wrong — re-check Step 5.

Do not make the verification commit without the user's go-ahead (global
rule §0).

## Step 8: Propose the rule-include edit (halt for approval)

The `global-claude-config` repo ships
`rules/prefer-gh-wrapper-in-app-repos.md`, which tells agents to prefer
`gh_wrapper` over `gh` in App repos. Subagents pick it up automatically
via `~/.claude/CLAUDE.md`'s include mechanism, but the **main session**
only loads rules explicitly listed in `CLAUDE.md`.

Per the "propose before editing global `~/.claude`" rule, **do not edit
`CLAUDE.md` silently.** Show the user the one-line addition:

```text
@~/.claude/rules/prefer-gh-wrapper-in-app-repos.md
```

…to the include list in `CLAUDE.md`, explain it activates the
prefer-`gh_wrapper` rule for the main session too, and **halt** for
approval before making the edit. If declined, leave `CLAUDE.md`
unchanged — the rule still governs subagents.

## Step 9: Report

```text
gh-create-identity-app — <app-name> (ID <app-id>), owner <owner>

On GitHub (you completed in the UI):
  App:           <app-name> (ID <app-id>)        <created|reused>
  Installed on:  <owner/repo>                     <confirmed>

Per-machine (un-mirrored <config-dir>):
  get-token.sh / credential-helper.sh / init-repo.sh   <deployed|unchanged>
  config (rendered)                                     <written|unchanged>
  private-key.pem                                       <stored|reused>
  Token mint smoke-test                                 <ghs_… ok>

This repo (<owner/repo>):
  Local bot identity (user.name/email)                  <set|already set>
  Credential helper + HTTPS origin                      <wired>
  gh_wrapper acts as <slug>[bot]                         <verified>

CLAUDE.md include for prefer-gh-wrapper rule:           <added|declined>

Next steps:
  - For GitHub CLI calls in this repo, use (not gh):
      gh_wrapper            (on PATH with this plugin enabled)
      ${CLAUDE_PLUGIN_ROOT}/bin/gh_wrapper   (full path)
  - For git in a repo not run through init-repo.sh, use:
      git_wrapper           (on PATH with this plugin enabled)
  - git commit/push in an init-repo'd repo already use the bot
    identity automatically.
  - For another repo: cd <repo> && <config-dir>/init-repo.sh
  - Rotate the key from the App settings page; then
    rm <config-dir>/.token-cache to force a fresh mint.
```

---

## Idempotency (summary)

Re-running this skill must **detect and converge**, never duplicate:

- **Machine config present** short-circuits the UI walkthrough and the
  config render; only stale helper scripts are re-deployed.
- **Helper scripts** are compared to the payload templates and
  re-deployed only when missing or changed.
- **Repo override** is skipped when the local `user.email` is already
  the bot address; the verify still runs.
- **No second App, ever, by accident.** If the user already has an App,
  reuse its identifiers — this skill registers a new App only when the
  machine has no config and the user confirms no existing App.

---

## Hard constraints

- **Never write a secret into the repo or the mirror.** The rendered
  `config`, the PEM, and `.token-cache` live only in the un-mirrored
  `<config-dir>`. The only repo-side artifacts are the plugin's already-
  shipped `gh_wrapper`, `git_wrapper`, and templates — this skill writes
  no new repo files.
- **Never print private-key material** to the conversation. Collect only
  the `.pem` *path*; move it into `<config-dir>` and never echo it.
- **Never create the App via API.** GitHub gates App creation behind the
  UI; the skill walks the user through it and halts.
- **Never skip a halt.** Steps 3a–3c (UI work + identifier/key
  collection) and Step 8 (the `CLAUDE.md` include) have explicit halts.
- **Never render the config with unresolved `__...__` placeholders.**
  Abort per the `${CLAUDE_PLUGIN_ROOT}/payload/README.md` rule.
- **Never edit `CLAUDE.md` without explicit approval** (Step 8). The
  rule file ships regardless; the include is opt-in.
- **Never touch `~/.gitconfig`.** The bot identity is per-repo and
  local. Scratch work, if any, goes under
  `<repo-root>/.claude/tmp/gh-create-identity-app/`, never `/tmp/`,
  never outside the repo.

---

## Out of scope

- **The org/enterprise workflow-auth App.** That is `/gh-create-app`.
- **Auto-creating the App via API.** GitHub gates creation behind the
  UI; the App-manifest flow is a separate, heavier mechanism.
- **macOS Keychain storage for the PEM.** File perms + FileVault are the
  documented baseline (design §4.1); Keychain is an unhandled option.
- **Global (all-GitHub-HTTPS) credential-helper wiring.** The skill does
  per-repo wiring only (design §4.3 / §5); a global helper would hijack
  the user's personal repos.
