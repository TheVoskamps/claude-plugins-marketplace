---
name: gh-repo-setup-protection
description: "Idempotently converge a repo's entire Security & Quality surface — GHAS toggles (incl. push-protection bypass lockdown, per-repo Code Security, malware alerts, grouped security updates), the merge-button / PR-hygiene settings (merge-commit-only, auto-merge, auto-delete head branch), a hardened templated Dependabot config (always covering GitHub Actions), an Advanced CodeQL workflow, a dependency-install-gate (npm/pip/pnpm/yarn drift guard), a dependency-pinned-gate (npm/pip/actions/docker/go exact-version guard), a no-back-merging-guard, and the protect-main ruleset — re-asserting on every run, and committing + PR-ing its own rendered files on a single approval."
---

You are running the `/gh-repo-setup-protection` skill. Your job is to
bring the **current repo** (the repo the user invoked the skill from)
to a desired security/quality protection baseline. The skill's remit is
the **entire Security & Quality surface** of the repo — every setting on
the repo's *Security & Quality* settings page — plus the repo's
merge-button / PR-hygiene **General** settings and the matching
`protect-main` ruleset. The GHAS features are half-measures without the
ruleset that enforces them, so both are in scope:

1. **GHAS / repo security settings** — Dependabot alerts, Dependabot
   security updates (incl. *grouped* security updates), Dependabot
   *malware* alerts, per-repo Code Security (GHAS enablement when the
   org/repo is entitled), and secret scanning + push protection
   (including *locking down who may bypass* push protection) where the
   repo is entitled to them.
2. **Merge-button / PR-hygiene repo settings** — the General-settings
   merge-button toggles (`allow_squash_merge`, `allow_rebase_merge`,
   `allow_update_branch`, `allow_auto_merge`, `delete_branch_on_merge`)
   converged to the hardened state: merge-commit only, suggest-update-
   branch + auto-merge + auto-delete-head-branch on. These are remote
   settings applied via the GitHub API, read-then-PATCH and idempotent
   like the GHAS toggles. See Step 4e.
3. **A templated `dependabot.yml`** — version-update config covering
   **every supported package ecosystem** (`github-actions`, `npm`,
   `pip`, `docker`, `gomod`, `bundler`, `cargo`, `maven`, `gradle`,
   `composer`, `terraform`), armed at install time regardless of what
   the scan found, with a `security-updates` group so security PRs are
   batched per ecosystem. Dependabot **no-ops** on an ecosystem whose
   manifest is absent, so arming the full set adds no spurious update
   PRs — it just means an ecosystem's first manifest is covered the
   moment it lands, with no skill re-run. See Step 2 / Step 3. (The
   Step 2b Dependabot tab is a *de-arm* override — drop an ecosystem you
   never want — defaulting to the full set armed.)
4. **An Advanced CodeQL workflow** — **only when CodeQL is enabled for
   this repo** (explicit `--codeql=on` operator override, or
   auto-detection). The workflow is armed with the **full supported
   CodeQL language set** and picks which to analyze at **runtime**, per
   PR: a `detect` job emits the languages actually present in the tree,
   an `analyze` matrix runs one leg per present language, and a
   `codeql-required` aggregator is the single required check (green when
   the matrix is empty, so a language-less repo is mergeable, not hung).
   A language that lands *after* setup lights its leg up automatically —
   no skill re-run. CodeQL is never turned on *by auto-detection* on an
   unentitled private repo; an explicit `--codeql=on` is an operator
   override that the skill honors. The shipped workflow is **Advanced
   setup from the first commit** (SHA-pinned, autobuild-free,
   least-privilege). See the "CodeQL is opt-in" section for why.
5. **A dependency-install-gate** — **installed whenever CodeQL-style
   protection is wanted for dependency drift** (armed with the full
   supported set of npm / pip / pnpm / yarn). A `pull_request` workflow
   with a `detect` job (emits the package managers whose manifest is
   present), a matrixed `gate` job (one leg per present PM, replaying the
   lockfile / running a resolver pre-flight and failing on drift), and an
   `install-gate-required` aggregator that is the single required check
   (green when the matrix is empty). Each Node manager keys off its
   **own** lockfile (`package-lock.json` / `pnpm-lock.yaml` /
   `yarn.lock`), so a pnpm/yarn repo is gated by the right tool instead
   of silently passing an npm-only check. A PM whose manifest lands after
   setup lights its leg up automatically — no skill re-run. See Step 5c.
6. **A dependency-pinned-gate** — the **sibling** of the
   dependency-install-gate (armed with the full supported set of npm /
   pip / actions / docker / go): where the install-gate protects the
   lockfile↔manifest *lock* relationship, this gate protects how the
   manifest itself **declares** versions. A `pull_request` workflow with
   the same `detect` → matrixed `gate` → `pinned-gate-required`
   aggregator shape, whose per-ecosystem legs fail the PR when any
   *declared* dependency is not pinned to an exact version
   (caret/tilde/comparator/X-range/OR/compatible-release specs, floating
   action `@vN` tags, floating Docker `:latest` tags, bare names) —
   catching the "works on main, breaks on rebase" supply-chain drift that
   slips past a green install-gate. Categorical exemptions
   (peerDependencies carets, `file:`/`workspace:` specs,
   `engines`/`requires-python` floors, override-value classification,
   `tag@sha256:` digests) live in the classifier, not an allowlist file.
   `actions` is an always-present floor (the skill always installs
   workflows). Its aggregator is a separate required check from the
   install-gate's. See Step 5c-pinned.
7. **A no-back-merging-guard** — installed **unconditionally** (it has
   no ecosystem dependency; it is pure git-history hygiene). A
   `pull_request` workflow whose single job `no-back-merging-guard`
   rejects PRs whose head branch contains a back-merge from the default
   branch (a merge commit whose incoming parent is reachable from
   `origin/<default>`), forcing feature branches to rebase rather than
   merge the base in. See Step 5d.
8. **The `protect-main` ruleset** — create/converge the standard
   branch ruleset (deletion, non-fast-forward, a `pull_request` rule
   with last-push-approval + code-owner review + thread-resolution, and
   `required_status_checks`). The `pull_request` rule grants the
   built-in **Repository admin** role a **PR-only** bypass so a
   single-maintainer repo (sole writer == sole code-owner == last
   pusher) is not deadlocked by last-push-approval + code-owner review.
   Required status checks are wired through a **generic gate**: each one
   is added **only if its producing workflow is present in the repo this
   run** — the issue #91/#230 phantom-check guard, applied at
   **workflow** granularity (never per-leg). The required checks are the
   workflows' **aggregators**: `codeql-required` iff a CodeQL workflow is
   present this run, `install-gate-required` iff the
   dependency-install-gate workflow is present this run,
   `pinned-gate-required` iff the dependency-pinned-gate workflow is
   present this run, and `no-back-merging-guard` iff that workflow is
   present this run (always, since it ships unconditionally) — never a
   per-leg name like `Analyze (python)` or `Install gate (npm)`, which
   would hang a repo lacking that language/PM (the #91/#230 failure
   mode). Each aggregator passes green when its runtime matrix was empty,
   so a repo missing the guarded languages/ecosystems is mergeable.

**Converge the whole surface on every run — do not set-and-forget.**
An org-level change can flip a per-repo setting back off (e.g. enabling
Code Security at the org level flips `secret_scanning_push_protection`
back to disabled). Every run must *re-assert* the hardened state for
every setting, reporting each as `enabled`/`changed`/`unchanged`.

The headline requirement is **idempotency / convergence**. This skill
is meant to be run repeatedly across many repos (at least four:
two under `TheVoskamps`, two under `ExampleProject`). Re-running on an
already-configured repo must **detect existing state and converge** to
the desired config — it must never duplicate ecosystem blocks, append
to a config that already has the right content, or hard-error because
something is already in place.

The **full supported set is armed at install time on every surface** —
CodeQL languages, both gates' ecosystems, and Dependabot's ecosystems —
and each surface **activates automatically the first time matching
source appears, with no skill re-run**. For CodeQL and the two gates
this is a **runtime dynamic-matrix**: a check appears on a PR iff the
language/ecosystem it guards is present in the tree at that moment
(present + clean → green; present + broken → red/blocking; absent → no
check). For Dependabot (which emits no PR check) it means the rendered
`updates:` list covers every supported ecosystem, no-opping on absent
manifests. This **structurally removes the protect-before-code ordering
inversion** — you no longer merge the code first so the skill can detect
it. Before authoring anything, the skill presents an **operator
confirmation checklist** (Step 2b) that is a *de-arm* override:
everything is armed by default, and the operator can drop a
language/ecosystem they never want armed.

After rendering its files, the skill **commits, pushes, and opens a
PR** for its own rendered files on a single approval (Step 7). The
rendered files go on a branch named after the skill
(`gh-repo-setup-protection`) and into a PR targeting the default
branch — the operator approves once, and that one approval covers
commit + push + PR. The **remote API changes** — the GHAS toggles
(Step 4), the merge-button settings (Step 4e), and the `protect-main`
ruleset (Step 6) — are not file edits and cannot live in a PR, so they
are applied **directly** to the repo; every such change is reported and
re-running is a no-op when the setting is already correct.

---

## Inputs

All optional; everything else is inferred from the repo.

- `--codeql=on|off|auto` (default `auto`): controls the CodeQL
  workflow. See "CodeQL is opt-in".
- `--ghas=on|off` (default `on`): whether to attempt the remote
  settings — the GHAS toggles (Step 4) and the merge-button /
  PR-hygiene settings (Step 4e). Set `off` for a repo where you only
  want the Dependabot/CodeQL files and not the remote
  security/merge-button settings.
- `--ruleset=on|off` (default `on`): whether to create/converge the
  `protect-main` ruleset (Step 6). Set `off` to manage branch
  protection elsewhere and have this skill touch only the
  GHAS/Dependabot/CodeQL surface.
- `--dry-run`: report what *would* change (files, GHAS toggles,
  merge-button settings, the ruleset, and the rendered-files PR) without
  writing files, calling the mutating API, or opening a PR. Skips the
  Step 2b operator de-arm checklist (arms the full supported set on
  every surface) so the multi-repo verification pass is non-interactive.

If the user passed nothing, use the defaults above.

---

## Step 0: Payload

The template payloads this skill renders ship with the plugin at
`${CLAUDE_PLUGIN_ROOT}/payload/gh-repo-setup-protection/`. The
placeholder/render convention is documented in
`${CLAUDE_PLUGIN_ROOT}/payload/README.md`.

## Step 1: Pre-flight — repo root, auth, and identifiers

Confirm you are inside a git working tree and capture the root:

```bash
git rev-parse --show-toplevel
```

If it fails, abort with:

> `/gh-repo-setup-protection` must be run from inside a git
> repository. The current directory is not a git working tree.

Confirm `gh` is authenticated:

```bash
gh auth status
```

If not authenticated, abort and tell the user to run `gh auth login`
(scopes: `repo`, plus `security_events` and `admin:repo_hook` are
helpful for the GHAS toggles).

`jq` must be on `PATH` (it parses the CodeQL default-setup response in
Step 5a; it is already a hard dependency of the global config's hooks).
Step 5a hard-stops if it is missing.

Resolve the repo identifiers (these feed the placeholders — see
`${CLAUDE_PLUGIN_ROOT}/payload/README.md` step 1 inference table):

```bash
gh repo view --json nameWithOwner -q .nameWithOwner   # __GH_ORG__/__GH_REPO__
gh repo view --json defaultBranchRef -q .defaultBranchRef.name  # __DEFAULT_BRANCH__
gh repo view --json visibility -q .visibility
gh repo view --json isPrivate -q .isPrivate
```

## Step 2: Scan package ecosystems present in the repo (informational)

**The armed set is no longer narrowed by this scan.** All four
protected surfaces — CodeQL, the two gates, and Dependabot — arm the
**full supported set** at install time (see Steps 3, 5b, 5c, 5c-pinned).
CodeQL and the two gates then narrow to the *present* set at **runtime**
via each workflow's `detect` job; Dependabot no-ops on absent manifests.
So this scan does **not** decide *what to author* — it is retained only
as **informational context** for the operator (to show, in the Step 2b
de-arm checklist, which languages/ecosystems already have source in the
tree) and for the CodeQL on/off decision (Step 5, which still needs to
know whether the repo has any analyzable language to auto-resolve).

The Dependabot supported set the skill arms unconditionally (one
`updates:` block each — directory `/` for `github-actions`, recursive
`**/*` for the rest):

`github-actions`, `npm`, `pip`, `docker`, `gomod`, `bundler`, `cargo`,
`maven`, `gradle`, `composer`, `terraform`.

(Confirm the exact set against Dependabot's current supported-ecosystems
docs at implementation time — arm whatever the current docs enumerate.
`github-actions` is the floor and is always armed.)

For the **informational** scan, use this mapping (manifest glob →
ecosystem). Run it from the repo root over tracked files only and ignore
vendored trees (`node_modules`, `vendor`, `.git`):

| Manifest (anywhere in tree) | Dependabot ecosystem |
| --- | --- |
| `package.json` | `npm` |
| `requirements*.txt`, `pyproject.toml`, `Pipfile`, `setup.py` | `pip` |
| `go.mod` | `gomod` |
| `Gemfile` | `bundler` |
| `Cargo.toml` | `cargo` |
| `composer.json` | `composer` |
| `pom.xml` | `maven` |
| `build.gradle`, `build.gradle.kts` | `gradle` |
| `*.tf` | `terraform` |
| `Dockerfile`, `*/Dockerfile` | `docker` |

Reference detection commands (adjust as needed):

```bash
ROOT="$(git rev-parse --show-toplevel)"
# Track files only — never scan ignored/vendored trees.
git -C "$ROOT" ls-files | grep -E '(^|/)package\.json$'
git -C "$ROOT" ls-files | grep -E '(^|/)go\.mod$'
git -C "$ROOT" ls-files | grep -E '(^|/)(requirements.*\.txt|pyproject\.toml|Pipfile|setup\.py)$'
# ... etc per the table above
```

**The gates' own detection is defined once, at runtime, by their
scripts** — not by this scan. `dependency-install-gate.sh --present`
and `dependency-pinned-gate.sh --present` emit the present set from the
same `git ls-files` predicates the gates check with, and CodeQL's
`codeql-language-present.sh --matrix` does the same for languages. This
Step 2 scan never feeds those; it is purely for display and the CodeQL
on/off gate.

**A `dependabot.yml` is always written** — the full supported set is
armed unconditionally, so the `updates:` list is never empty. The old
"no ecosystem detected → skip the file" / "markdown-only repo" path is
**gone**: the skill always arms every supported ecosystem.

## Step 2b: Operator de-arm checklist (defaults to the full armed set)

Every surface is **armed with the full supported set** at install time,
and each **narrows to the present set at runtime** (CodeQL and the two
gates via their `detect` jobs) or no-ops on absent manifests
(Dependabot). So there is **nothing to detect-and-narrow up front** — the
protect-before-code ordering inversion is gone structurally, not via an
operator toggle. The scan (Step 2) is informational only.

The checklist that remains is a **de-arm override**: for each surface,
the full supported set is armed by default, and the operator may **drop**
a language/ecosystem they never want armed on this repo. This is the
inverse of the old "confirm what to arm" flow — the default is
everything-on, and the only edit is subtraction.

So after the informational scan and **before authoring any file**
(Steps 3, 5b, 5c, 5c-pinned), present a **single multi-tab
`AskUserQuestion`** — one tab per surface (drift-gate / pinned-gate /
Dependabot / CodeQL), each `multiSelect: true` — whose options are the
surface's **full supported set, all preselected (armed)**. The operator
**unchecks** any item they want de-armed; the **armed set** (full set
minus the operator's unchecks) is what is authored. This is the skill's
up-front interaction; the single commit/push/PR approval (Step 7) still
comes after, so the approve-once model is preserved.

Skip the checklist under `--dry-run` (arm the full supported set on every
surface and note the checklist was skipped) — every interactive run
presents it.

**Working within the `AskUserQuestion` contract.** The tool caps a call
at 1–4 questions, each with 2–4 options. The four surfaces ⇒ four
questions — at the question cap. Several surfaces have more than four
supported values (Dependabot ≈11, CodeQL 10, pinned-gate 5), which
exceeds the 2–4-options-per-question cap. Because the flow is now
**de-arm only** (no free-text "add" path — the full set is already
armed), an over-cap surface is presented as a **single confirm-or-edit
option**: default "keep the full set armed", with a free-text `response`
in which the operator lists **only the items to de-arm** (e.g. "drop
maven, gradle"). A de-arm entry is validated against that surface's
supported set (below); an unrecognized entry is reported and re-prompted,
never silently applied. Surfaces that fit the cap (drift-gate has exactly
four PMs) list each supported value as a preselected checkbox directly.

### The four tabs (all default to the full armed set)

- **Drift-gate tab** (armed set → Step 5c gate is armed with these PMs).
  Options are the four supported package managers — `npm`, `pip`,
  `pnpm`, `yarn` — each **preselected (armed)**. Unchecking a PM de-arms
  it (its runtime `detect` never proposes it and no leg ever spawns).
  The armed set is baked into the workflow's `detect` script coverage;
  in practice the gate script already covers all four, so a de-arm is
  honored by the ruleset/reporting layer, not by removing a job (there
  are no per-PM jobs any more — one matrixed `gate` job covers all).
- **Pinned-gate tab** (armed set → Step 5c-pinned). Five supported
  ecosystems (`npm`, `pip`, `actions`, `docker`, `go`) — one over the
  cap, so use the confirm-or-edit pattern: default "keep all five
  armed", free-text de-arm listing the ecosystems to drop. `actions` is
  the always-present floor — de-arming it is discouraged (report it) but
  permitted.
- **Dependabot tab** (armed set → Step 3 `updates:` blocks). The full
  supported ecosystem set (`github-actions`, `npm`, `pip`, `docker`,
  `gomod`, `bundler`, `cargo`, `maven`, `gradle`, `composer`,
  `terraform`) — more than the cap, so use the confirm-or-edit pattern:
  default "arm every supported ecosystem", free-text de-arm listing the
  ecosystems to drop. `github-actions` is the floor and is not
  de-armable.
- **CodeQL tab** (armed set → Step 5b). The full supported CodeQL
  language set (`javascript-typescript`, `python`, `go`, `java-kotlin`,
  `csharp`, `c-cpp`, `ruby`, `rust`, `swift`, `actions`) — more than the
  cap, so use the confirm-or-edit pattern: default "arm every supported
  language", free-text de-arm listing the languages to drop. `actions`
  is the floor. The armed set does **not** override the CodeQL on/off
  decision — `--codeql` and the entitlement guard in Step 5 still decide
  *whether* CodeQL runs; the armed set only bounds which languages the
  runtime `detect` may propose. (De-arming every language does not turn
  CodeQL off — the runtime matrix simply never spawns a leg, and the
  `codeql-required` aggregator passes green.)

### Validate a de-arm entry before it is applied

A free-text de-arm entry names an item to **remove** from the armed set.
Validate each against its surface's supported set so a typo does not
silently fail to de-arm (or, worse, get misread):

- **Pinned-gate**: `npm`, `pip`, `actions`, `docker`, `go`.
- **Dependabot**: the documented Dependabot `package-ecosystem` enum
  (`github-actions`, `npm`, `pip`, `docker`, `gomod`, `bundler`, `cargo`,
  `maven`, `gradle`, `composer`, `terraform`, plus any others GitHub's
  options reference lists — treat the docs as authoritative).
- **CodeQL**: `javascript-typescript`, `python`, `go`, `java-kotlin`,
  `csharp`, `c-cpp`, `ruby`, `rust`, `swift`, `actions`.

For each de-arm entry: normalize an unambiguous alias to its canonical
value (`golang`/`gomod` → the surface's canonical form; `typescript` →
`javascript-typescript`; `c#` → `csharp`; etc.); if it matches a
supported value, remove that value from the armed set; if it resolves to
nothing, report the unrecognized entry, show the surface's supported set,
and re-prompt. Never apply an unvalidated de-arm.

### How the armed sets flow downstream

| Tab | Armed set drives | Consumed in |
| --- | --- | --- |
| Drift-gate | which PMs the install-gate covers (runtime-matrixed) | Step 5c, Step 6c |
| Pinned-gate | which ecosystems the pinned-gate covers (runtime-matrixed) | Step 5c-pinned, Step 6c |
| Dependabot | which `updates:` ecosystem blocks render | Step 3 |
| CodeQL | which languages the runtime CodeQL matrix may propose | Step 5, Step 5b, Step 6c |

From Step 2b onward, the downstream steps arm the **armed set** (full
supported set minus operator de-arms), and the **runtime `detect` jobs**
(CodeQL and the two gates) narrow that to the present set per PR. The
scan is informational; the authored artifact is the armed set; the
running check is the present subset of the armed set.

## Step 3: Render and converge `dependabot.yml`

Target path: `<repo-root>/.github/dependabot.yml`.

**Arm the full supported ecosystem set** (Step 2's list, minus any
Step 2b de-arms): `github-actions`, `npm`, `pip`, `docker`, `gomod`,
`bundler`, `cargo`, `maven`, `gradle`, `composer`, `terraform`. Render
one `updates:` block per armed ecosystem **unconditionally** — do
**not** narrow to detected ecosystems. Dependabot no-ops on an ecosystem
whose manifest is absent, so arming the full set adds no spurious update
PRs; it just covers each ecosystem's first manifest the moment it lands,
with no skill re-run.

The generated baseline is **hardened** (issue #51): per-ecosystem
cooldown soak, `versioning-strategy`, recursive directory coverage,
semver-major ignore, and per-ecosystem schedules. Several values vary
by **ecosystem class** — npm/pip (the rich tier), github-actions (fixed
directory, weekly, default-days only), and everything else (docker,
gomod, bundler, cargo, maven, gradle, composer, terraform — recursing
directory, daily, default-days only). The `ecosystem-block.yml`
template carries those variant parts as block placeholders the skill
resolves per ecosystem. **Getting the class variant right for every
armed ecosystem is the one real complexity** — a wrong variant (e.g.
`versioning-strategy` on docker/github-actions, which Dependabot does
not support) makes Dependabot **reject the whole config**. Test this
hardest.

1. Read the per-ecosystem template
   `gh-repo-setup-protection/ecosystem-block.yml`. Strip its leading
   comment block (every line up to and including the
   `# Indentation ...` comment) — only the YAML body is rendered.
2. For each armed ecosystem (directory `/` unless the operator's stated
   layout says otherwise — since the armed set no longer comes from a
   directory-bearing scan, default every ecosystem's directory to the
   repo root), substitute the placeholders below. Render the blocks in a
   **stable, sorted order** (sort by ecosystem then directory) so the
   output is deterministic — this is what makes the re-run a
   byte-for-byte no-op instead of a reorder churn.

   **Per-ecosystem placeholder resolution.** Resolve each placeholder
   from the ecosystem class. There are three ecosystem classes:
   **npm/pip** (the rich tier), **github-actions** (fixed directory,
   weekly, default-days only), and **everything else** (docker, gomod,
   bundler, cargo, maven, gradle, composer, terraform — recursing
   directory, daily, default-days only). Every newly-armed ecosystem
   (bundler, cargo, maven, gradle, composer, terraform) falls in the
   **"everything else"** class: `directories: **/*`, daily, `cooldown:
   default-days: 7` only, and **no** `versioning-strategy` (dropped).

   The two scalar placeholders resolve as:

   | Placeholder | npm / pip | github-actions | other (docker, gomod, …) |
   | --- | --- | --- | --- |
   | `__ECOSYSTEM__` | the ecosystem value | `github-actions` | the ecosystem value |
   | `__DEFAULT_BRANCH__` | default branch | default branch | default branch |
   | `__SCHEDULE_INTERVAL__` | `daily` | `weekly` | `daily` |

   The three multi-line block placeholders resolve per class as follows
   (each block's first line carries no leading indent — the template's
   4-space indent supplies it — and continuation lines carry their own
   absolute 6-space indent):

   - **`__DIRECTORY_BLOCK__`** — npm/pip and every other ecosystem
     **except** `github-actions` use the plural `directories:` key with
     a root-anchored globstar:

     ```yaml
     directories:
       - "<dir-glob>"
     ```

     `<dir-glob>` is `**/*` when the detected directory is the repo root
     `/`; for a non-root manifest directory `/sub`, anchor the globstar
     there as `sub/**/*`. `github-actions` keeps the singular
     `directory: "/"` — it has a fixed workflow search and is not a
     recursing path. Bare `**` under `directories` does **not** recurse
     arbitrarily; `**/*` is the verified pattern.
   - **`__VERSIONING_STRATEGY_BLOCK__`** — on **npm/pip only**, the
     single line `versioning-strategy: increase` (the only two
     ecosystems that honour the key — preserves exact-pin policy;
     emitting it elsewhere is a no-op at best and a parse risk at
     worst). For every other ecosystem this block is **empty** — drop
     the placeholder line (see empty-block collapse below).
   - **`__COOLDOWN_BLOCK__`** — cooldown soak applies to **version
     updates only** (security PRs bypass it). npm/pip get per-semver
     tiers:

     ```yaml
     cooldown:
       semver-major-days: 14
       semver-minor-days: 7
       semver-patch-days: 7
       default-days: 7
     ```

     docker, github-actions, and every other ecosystem do **not**
     support semver tiers (Dependabot rejects `semver-*-days` for them),
     so they get `default-days` only:

     ```yaml
     cooldown:
       default-days: 7
     ```

   Two more hardening patterns live in the **static body** of the
   template (not placeholders) and therefore apply to every ecosystem
   unconditionally: the **ignore semver-major** version-update entry and
   the **`*-security` group**.

   **Empty-block collapse.** `__DIRECTORY_BLOCK__`,
   `__VERSIONING_STRATEGY_BLOCK__`, and `__COOLDOWN_BLOCK__` each sit
   alone on a 4-space-indented line in the template. When a block
   resolves to **empty** (`__VERSIONING_STRATEGY_BLOCK__` on every
   non-npm/pip ecosystem), **drop the entire placeholder line** — do not
   leave a whitespace-only line, which would be spurious diff noise on
   re-run.

3. Concatenate the rendered blocks.
4. Read the outer template `gh-repo-setup-protection/dependabot.yml`,
   strip its leading comment block, and substitute
   `__DEPENDABOT_ECOSYSTEMS__` with the concatenated blocks (and
   `__DEFAULT_BRANCH__` if it appears).

This produces the **desired file content**.

**Explicitly out of this generated baseline (deferred to skill V3,
issue #51).** Domain dependency groups (e.g. `fastapi-stack`,
`aws-cdk`, `vite-toolchain`), `exclude-paths`, and `assignees` are
**not** part of this template — they are repo-specific and cannot be
inferred for an arbitrary repo. A future V3 of the skill will collect
them interactively and converge them. Do not add them to the generated
block here.

### Converge (idempotency)

- If `<repo-root>/.github/dependabot.yml` does **not** exist: write it.
- If it **exists**:
  - Parse both the existing file and the desired content as YAML and
    compare the normalized structures. If they are **semantically
    equal**, do nothing and report "dependabot.yml already converged".
  - If they **differ**, the convergence rule is **whole-file replace
    with the rendered desired content**, NOT append. Appending is what
    produces duplicate ecosystem blocks on re-run; this skill owns the
    file's shape, so it overwrites. Before overwriting, show the user a
    diff (existing vs. desired) and note any `updates:` entries in the
    existing file that the skill would drop (e.g. a hand-added
    ecosystem the detection missed, or custom `ignore:`/`reviewers:`
    blocks). **Halt and ask** before overwriting a file that contains
    entries the render would lose — the user may want those preserved.
    If the existing file's only differences are ones the render
    subsumes, overwrite and report.

Never write the file with unresolved `__...__` placeholders. If any
remain after substitution, abort per the README's unresolved-
placeholder rule.

## Step 4: GHAS / repo security settings (convergent toggles)

Skip this entire step if `--ghas=off`.

These are **remote settings**, applied via the GitHub API. Each one is
read first and only written when it differs from the desired state, so
re-running is a no-op. None of these toggles costs money for **public**
repos; for **private** repos, secret scanning / push protection and
CodeQL require a GitHub Advanced Security entitlement — detect the lack
of entitlement and skip gracefully rather than erroring.

### 4a. Dependabot alerts + security updates

```bash
# Read current state.
gh api repos/__GH_ORG__/__GH_REPO__/vulnerability-alerts \
  --silent && echo "alerts: enabled" || echo "alerts: disabled"
```

Enable (idempotent — PUT is safe to repeat):

```bash
gh api --method PUT repos/__GH_ORG__/__GH_REPO__/vulnerability-alerts
gh api --method PUT repos/__GH_ORG__/__GH_REPO__/automated-security-fixes
```

`vulnerability-alerts` returns 204 whether or not it was already on;
treat any 2xx as success and report "Dependabot alerts: enabled".

Dependabot **malware alerts** are a separate, *settings-level* toggle —
they are NOT a `dependabot.yml` key (that file controls version updates
and alert *rules*, not malware-alert *enablement*). Malware alerts
require Dependabot alerts to be on (enabled just above) and are
**npm-only today**. There is no documented public per-repo REST
endpoint for this toggle as of this writing (it is managed from the
repo's *Code security* settings UI). There is therefore **no enable
PATCH to make** — the `security_and_analysis[dependabot_security_updates]`
field is the Dependabot *security-updates* feature (already enabled by
the `automated-security-fixes` PUT above), **not** malware alerts, so
poking it would be a misdirected no-op against an already-on, unrelated
setting. The skill instead reads-to-report and surfaces the one manual
step:

Read the repo's `security_and_analysis` block to *report* the malware-
alert state if it is exposed; otherwise report
"Dependabot malware alerts: enable in the repo's Code security settings
(npm-only; no public REST toggle)" so the operator finishes the one
manual step. Never hard-fail on the absence of the endpoint. See
<https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/configure-malware-alerts>.

**Grouped security updates** (batching security PRs per ecosystem into
one PR) are driven two ways, and the skill owns the deterministic one:

- The per-repo/org *Code security* settings toggle (UI; no stable
  public REST toggle) controls grouping for ecosystems **not**
  configured in `dependabot.yml`.
- The `dependabot.yml` `groups:` key with `applies-to: security-updates`
  controls grouping for the configured ecosystems — this is the
  in-file, deterministic mechanism the skill renders (Step 3). Because
  the rendered `dependabot.yml` already carries a per-ecosystem
  `security-updates` group, security PRs for every configured ecosystem
  are grouped regardless of the settings toggle. Report
  "Grouped security updates: configured via dependabot.yml
  (applies-to: security-updates)".

### 4b. Per-repo Code Security (GHAS) enablement (entitlement-gated)

When the org/repo is **GHAS-entitled**, enable per-repo Code Security
(Advanced Security). This is the lever that makes secret scanning,
push protection, and CodeQL available on a *private* repo. The skill
must *enable* it when entitlement is present — not merely detect its
*absence* to skip CodeQL.

Read the current state, then enable iff entitled and not already on.
Read the **granular `code_security`** field, not the deprecated
`advanced_security` toggle: GitHub split the single Advanced Security
toggle into granular fields (`code_security`, `secret_scanning`, …),
and on a fully-entitled repo the legacy `advanced_security` field reads
`absent` while `code_security.status` reads `enabled`. Reading the
legacy field therefore mis-detects an entitled repo as unentitled.
Treat the repo as **entitled** when `code_security.status == "enabled"`:

```bash
gh api repos/__GH_ORG__/__GH_REPO__ \
  --jq '.security_and_analysis.code_security.status // "absent"'
```

```bash
# Only attempt on a private repo (public repos get these features free
# and have no code_security toggle). A 422 "Advanced Security is
# not enabled for this account/org" means the org is not entitled —
# report and skip, do not hard-fail.
gh api --method PATCH repos/__GH_ORG__/__GH_REPO__ \
  -f 'security_and_analysis[code_security][status]=enabled' \
  2>/dev/null \
  && echo "Code Security: enabled" \
  || echo "Code Security: skipped (org not GHAS-entitled)"
```

Report `enabled (was already on)`, `enabled (changed)`, or
`skipped (org not GHAS-entitled)`. Enabling this is what makes the
secret-scanning/push-protection PATCH below succeed on a private repo.

### 4c. Secret scanning + push protection (entitlement-gated)

Read the current security-and-analysis block:

```bash
gh api repos/__GH_ORG__/__GH_REPO__ \
  --jq '.security_and_analysis'
```

Build the desired patch and only PATCH the fields that differ. **Always
re-assert these on every run** — an org-level Code Security change can
flip `secret_scanning_push_protection` back to disabled, so a converge
run must set it back on even if a prior run already enabled it:

```bash
gh api --method PATCH repos/__GH_ORG__/__GH_REPO__ \
  -f 'security_and_analysis[secret_scanning][status]=enabled' \
  -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'
```

If this PATCH returns 422 / "Advanced Security is not enabled for this
repository" (the common case on an unentitled private repo), do
**not** treat it as a hard failure: report
"secret scanning unavailable (no GHAS entitlement on this private
repo); skipping" and continue. Public repos get secret scanning for
free, so the PATCH succeeds there.

Always report, for each toggle, one of: `enabled (was already on)`,
`enabled (changed)`, or `skipped (<reason>)`. That report is the
evidence the run converged.

### 4d. Lock down push-protection bypass

Push protection's default bypass list is **"Anyone with write access"**.
The hardened state is **nobody** — restrict bypass to a specific
role/team set whose membership is empty, so a blocked secret push must
go through a bypass *request* rather than a self-serve override.

This is GitHub's *delegated bypass* for push protection. As of this
writing it is configured through an **org-level security configuration**
(`secret_scanning_delegated_bypass_options` on the security-configuration
API, then attached to the repo) and a repo-level
`secret_scanning_delegated_bypass` enablement — there is **no clean,
stable per-repo public REST toggle** that sets the bypass list to
"nobody" directly. The skill therefore:

```bash
# Best-effort: enable delegated bypass at the repo level so bypass
# becomes request-gated rather than self-serve. The reviewer/role list
# (the "who may bypass" set) is configured in the org security
# configuration; the skill cannot set an empty reviewer list through a
# stable public per-repo endpoint, so it enables delegated bypass and
# reports the residual manual step.
gh api --method PATCH repos/__GH_ORG__/__GH_REPO__ \
  -f 'security_and_analysis[secret_scanning_delegated_bypass][status]=enabled' \
  2>/dev/null || true
```

Report the outcome honestly: if the enablement succeeded, report
"Push-protection bypass: delegated bypass enabled (set the bypass
reviewer list to an empty role/team in the org security configuration
to reach 'nobody')". If the endpoint is unavailable (422/404), report
"Push-protection bypass: configure 'who can bypass' = nobody in the
repo's Code security settings (no stable public REST toggle)". Never
hard-fail — surface the residual manual step instead of inventing an
endpoint that may not exist.

### 4e. Merge-button / PR-hygiene repo settings (convergent toggles)

The repo's General-settings merge button stays at GitHub defaults
unless something converges it. The `protect-main` ruleset's
`allowed_merge_methods: ["merge"]` (Step 6) constrains only the
*ruleset's* merge enforcement — it does **not** flip the repo-level
`allow_squash_merge` / `allow_rebase_merge` toggles, so the merge
button still offers squash and rebase. This step converges the five
merge-button / PR-hygiene fields directly, the same read-then-PATCH,
re-asserted-every-run, idempotent way the GHAS toggles do. These are
**remote settings**, not file edits, so they apply directly (not via
the Step 7 PR). This step runs under `--ghas` (skip it when
`--ghas=off`, like the other remote toggles).

Desired hardened state:

| UI setting | REST field | Desired |
| --- | --- | --- |
| Allow squash merging | `allow_squash_merge` | `false` |
| Allow rebase merging | `allow_rebase_merge` | `false` |
| Suggest updating PR branches | `allow_update_branch` | `true` |
| Allow auto-merge | `allow_auto_merge` | `true` |
| Auto-delete head branches | `delete_branch_on_merge` | `true` |

`allow_merge_commit` is left `true` (consistent with the ruleset's
`allowed_merge_methods: ["merge"]`) — do not flip it off, or the repo
would have no enabled merge method.

Read the current values first, then PATCH only when they differ so a
converged re-run is a no-op:

```bash
# Read current state.
gh api repos/__GH_ORG__/__GH_REPO__ \
  --jq '{allow_squash_merge, allow_rebase_merge, allow_update_branch,
         allow_auto_merge, delete_branch_on_merge}'
```

```bash
# Re-assert the desired state (idempotent — PATCH with the same values
# is a no-op server-side; only PATCH the fields that differ, or PATCH
# all five — both converge).
gh api --method PATCH repos/__GH_ORG__/__GH_REPO__ \
  -F allow_squash_merge=false \
  -F allow_rebase_merge=false \
  -F allow_update_branch=true \
  -F allow_auto_merge=true \
  -F delete_branch_on_merge=true
```

All five are documented public REST fields on the repository object.
Report each as `unchanged` (already at desired) or `changed` (was at a
different value). This step is convergent and never hard-fails; a
private repo with no special entitlement still accepts these
General-settings PATCHes (they are not GHAS-gated).

## Step 5: CodeQL — opt-in, never auto-forced

### CodeQL is opt-in

CodeQL must not be assumed for every repo. The hazard is concrete and
has happened twice on `global-claude-config`:

- **Issue #91**: a CodeQL workflow on a repo with no analyzable language
  produced a phantom required check that hung PRs on "Waiting for Code
  scanning results" forever.
- **Issue #230 (PR #226 → #227)**: CodeQL **default setup** was enabled
  server-side with a pinned language list `[actions, python]`. The repo
  has zero Python, so `CodeQL / Analyze (python)` failed on every PR and
  blocked merges. Default and advanced setup cannot coexist; the fix
  (PR #227) was an Actions-only advanced `codeql.yml` plus disabling
  default setup out-of-band.

The rationale, inlined here so it does not depend on any other rule
file: a CodeQL check becomes a **phantom failing/hung required check**
whenever the workflow's analysis cannot succeed — either because no
analyzable language is present, or because a server-side default-setup
language list does not match the repo. Such a check blocks every PR.
Therefore CodeQL is opt-in, the skill reads the existing server-side
setup mode before writing (Step 5a below), and it never enables CodeQL
for a language the repo cannot analyze.

"Opt-in" means: **auto-detection never turns CodeQL on for an
unentitled-private repo.** It does *not* mean the skill refuses an
explicit operator request. `--codeql=on` is an operator override — the
operator has decided CodeQL belongs on this repo, and the skill honors
that by installing the workflow. The distinction matters: the danger
the policy guards against is CodeQL silently *auto*-resolving on
(recreating issue #91), not an operator deliberately enabling it.
(Before Step 2 made `actions` the always-present floor, a markdown-only
repo was also an auto-skip case; it no longer is, because every repo
the skill touches gets workflows and therefore the `actions` analyzable
language. The one auto-skip left is the unentitled-private repo.) So:

Resolve whether CodeQL is wanted, in this order:

1. `--codeql=on` → CodeQL on. `--codeql=off` → CodeQL off (skip Step 5
   entirely; if a `codeql.yml` workflow already exists, report it and
   do **not** delete it — removing a security workflow is a decision
   for the user).
2. `--codeql=auto` (default) → **auto-detect**:
   - **Off** if the repo is **private AND not GHAS-entitled**. CodeQL
     on an unentitled private repo recreates the issue #91
     phantom-check problem. **Determine entitlement independently of
     Step 4 — do not rely on Step 4 having run.** Step 4 is skipped
     entirely under `--ghas=off`, so the auto-detect must read the
     entitlement signal itself with a read-only call that is safe to
     make regardless of `--ghas`:

     ```bash
     # isPrivate captured in Step 1. Read the granular code_security
     # field, not the deprecated advanced_security toggle — the legacy
     # field reads "absent" on a fully-entitled repo and would mis-detect
     # entitlement (see Step 4b).
     gh api repos/__GH_ORG__/__GH_REPO__ \
       --jq '.security_and_analysis.code_security.status // "absent"'
     ```

     Treat the repo as **not entitled** when `isPrivate` is `true` AND
     that status is `disabled` or `absent`. Equivalently, the repo is
     **entitled** when `code_security.status == "enabled"`. When
     `--ghas=on` and Step 4b already ran, its no-entitlement 422 is an
     equivalent signal and may be reused; but the read above is the
     source of truth so the determination is identical whether or not
     Step 4 ran. This closes the `--ghas=off` bypass: on a private,
     unentitled repo with workflow files (this repo's shape — `actions`
     is an analyzable language), `--ghas=off` must still resolve CodeQL
     **off**, never let it auto-resolve **on**.
   - The old "no analyzable language → off" auto-skip is **gone.** The
     CodeQL workflow is armed with the **full supported language set**
     and narrows to the present languages at **runtime** via its
     `detect` job (Step 5b). `actions` is an always-present floor (the
     skill installs workflows), so at least one leg always runs on an
     entitled-or-public repo, and the `codeql-required` aggregator
     passes green even when the runtime matrix is empty. There is
     therefore no install-time language check to fail — the only
     off-branch left in `auto` is the **private + unentitled** case
     above. A repo mid-transition (e.g. Python today, TypeScript
     tomorrow) gets its new-language leg the moment the first `.ts` file
     lands, with **no skill re-run** — the exact ordering inversion this
     issue fixes.
   - **On** otherwise (public repo, or entitled private repo).
3. Do not ask — a public (or entitled private) repo resolves CodeQL
   **on**. The runtime matrix (armed full set, narrowed to present) is
   never a deadlock: an absent language produces no leg, and the
   aggregator is green on an empty matrix. (The only off-resolutions
   left are the private-unentitled and the explicit `--codeql=off`
   cases.)

**No install-time empty-matrix hazard (why the old hard stop is gone).**
The old "no-supported-language hard stop" existed because the former
static CodeQL language-list matrix could be authored **empty**, producing
a check that can never pass and deadlocks branch protection (issue #230's
failure mode). That hazard **no longer exists**: the workflow is armed
with the full supported set and the analyze matrix is built at runtime
from `codeql-language-present.sh --matrix`. An empty runtime matrix (no
analyzable language present) spawns **zero** analyze legs and the
`codeql-required` aggregator concludes **success** (`if: always()` +
empty-matrix pass), so the PR is mergeable, never hung. `--codeql=on`
overrides the *entitlement* auto-skip and installs the armed workflow;
there is no separate language check for it to override, because the
runtime matrix cannot deadlock.

**Always report the CodeQL decision and the reason**, e.g.
"CodeQL: off (auto — private repo without GHAS entitlement)" or
"CodeQL: on (armed with the full supported language set; runtime matrix
narrows to present languages per PR)".

### 5a. Read the server-side CodeQL setup mode before writing

This is the fix for the issue #230 wedge. **Before installing advanced
setup, read GitHub's server-side CodeQL setup mode** — the skill must
not write a `codeql.yml` blind to a default setup already running with a
different (possibly wrong) language list. Default setup and advanced
setup (a `codeql.yml` workflow) **cannot coexist**; default setup runs
its own language list independently of any workflow file, which is
exactly how `Analyze (python)` failed on a repo with zero Python.

Read the current mode (read-only, safe regardless of `--ghas`). Only a
clean `403` (unentitled) or `404` (code-scanning disabled / no default
setup) means "not configured" — **every other non-zero exit
(`5xx`, rate limit, auth expiry, network/transport failure) is a hard
stop**, because silently treating a transient failure as
"not-configured" would skip the disable-default-setup step and
re-trigger the exact wedge issue #230 fixes. Capture the HTTP status
and branch on it:

```bash
# jq parses the response body below. If it is missing, the body parse
# would silently yield an empty $setup and fall through to the decision
# table with a state that is neither configured nor not-configured —
# the exact issue #230 wedge, triggered by a missing binary. Hard-stop
# up front instead, in the same style as the default (*) branch below.
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required to read the CodeQL default-setup mode" \
       "for __GH_ORG__/__GH_REPO__ but is not installed / not on PATH." \
       "jq is a hard dependency of the global config (its hooks need" \
       "it too). Install jq and re-run this skill rather than letting" \
       "the skill proceed blind to an empty CodeQL state (issue #230)." >&2
  exit 1
}

# Make a SINGLE request: -i emits the response headers AND the JSON
# body in one response, so we parse both the HTTP status line and the
# body from the same fetch — no second call, no transient-failure
# window between two reads. Without letting a non-zero exit abort the
# script; 2>/dev/null suppresses gh's stderr so a transport failure
# leaves the response empty (status parses to empty → default case).
response=$(
  gh api -i repos/__GH_ORG__/__GH_REPO__/code-scanning/default-setup \
    2>/dev/null
)
http_status=$(
  printf '%s\n' "$response" \
    | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p'
)

case "$http_status" in
  200)
    # Extract the body (everything after the first blank line that
    # separates headers from body) and pull state/languages from it.
    # No second network call — the body came back with the status above.
    setup=$(
      printf '%s\n' "$response" \
        | sed -n '1,/^[[:space:]]*$/d;p' \
        | jq '{state: .state, languages: .languages}'
    )
    ;;
  403|404)
    # Unentitled, or code-scanning disabled / no default setup.
    setup='{"state":"not-configured","languages":null}'
    ;;
  *)
    # Empty status = curl/transport failure; any other status (5xx,
    # 429 rate limit, 401 auth expiry, etc.) = a non-clean failure.
    # Do NOT assume "not-configured" — halt and tell the operator.
    echo "ERROR: could not read CodeQL default-setup mode for" \
         "__GH_ORG__/__GH_REPO__ (HTTP status: ${http_status:-none —" \
         "transport/network failure}). This is not a clean 403/404," \
         "so the skill will NOT assume CodeQL is unconfigured —" \
         "doing so could skip disabling a live default setup and" \
         "re-wedge branch protection (issue #230). Re-run this skill" \
         "once the GitHub API is reachable." >&2
    exit 1
    ;;
esac

echo "$setup"
```

(`state` is `configured` or `not-configured`. Only a clean `403`
(unentitled) or `404` (code-scanning disabled / no default setup) is
mapped to `not-configured`; **any other non-zero exit — `5xx`, `429`
rate limit, `401` auth expiry, or a curl/transport failure — is a hard
stop, not a silent "not-configured".** A transient failure misread as
"not-configured" would skip the disable step below and re-create the
issue #230 wedge, so the skill aborts and asks the operator to re-run
once the API is reachable rather than proceeding blind.)

**The core invariant: default setup and an advanced `codeql.yml`
cannot coexist.** A repo with a working advanced workflow MUST have
default setup `not-configured` — that is the correct, intended end
state, not an incidental "nothing to disable." The advanced workflow
being committed is precisely what forces default setup to stay off
(the leading comment in `gh-repo-setup-protection/codeql.yml` says
this); the report wording below matches that framing. `configured`
default setup alongside an advanced workflow is the issue #230 wedge,
to be disabled with operator confirmation.

Decision table once CodeQL has resolved **on** (Step 5) and you are
about to install advanced setup:

- **default setup `not-configured`** → this is the **correct
  mutually-exclusive state**: advanced setup active, default setup
  correctly off, because the two cannot coexist. Nothing to disable;
  proceed to render the workflow (5b). Report "default setup: correctly
  not configured (advanced setup active — the two cannot coexist)".
- **default setup `configured`** → it conflicts with the advanced
  workflow (the issue #230 wedge). **Show the operator the detected
  `state` and `languages`, and ask for confirmation** before disabling
  it. On confirmation, disable it out-of-band, then proceed to render:

  ```bash
  gh api --method PATCH \
    repos/__GH_ORG__/__GH_REPO__/code-scanning/default-setup \
    -f state=not-configured
  ```

  If the operator declines, do **not** install the advanced workflow
  (the two cannot coexist); report "CodeQL: left as server-side default
  setup at operator's request; advanced workflow not installed" and
  skip the render. Never install advanced setup alongside a live default
  setup.

Report what was found and what changed, e.g. "default setup: was
configured (languages: actions, python) → disabled (operator confirmed);
installing advanced setup".

When CodeQL has resolved **off**, do not PATCH default setup off on the
skill's own initiative — disabling an existing server-side scan is a
security-posture change the operator owns. Report the detected default
setup state so the operator can act if they want to.

### 5a-bis. Preserve a newer SHA-pinned action pin (never downgrade)

The workflow converges (Steps 5b, 5c, 5c-pinned, 5d) take the
**payload** content
as the base, but they must **never downgrade an action pin the repo
already has pinned to a newer release**. Doing so would silently roll
back a deliberate operator upgrade — a regression. This sub-step
defines the pin-reconciliation pass each of those converges applies to
the desired content **before** the semantic-compare, generically to
**every** `uses:` line (checkout, codeql-action, setup-node,
setup-python, and any future action).

**Convergence never even offers to bump a pin down.** There is no
prompt. For each `uses: <owner>/<repo>[/<path>]@<ref>` line in the
rendered desired content, find the corresponding line in the existing
repo file (matched by `<owner>/<repo>[/<path>]`, the action coordinate
without the `@<ref>`). If the repo's pin is **strictly newer and
SHA-pinned**, keep the repo's pin (its SHA **and** its trailing
`# vX.Y.Z` comment) in the desired content; otherwise take the
payload's pin. Concretely, for each matched action coordinate:

- Repo's resolved tag **strictly newer AND the repo's ref is a 40-hex
  SHA** → keep the repo's `uses:` line verbatim in the desired content.
- Repo's pin **older, equal, or floating** (the ref is a tag like `@v6`
  or a branch, not a 40-hex SHA) → take the payload's pin.
- An action coordinate that appears only in the payload (no matching
  `uses:` in the repo file) → take the payload's pin (nothing to
  preserve).

**"Newer" is derived from the SHA, not the trailing comment.** The
trailing `# vX.Y.Z` comment is operator-written and may lie, so it is
**display-only** and never used for the comparison. To compare two
SHA-pinned refs, resolve **both** the repo's SHA and the payload's SHA
against the action's upstream repo and compare the resolved release
tags by semver:

```bash
# Resolve a commit SHA to the release tag that points at it.
# --paginate: the tags list spans multiple pages on actions with many
# releases; without it a matching tag on page 2+ is missed and the SHA
# is wrongly treated as unresolvable (downgrading a genuinely-newer pin).
gh api --paginate repos/<owner>/<repo>/tags --jq \
  ".[] | select(.commit.sha == \"<sha>\") | .name"
```

When a tag does not point directly at the commit (e.g. the SHA is a
tagged commit reached via `git rev-parse <tag>^{commit}`), fall back to
matching the SHA against each candidate tag's dereferenced commit via
`gh api --paginate repos/<owner>/<repo>/git/refs/tags` (again
`--paginate`, so a tag ref on a later page isn't missed). Compare the
two resolved tags with semver (`vMAJOR.MINOR.PATCH`).

**Unresolvable → take the payload's pin.** If **either** SHA cannot be
resolved to an upstream tag — a deleted tag, a fork, a private action,
or an API / network failure — do **not** guess and do **not** keep the
repo's pin. Take the **payload's** pin (the skill's owned, known-good
value). Resolution failure is never treated as "repo is newer".

After this pass, the desired content differs from the raw payload only
where a repo pin was kept for being strictly-newer-and-SHA-pinned. The
subsequent semantic-compare (Steps 5b/5c/5c-pinned/5d) then runs against this
**pin-reconciled** desired content: if the only remaining difference
between the existing file and the payload was those kept newer pins,
the file compares **equal** and is reported "unchanged" — no
downgrade, no halt. "Match the payload" thus explicitly **excludes**
downgrading a deliberately-newer SHA-pinned repo pin.

### 5b. Render and converge the CodeQL workflow (only when CodeQL is on)

Target paths:

- `<repo-root>/.github/workflows/codeql.yml`
- `<repo-root>/.github/codeql/codeql-config.yml`
- `<repo-root>/.github/scripts/codeql-language-present.sh`

**There is no install-time CodeQL language-list placeholder any more.**
The workflow is armed with the **full supported CodeQL language set** and
narrows to the present languages at **runtime**: its `detect` job runs
`codeql-language-present.sh --matrix`, which emits a JSON array of
`{ language, runner }` matrix entries for exactly the languages present
in the tracked tree, and the `analyze` job builds its matrix from that
array via `fromJSON`. So the language set is decided per PR at runtime,
never frozen at install time.

1. Render `gh-repo-setup-protection/codeql.yml` (strip its leading
   comment block) substituting **only** `__DEFAULT_BRANCH__`. The
   template has no language placeholder.
2. `codeql-config.yml` has no placeholders — keep its `name:`/`queries:`
   body; it has no leading placeholder-doc comment block to strip, so it
   ships as-is.
3. `codeql-language-present.sh` has no placeholders — ship it
   **verbatim** (including its leading comment block; it is a shell
   script whose header documents its own behavior), with the executable
   bit set (`chmod +x`). It is the SAME `git ls-files` predicate the
   analyze matrix is built from, so "what detect thinks is present"
   cannot drift from what the analyze legs run. The `swift` entry it
   emits carries `runner: macos-latest`; every other language carries
   `runner: ubuntu-latest`, so a Swift-less repo never provisions macOS.

First apply the **pin-reconciliation pass (Step 5a-bis)** to the
rendered `codeql.yml` — keep any `uses:` pin the repo already has
pinned to a strictly-newer SHA, never downgrade. Then converge each
target as in Step 3 against that pin-reconciled content: if the target
file is absent, write it; if present and **semantically equal**, do
nothing; if present and different, show the diff and halt before
overwriting. Whole-file replace, never append. The `.sh` uses a
normalized-text/byte compare (it is a shell script, not YAML), like the
gate scripts.

## Step 5c: Render and converge the dependency-install-gate (drift guard)

A drifted `package.json`/lockfile (or an unresolvable requirements pin)
can desync from its manifest via a Dependabot PR or a hand edit; without
a PR-time gate the desync auto-merges into the default branch and breaks
local dev and downstream pipelines. This step installs a
**dependency-install-gate** — a `pull_request` workflow armed with the
**full supported set** of package managers (`npm`, `pip`, `pnpm`,
`yarn`) that replays the lockfile / runs a resolver pre-flight over
every discovered manifest and fails the PR on drift. The artifact is
ported from the proven `ExampleProject/example-app-repo` gate.

**Runtime dynamic-matrix, not install-time-narrowed jobs.** The workflow
has three jobs: a `detect` job that runs
`dependency-install-gate.sh --present` (the SAME `git ls-files`
discovery the gate checks with) and emits a JSON array of the PMs whose
manifest is present right now; a matrixed `gate` job over
`fromJSON(needs.detect.outputs.pms)`, so a leg exists for a PM **iff**
its lockfile/manifest is in the tree at that moment; and an
`install-gate-required` aggregator. A PM whose manifest lands **after**
setup lights its leg up on the next PR, with **no skill re-run** — the
ordering-inversion fix.

**Why per-PM legs, not one Node job.** Each Node package manager keys
off its **own** lockfile (npm → `package-lock.json`, pnpm →
`pnpm-lock.yaml`, yarn → `yarn.lock`). A single npm-only job discovers
nothing on a pnpm/yarn repo, hits its no-manifests-green branch, and
exits 0 — a **dead check that gives false assurance** while the very
`package.json`↔lockfile desync it exists to catch merges anyway
(issue #111). One matrix leg per manager, each keyed off its own
lockfile, closes that gap.

### The aggregator is the required check (not the per-PM legs)

GitHub `required_status_checks` is a static list of names and cannot
express "require the `npm` leg only if it runs". So the per-PM legs
(`Install gate (<pm>)`) are **visible** but **not** individually
required; the always-running `install-gate-required` aggregator (stable
name) is the single required check. It `needs:` the matrixed `gate` job,
runs `if: always()`, and concludes:

- **success** when the matrix was empty (no PM present) — so a
  manifest-less repo is **mergeable, not hung**;
- **success** when every spawned leg succeeded;
- **failure** when any leg failed or was cancelled.

The `if: always()` is **mandatory**: without it the aggregator is
*skipped* on an empty matrix, and a required check treats "skipped" as
not-passed → the #91/#230 phantom-check hang returns. Step 6c registers
`install-gate-required`, never a per-leg name.

### Render the gate files

Target paths:

- `<repo-root>/.github/workflows/dependency-install-gate.yml`
- `<repo-root>/.github/scripts/dependency-install-gate.sh`

1. Render `gh-repo-setup-protection/dependency-install-gate.yml` (strip
   its leading comment block) substituting **only** `__DEFAULT_BRANCH__`.
   The actions are SHA-pinned in the template (with the human-readable
   tag in a trailing comment), matching the `codeql.yml` convention — do
   not de-pin them. There is **no** per-job delimiter-comment rendering
   any more: the workflow ships with the full detect → matrix →
   aggregator shape, armed with all four PMs, and narrows at runtime.
2. `dependency-install-gate.sh` has no placeholders — ship it
   **verbatim** (including its leading comment block; it is a shell
   script whose header documents its own behavior). The script accepts
   all four modes (`npm`, `pip`, `pnpm`, `yarn`), the `--present` mode
   the detect job calls, and no-ops gracefully (exit 0) for any mode
   whose lockfile the repo lacks. The `--present` mode reuses the same
   discovery predicate, so the runtime matrix cannot drift from what the
   gate checks. Ship it with the executable bit set (`chmod +x`).

The gate ships **unconditionally** whenever the skill installs
workflows — there is no "empty resolved set → skip the file" case any
more, because the workflow is armed with the full set and gates at
runtime (an absent PM produces no leg and a green aggregator, so it is
never dead weight or noise). Both files are always written together
(the workflow calls the script).

Never write the `.yml` with an unresolved `__DEFAULT_BRANCH__`. If it
remains after rendering, abort per the README's unresolved-placeholder
rule.

### Converge the gate files (idempotency)

Apply the same **whole-file-replace + semantic-compare** rule the skill
uses for `dependabot.yml`/`codeql.yml`, with one difference in the
compare method per file type. For the `.yml`, first apply the
**pin-reconciliation pass (Step 5a-bis)** to the rendered desired
content so a repo's strictly-newer SHA-pinned action (e.g. a
`actions/checkout` the operator already bumped past the payload's) is
**kept, never downgraded**, before the semantic-compare:

- **`dependency-install-gate.yml`** — YAML semantic-compare (parse both
  the existing file and the pin-reconciled desired content as YAML,
  compare normalized structures). Equal → "unchanged"; absent → write;
  different → show the diff and halt before overwriting (whole-file
  replace, never append). Because the workflow is now a fixed
  full-set-armed shape (no per-job rendering), the compare is against
  the same content every run — a converged repo re-runs as a no-op.
- **`dependency-install-gate.sh`** — this is a shell script, **not**
  YAML, so the semantic-compare is a **normalized-text/byte compare**
  (trailing-whitespace-normalized), not a YAML parse. Equal →
  "unchanged"; absent → write (with the executable bit set, `chmod +x`);
  different → show the diff and halt before overwriting.

Both files are written together: install both. Never install one without
the other (the workflow calls the script).

## Step 5c-pinned: Render and converge the dependency-pinned-gate

(The exact-version guard — sibling of the install-gate.)

The dependency-install-gate (Step 5c) protects the **lock** relationship
— it fails a PR when a manifest and its lockfile have drifted. It does
**not** check how the *manifest itself* declares versions. A
`package.json` with `"aws-cdk-lib": "^2.172.0"`, a `requirements.txt`
with `boto3>=1.40`, a workflow `uses: actions/checkout@v4`, or a
`FROM node:22` resolves to a **different** concrete version over time
even when the lockfile is perfectly in sync — the "works on main, breaks
on rebase" supply-chain drift that slips past a green install-gate. This
step installs the **dependency-pinned-gate** — the sibling of the
install-gate — a `pull_request` workflow armed with the **full supported
set** of ecosystems (`npm`, `pip`, `actions`, `docker`, `go`) whose
per-ecosystem legs fail the PR when any *declared* dependency is not
pinned to an exact version (rejecting caret `^`, tilde `~`, comparators
`>= <= > <`, hyphen/X-ranges, OR-ranges, compatible-release `~=`,
floating action `@vN`/`@main` tags, floating Docker `:latest`/tag-only
refs, and bare/unpinned names).

**Runtime dynamic-matrix, same shape as the install-gate.** A `detect`
job runs `dependency-pinned-gate.sh --present` (the SAME `git ls-files`
discovery the gate checks with) and emits a JSON array of the ecosystems
whose manifest is present; a matrixed `gate` job over
`fromJSON(needs.detect.outputs.ecosystems)` runs one leg per present
ecosystem; and a `pinned-gate-required` aggregator is the single
required check. `actions` is an always-present floor (the skill always
installs workflow files). An ecosystem whose manifest lands **after**
setup (e.g. the repo's first `go.mod`) lights its leg up on the next PR,
with **no skill re-run**.

**It is a separate gate from the install-gate** — its own workflow +
script, and its own aggregator (`pinned-gate-required`) is a separate
required check from the install-gate's. Do not fold it into Step 5c; the
two protect different properties (lock-drift vs. declared-version-
floating) and a repo may want one without the other.

**Categorical exemptions live in the classifier, not an allowlist
file.** A small, fixed set of specs is *legitimately* not exact-pinnable
and is exempt by category in the script (`dependency-pinned-gate.sh`),
never by a maintained per-package allowlist: npm `peerDependencies`
carets (ranges by design); `file:`/`workspace:`/`link:`/`git+`/`http(s):`
protocol specs (no registry version to pin); npm `engines` and pip
`requires-python`/`python_requires` (runtime/toolchain floors, not
dependency versions); npm `overrides`/`resolutions` classified on the
override **value** (exact), never the selector **key** (whose caret is a
match pattern); and Docker `tag@sha256:` digests (the tag floats but the
immutable digest is read, so the resolved image is exact). These were
settled empirically against the strict-pinned
`Fablegate/fablegate_quasar_fastapi` monorepo (issue #90) — every
non-exact spec found there fell into this fixed set, so no escape-hatch
file is needed.

For **npm**, the depth is **direct deps + lockfile-present**: the
human-authored specs in `package.json` must be exact, AND a lockfile must
exist beside a deps-declaring manifest (an exact-pinned manifest with no
lockfile still floats transitively). Transitive pinning itself stays the
install-gate's job.

### The aggregator is the required check (not the per-ecosystem legs)

Exactly as the install-gate: the per-ecosystem legs
(`Pinned gate (<ecosystem>)`) are **visible** but **not** individually
required; the always-running `pinned-gate-required` aggregator (stable
name) is the single required check. It `needs:` the matrixed `gate` job,
runs `if: always()`, and concludes **success** on an empty matrix (no
ecosystem present → mergeable, not hung) or when every leg succeeded,
and **failure** when any leg failed or was cancelled. The `if: always()`
is **mandatory** for the empty-matrix-success property (a skipped
aggregator would hang the PR — #91/#230). Step 6c registers
`pinned-gate-required`, never a per-leg name.

### Render the gate files (pinned-gate)

Target paths:

- `<repo-root>/.github/workflows/dependency-pinned-gate.yml`
- `<repo-root>/.github/scripts/dependency-pinned-gate.sh`

1. Render `gh-repo-setup-protection/dependency-pinned-gate.yml` (strip
   its leading comment block) substituting **only** `__DEFAULT_BRANCH__`.
   The actions are SHA-pinned in the template — do not de-pin them (the
   pinned-gate would flag its own workflow otherwise). There is **no**
   per-job delimiter-comment rendering any more: the workflow ships with
   the full detect → matrix → aggregator shape, armed with all five
   ecosystems, and narrows at runtime.
2. `dependency-pinned-gate.sh` has no placeholders — ship it
   **verbatim** (including its leading comment block; it is a shell
   script whose header documents its own classifier behavior). The
   script accepts all five modes, the `--present` mode the detect job
   calls, and no-ops gracefully (exit 0) for any mode whose manifest the
   repo lacks. The `--present` mode reuses the same discovery predicate,
   so the runtime matrix cannot drift from what the gate checks. Ship it
   with the executable bit set (`chmod +x`).

The gate ships **unconditionally** whenever the skill installs
workflows — there is no "empty resolved set → skip the file" case any
more (an absent ecosystem produces no leg and a green aggregator). Both
files are always written together (the workflow calls the script).

Never write the `.yml` with an unresolved `__DEFAULT_BRANCH__`. If it
remains after rendering, abort per the README's unresolved-placeholder
rule.

### Converge the gate files (idempotency, pinned-gate)

Apply the same **whole-file-replace + semantic-compare** rule the skill
uses for the dependency-install-gate. For the `.yml`, first apply the
**pin-reconciliation pass (Step 5a-bis)** to the rendered desired
content so a repo's strictly-newer SHA-pinned action is **kept, never
downgraded**, before the semantic-compare:

- **`dependency-pinned-gate.yml`** — YAML semantic-compare (parse both
  the existing file and the pin-reconciled desired content as YAML,
  compare normalized structures). Equal → "unchanged"; absent → write;
  different → show the diff and halt before overwriting (whole-file
  replace, never append). The workflow is a fixed full-set-armed shape,
  so a converged repo re-runs as a no-op.
- **`dependency-pinned-gate.sh`** — this is a shell script, **not** YAML,
  so the semantic-compare is a **normalized-text/byte compare**
  (trailing-whitespace-normalized), not a YAML parse. Equal →
  "unchanged"; absent → write (with the executable bit set, `chmod +x`);
  different → show the diff and halt before overwriting.

Both files are written together: install both. Never install one without
the other (the workflow calls the script).

## Step 5d: Render and converge the no-back-merging-guard

A feature branch that brings in upstream changes by **merging the
default branch** (a "back-merge") instead of rebasing produces a tangled
history: the PR diff carries unrelated base commits, and the merge
commit's incoming parent is reachable from `origin/<default>`. This step
installs a **no-back-merging-guard** — a `pull_request` workflow whose
single job `no-back-merging-guard` walks the merge commits unique to the
PR head branch and **rejects** any whose incoming (second) parent is
reachable from the base branch tip, forcing rebase-not-merge. The
artifact is ported verbatim (script + self-test) from the proven
`Fablegate/fablegate_quasar_fastapi` guard (issue #51).

### Ships unconditionally — no ecosystem gate

Unlike the dependency-install-gate (npm/pip/pnpm/yarn-gated) and CodeQL
(language/entitlement-gated), the no-back-merging-guard has **no
ecosystem dependency**. It is pure git-history hygiene and is desirable
on **every** repo. So it ships **unconditionally** on every run (subject
only to the converge/semantic-compare rules below). There is no flag to
disable it; managing branch-merge policy elsewhere is not a supported
mode for this guard.

### Render the guard files

Target paths:

- `<repo-root>/.github/workflows/no-back-merging-guard.yml`
- `<repo-root>/.github/scripts/no-back-merging-guard.sh`
- `<repo-root>/.github/scripts/test-no-back-merging-guard.sh`

1. Render `gh-repo-setup-protection/no-back-merging-guard.yml` (strip its
   leading comment block) substituting `__DEFAULT_BRANCH__`. This is the
   only placeholder — it appears in the `on.pull_request.branches` filter
   and in the explanatory comments. The per-PR base comparison is read
   from `github.base_ref` at run time, so the guard still follows a
   base-branch rename for the actual back-merge check; the
   `__DEFAULT_BRANCH__` substitution only scopes which PRs the workflow
   triggers on.
2. `no-back-merging-guard.sh` and `test-no-back-merging-guard.sh` have
   **no placeholders** — ship them **verbatim** (including their leading
   comment blocks; they are shell scripts whose headers document their
   own behavior, not placeholder blocks to strip). Set the executable
   bit (`chmod +x`) on both when writing, matching the
   `dependency-install-gate.sh` convention.

Never write the `.yml` with an unresolved `__DEFAULT_BRANCH__`. If it
remains after substitution, abort per the README's unresolved-
placeholder rule.

### Converge the guard files (idempotency)

Apply the same **whole-file-replace + semantic-compare** rule the skill
uses for the dependency-install-gate, with the per-file-type compare.
For the `.yml`, first apply the **pin-reconciliation pass (Step
5a-bis)** to the rendered desired content so a repo's strictly-newer
SHA-pinned `actions/checkout` is **kept, never downgraded**, before the
semantic-compare:

- **`no-back-merging-guard.yml`** — YAML semantic-compare (parse both the
  existing file and the pin-reconciled desired content as YAML, compare
  normalized structures). Equal → "unchanged"; absent → write; different
  → show the diff and halt before overwriting (whole-file replace, never
  append).
- **`no-back-merging-guard.sh`** and **`test-no-back-merging-guard.sh`**
  — these are shell scripts, **not** YAML, so the semantic-compare is a
  **normalized-text/byte compare** (trailing-whitespace-normalized), the
  same rule used for `dependency-install-gate.sh`. Equal → "unchanged";
  absent → write (with the executable bit set, `chmod +x`); different →
  show the diff and halt before overwriting.

All three files are written together (the workflow invokes the script;
the self-test documents and verifies the script). Never install the
workflow without its script.

## Step 6: Create / converge the `protect-main` ruleset

Skip this entire step if `--ruleset=off`.

The GHAS features above are half-measures without a ruleset that
enforces review and required checks on the default branch. This skill
**owns** the `protect-main` ruleset and converges it on every run, the
same read-then-reconcile way it converges the GHAS toggles. The proven
reference shape is `ExampleProject/example-app-repo`'s `protect-main`.

### 6a. Read the existing ruleset

A repository ruleset is identified by name, not a stable ID, so list
and match on `name == "protect-main"`:

```bash
# Find an existing protect-main ruleset (empty output = none yet).
# --paginate: the rulesets list can span multiple pages; without it a
# protect-main ruleset on page 2+ is missed, wrongly concluding "none
# yet" and creating a duplicate.
gh api --paginate repos/__GH_ORG__/__GH_REPO__/rulesets \
  --jq '.[] | select(.name=="protect-main") | .id'
```

If found, read its full body so you can compare against the desired
shape and PUT only when it differs:

```bash
gh api repos/__GH_ORG__/__GH_REPO__/rulesets/<ID>
```

### 6b. Build the desired ruleset body

The desired body (targets the default branch; `enforcement: active`):

```json
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": true,
        "required_review_thread_resolution": true,
        "required_reviewers": [],
        "allowed_merge_methods": ["merge"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": []
      }
    }
  ]
}
```

Notes on the shape:

- `~DEFAULT_BRANCH` is GitHub's symbolic ref for the repo's default
  branch — use it so the ruleset follows a default-branch rename.
- `require_last_push_approval: true` is **issue #222 item 6** — "Require
  approval of the most recent reviewable push".
- `require_code_owner_review: true` requires a `CODEOWNERS` file to be
  meaningful. If the repo has no `.github/CODEOWNERS` (or root/`docs/`
  variant), still set it true (it is a no-op until CODEOWNERS exists)
  but **report** "code-owner review required, but no CODEOWNERS file
  present — add one for it to take effect".
- `required_review_thread_resolution: true` ("Require conversation
  resolution before merging"). The reference repo currently has this
  `false`; the hardened baseline this skill converges to is `true`.
- `bypass_actors` grants the built-in **Repository admin** role
  (`actor_id: 5`, `actor_type: "RepositoryRole"`) a **PR-only** bypass
  (`bypass_mode: "pull_request"`). This is **issue #61**: on a
  single-maintainer repo whose sole writer is also the sole code-owner
  and the last pusher (CODEOWNERS `* @owner`), the combination of
  `require_last_push_approval` + `require_code_owner_review` is
  unsatisfiable — the only eligible approver is the last pusher, which
  last-push-approval forbids, so no PR can ever merge. A PR-only admin
  bypass lets the maintainer merge their own PRs while leaving the
  `deletion` and `non_fast_forward` protections fully enforced (the
  bypass mode is `pull_request`, not the broader unrestricted bypass).
  `actor_id: 5` is the documented built-in Admin repository role;
  confirm it on the first PUT. This entry must be **ensured** on every
  converge run (added if missing) while preserving any other
  `bypass_actors` the repo already has — see 6d.
- The `required_status_checks` list starts **empty** in this template
  and is filled by the generic gate in 6c. **GitHub rejects a
  `required_status_checks` rule whose `required_status_checks` array is
  empty with a 422** (the whole rule is dropped), so the gate must
  contribute at least one real check for the rule to be includable.
  Because the no-back-merging-guard ships **unconditionally** (Step
  5d), its check is present on every successful run, so the array is
  never empty in practice — the empty starting state is only the
  pre-gate template, never what is PUT. Never hard-code a check whose
  workflow may not exist.

### 6c. Gate each required status check on its producing workflow (#91/#230 guard)

This is the **generic mechanism** issue #222 delivers, generalized by
issue #61: a required status check is added to the ruleset **iff the
workflow that produces it is present in the repo this run**.
"Present in the repo this run" is the gate condition — broader than the
old "installed *by this skill* this run". A producing workflow counts
as present when the skill wrote/converged it this run **or** when it
already existed in `.github/workflows/` and the skill left it unchanged
(converged-as-unchanged, or simply present and skill-owned). What still
disqualifies a check is the workflow being **absent** from the repo
after this run — registering a check whose producing workflow never
uploads results recreates the issue #91 phantom-check hang, where every
PR waits forever for a result that never comes.

**The required checks are the workflows' AGGREGATORS, never per-leg
names.** Each of CodeQL and the two gates now runs a dynamic matrix and
exposes a single always-running aggregator (`codeql-required`,
`install-gate-required`, `pinned-gate-required`) whose stable name is
what the ruleset lists. GitHub `required_status_checks` is a static list
of names and **cannot** express "require `Analyze (python)` only if it
runs" — listing a per-leg name on a repo lacking that language/PM hangs
the PR forever (the #91/#230 failure mode). So the gate is applied at
**workflow** granularity: present workflow → add its aggregator context;
absent workflow → omit it. The per-leg legs stay **visible** (red/green,
only when their language/ecosystem is present) but are **never**
individually required.

- For each candidate aggregator, the skill knows (from this run) whether
  the producing workflow is **present in the repo**. If present → add
  the aggregator's context to `required_status_checks`. If absent →
  **omit it** and report the skip with the #91 rationale.
- **CodeQL** — add the aggregator context **iff CodeQL resolved on and
  its workflow is present in the repo this run** (Step 5b wrote or
  converged it, or it already existed):

  ```json
  { "context": "codeql-required" }
  ```

  The `codeql-required` aggregator passes green when the runtime matrix
  is empty (no analyzable language present), so a language-less repo is
  mergeable, not hung. When CodeQL is off (no workflow present), omit it
  and report "codeql-required required check: skipped (no CodeQL
  workflow present — would be a phantom required check, issue #91)".

  When CodeQL **is** on, also express **code scanning** and **code
  quality** as ruleset rules (issue #222 items 7/8; matching the
  reference shape) — these are result-consuming rule types, orthogonal
  to the status-check aggregator:

  ```json
  {
    "type": "code_scanning",
    "parameters": {
      "code_scanning_tools": [
        {
          "tool": "CodeQL",
          "security_alerts_threshold": "high_or_higher",
          "alerts_threshold": "errors"
        }
      ]
    }
  },
  { "type": "code_quality", "parameters": { "severity": "errors" } }
  ```

  Append these to the `rules` array only when CodeQL is on this run.
- **Dependency-install-gate** (issue #238, extended by issue #111) is
  produced by the `dependency-install-gate.yml` workflow installed in
  Step 5c. Add its **aggregator** context to `required_status_checks`
  **iff that workflow is present in the repo this run** (Step 5c
  wrote/converged it, or it already existed):

  ```json
  { "context": "install-gate-required" }
  ```

  Do **not** register the per-PM leg names (`Install gate (npm)`, etc.)
  — those are dynamic and would hang a PR on a repo lacking that PM. The
  aggregator passes green when the runtime matrix is empty (no PM
  present). When the gate workflow is **absent** from the repo after
  this run, omit `install-gate-required` and report "install-gate
  required check: skipped (no dependency-install-gate workflow present —
  would be a phantom required check, issue #91/#230)".
- **Dependency-pinned-gate** (issue #90) is produced by the
  `dependency-pinned-gate.yml` workflow installed in Step 5c-pinned. Add
  its **aggregator** context to `required_status_checks` **iff that
  workflow is present in the repo this run**:

  ```json
  { "context": "pinned-gate-required" }
  ```

  Do **not** register the per-ecosystem leg names — same phantom-check
  hazard. The aggregator passes green on an empty runtime matrix. When
  the pinned-gate workflow is **absent** from the repo after this run,
  omit `pinned-gate-required` and report "pinned-gate required check:
  skipped (no dependency-pinned-gate workflow present — would be a
  phantom required check, issue #91/#230)". The two gates' aggregators
  are **distinct** contexts (`install-gate-required` vs.
  `pinned-gate-required`), so a repo running both requires both to pass,
  with no context collision.
- **No-back-merging-guard check** (issue #51) is produced by the
  `no-back-merging-guard.yml` workflow installed in Step 5d. Add its
  context to `required_status_checks` **iff that workflow is present in
  the repo this run**. The check context is the job name from the
  workflow:

  ```json
  { "context": "no-back-merging-guard" }
  ```

  Because Step 5d installs the guard **unconditionally**, this workflow
  is present on every successful run, so the check is registered on
  every run — but it still goes through the same generic gate (it is
  added because its producing workflow is present in the repo this run,
  never standalone), preserving the issue #91/#230 phantom-check
  invariant. Under the generalized "present in the repo" gate, a Step 5d
  diff-halt that leaves the **existing** workflow file in place still
  counts the workflow as present (the file is on disk, just awaiting a
  converge), so the check stays registered. The check is omitted only
  when the guard workflow is genuinely **absent** from the repo after
  this run — report "no-back-merging-guard required check: skipped
  (workflow not present in the repo this run — would be a phantom
  required check, issue #91/#230)". Because the guard ships
  unconditionally and is owned by this skill, the registered check is
  also what keeps `required_status_checks` non-empty, so the rule is
  always includable (avoiding the empty-array 422 described in 6b).
- **Future producing workflows** plug into this same gate: when a
  workflow is present in the repo, its check contexts are added to
  `required_status_checks`; until then they are omitted.

The `integration_id` on a `required_status_checks` entry (the reference
uses `15368`, GitHub Actions) is optional — omit it and GitHub matches
the check by `context` alone, which is what the gate wants.

### 6d. Converge (create or update)

- **No existing ruleset** → create it:

  ```bash
  gh api --method POST repos/__GH_ORG__/__GH_REPO__/rulesets \
    --input <desired-body.json>
  ```

- **Existing ruleset that differs** → update it (PUT replaces the
  ruleset body so the skill owns its shape; semantic-compare first and
  skip when already equal so a converged re-run is a no-op):

  ```bash
  gh api --method PUT repos/__GH_ORG__/__GH_REPO__/rulesets/<ID> \
    --input <desired-body.json>
  ```

**Semantic-compare, not byte-compare — normalize before deciding to
PUT.** The server returns a ruleset body that is *equivalent to but not
byte-identical with* the desired body. A naive compare would re-PUT
every run and break the headline idempotency guarantee. Normalize these
fields before comparing, and treat them as equal when:

- **`conditions.ref_name.include`** — the server may store
  `["refs/heads/main", "~DEFAULT_BRANCH"]` (the reference repo's shape)
  while the desired body carries only `["~DEFAULT_BRANCH"]`. Treat an
  existing `include` as **already converged** when it is equivalent to —
  or a superset that contains — the desired symbolic ref
  (`~DEFAULT_BRANCH`, or the concrete `refs/heads/<default-branch>` it
  resolves to). Do **not** re-PUT merely to strip the redundant concrete
  entry; that churn is a spurious write, not a convergence.
- **`required_status_checks`** — the server stores an `integration_id`
  on each check (the reference uses `15368`, GitHub Actions) that the
  desired body omits. **Compare on `context` only** (the set of check
  contexts), ignoring `integration_id` presence/absence. Equal context
  sets → no re-PUT, even though the stored entries carry an extra
  `integration_id`.
- **`bypass_actors`** — the desired body asserts the admin PR-only
  entry (`actor_id: 5`, `actor_type: "RepositoryRole"`,
  `bypass_mode: "pull_request"`); the existing ruleset may carry that
  same entry plus other actors the repo added (e.g. a team
  `pull_request` bypass). Treat the existing `bypass_actors` as
  **already converged** when it **contains** the admin PR-only entry
  (regardless of any additional actors). Compare on the
  `(actor_id, actor_type, bypass_mode)` tuple; the server may add no
  extra fields here, so a plain set-containment check on those three
  keys suffices. Only the **absence** of the admin entry is a semantic
  difference that warrants a PUT — and the PUT carries the existing
  actors plus the admin entry (see the preserve-and-ensure rule below),
  never a replacement that drops the others.

Only PUT when a semantic difference remains after this normalization.

**Graceful-skip a `code_quality` 422.** The `code_quality` rule type is
limited-availability and may not be enabled for the org/repo. If the
create/update returns a `422` attributable to the `code_quality` rule
(message naming `code_quality` / "Code quality" / an unsupported rule
type), do **not** hard-fail the whole ruleset convergence — retry the
same call with the `code_quality` rule dropped from the `rules` array,
and report "code quality required check: skipped (rule type not
available for this repo)". The rest of the ruleset (deletion,
non-fast-forward, `pull_request`, `required_status_checks`, and the
`code_scanning` rule) still converges. This mirrors the graceful
entitlement degradation the GHAS toggle steps already apply to a 422.

**Preserve-and-ensure `bypass_actors`.** Two rules apply together:

- **Preserve** any `bypass_actors` the repo already has (the reference
  repo grants a team `pull_request` bypass) — read them from 6a and
  carry them through unchanged rather than clearing them; clearing a
  bypass list is a posture change the operator owns.
- **Ensure** the admin PR-only entry (`actor_id: 5`,
  `actor_type: "RepositoryRole"`, `bypass_mode: "pull_request"`) is
  present (issue #61). On every converge run, compute the union of the
  existing actors and this admin entry: if the admin entry is already
  in the existing list (matched on the
  `(actor_id, actor_type, bypass_mode)` tuple), it is a no-op; if it is
  missing, add it while keeping every other actor. Never replace the
  list with the admin entry alone — that would drop the operator's
  other bypasses, violating the preserve rule.

So the converged `bypass_actors` is always
`existing ∪ {admin PR-only entry}`. On a freshly created ruleset (no
existing actors) that is just the admin entry; on a repo with a
pre-existing team bypass it is that team plus the admin entry. Report
the ruleset as `created`, `updated (changed: <fields>)`, or
`unchanged`.

Write nothing to disk in this step — a ruleset is server-side state,
like the GHAS toggles. The skill applies it directly and reports it.

## Step 7: Commit, push, and open a PR for the rendered files

After rendering and converging its files (Steps 3, 5b, 5c, 5c-pinned,
5d), the
skill **commits, pushes, and opens a PR** for those files — **always**,
on a **single approval**. There is no flag to disable this and no
"am I being orchestrated?" knob: the skill always produces a PR for its
own rendered files. Only the **rendered files** go through this branch →
commit → push → PR flow. The **remote API changes** — the GHAS toggles
(Step 4), the merge-button settings (Step 4e), and the `protect-main`
ruleset (Step 6) — are not file edits and cannot live in a PR, so they
were already applied directly to the repo and are **not** part of this
PR.

### 7a. Skip cleanly when there is nothing to commit

If every rendered file converged as `unchanged` (a no-op run against an
already-configured repo — the headline idempotency case), there is
**nothing to commit**: skip this step entirely, report "no file changes
to commit; no PR opened", and proceed to the report (Step 8). A
converged re-run must not produce an empty PR.

### 7b. Present the changes and get one approval

Show the operator the rendered file changes (the diff) and ask for a
single approval that covers commit + push + PR together — **not** three
separate prompts:

```bash
git status --short -- .github/
git diff -- .github/        # plus any staged/new files under .github/
```

```text
gh-repo-setup-protection rendered these files:
  <list of written/changed files under .github/>

On approval I will, in one go:
  1. Commit them on a branch named after this skill
     (gh-repo-setup-protection).
  2. Push that branch.
  3. Open a PR targeting the default branch (<default-branch>).

The remote settings (GHAS toggles, merge-button settings, protect-main
ruleset) were already applied directly and are NOT part of this PR.

Proceed with commit + push + PR? (y to do all three, or no to leave the
files uncommitted for you to handle)
```

If the operator declines, leave the rendered files uncommitted in the
working tree and report "files left uncommitted at operator's request;
no PR opened". Do not partially commit.

### 7c. Commit, push, and open the PR

On approval, do all three with no further prompts:

```bash
# Branch named after the skill. Create it from the current default-branch
# tip if it does not exist; reuse it if a prior run left it.
git switch -c gh-repo-setup-protection \
  || git switch gh-repo-setup-protection

git add -- .github/
git commit -m "Converge repo protection config (gh-repo-setup-protection)"

git push -u origin gh-repo-setup-protection

gh pr create --base "__DEFAULT_BRANCH__" \
  --head gh-repo-setup-protection \
  --title "Converge repo protection config" \
  --body "Rendered by /gh-repo-setup-protection: Dependabot config, CodeQL
workflow (when on), dependency-install-gate (when npm/pip/pnpm/yarn present), and
the no-back-merging-guard. Remote settings (GHAS toggles, merge-button
settings, protect-main ruleset) were applied directly to the repo and
are not part of this PR."
```

Capture and report the PR URL. If a PR already exists for the branch
(`gh pr create` reports it), report that URL instead of failing.

**Nice-to-have — do the file work in a git worktree.** The skill does
not currently require running from inside a worktree (it is meant to be
run directly on a repo being transitioned), but rendering and committing
the files in a dedicated worktree would isolate the operator's working
tree from the skill's edits. Adding worktree support is a welcome
improvement, not a requirement for this step.

## Step 8: Report and next steps

Print a converged-state summary:

```text
gh-repo-setup-protection — <owner>/<repo> (default branch: <branch>)

Files (written / unchanged / skipped):
  .github/dependabot.yml                          <written|unchanged>  (always written — github-actions floor)
  .github/workflows/codeql.yml                    <written|unchanged|skipped: reason>
  .github/codeql/codeql-config.yml                <written|unchanged|skipped: reason>
  .github/workflows/dependency-install-gate.yml   <written|unchanged|skipped: reason>
  .github/scripts/dependency-install-gate.sh      <written|unchanged|skipped: reason>
  .github/workflows/dependency-pinned-gate.yml    <written|unchanged|skipped: reason>
  .github/scripts/dependency-pinned-gate.sh       <written|unchanged|skipped: reason>
  .github/workflows/no-back-merging-guard.yml     <written|unchanged>
  .github/scripts/no-back-merging-guard.sh        <written|unchanged>
  .github/scripts/test-no-back-merging-guard.sh   <written|unchanged>

GHAS settings (each idempotent, re-asserted every run):
  Code Security (Advanced Security)  <enabled changed|was on|skipped: why>
  Dependabot alerts                  <enabled changed|was on|skipped: why>
  Dependabot security updates        <...>
  Dependabot grouped security updates <via dependabot.yml | settings UI>
  Dependabot malware alerts          <enabled|UI-only (npm); manual step>
  Secret scanning                    <...>
  Secret scanning push protection    <...>
  Push-protection bypass lockdown    <delegated bypass on | manual: nobody>

Merge-button / PR-hygiene settings (each idempotent, re-asserted every run):
  Allow squash merging   (off)       <unchanged|changed>
  Allow rebase merging   (off)       <unchanged|changed>
  Allow merge commit     (on, kept)  <unchanged>
  Suggest update branch  (on)        <unchanged|changed>
  Allow auto-merge       (on)        <unchanged|changed>
  Auto-delete head branch (on)       <unchanged|changed>

CodeQL decision: <on|off> (<reason>)
  Default setup: <correctly not configured (advanced setup active — the two cannot coexist) | was configured → disabled | left as-is>

protect-main ruleset: <created|updated|unchanged|skipped (--ruleset=off)>
  require_last_push_approval         <true>
  Admin PR-only bypass               <ensured | already present>
  Required status checks (aggregators, not per-leg names):
    codeql-required                    <added (CodeQL present) | skipped (#91)>
    install-gate-required              <added (gate present) | skipped (#91)>
    pinned-gate-required               <added (gate present) | skipped (#91)>
    no-back-merging-guard              <added (guard present) | skipped (#91)>
  code scanning / code quality rules   <added (CodeQL on) | skipped>

Armed Dependabot ecosystems: <full supported set minus de-arms>  (present in tree: <raw scan>)
Armed drift-gate PMs: <npm/pip/pnpm/yarn minus de-arms>  (runtime matrix narrows to present)
Armed pinned-gate ecosystems: <npm/pip/actions/docker/go minus de-arms>  (runtime matrix narrows to present)
Armed CodeQL languages: <full supported set minus de-arms; runtime matrix narrows to present>  (present in tree: <raw scan>)

Rendered-files PR: <URL | no file changes to commit | left uncommitted at operator's request>

Next steps:
  1. Review and merge the rendered-files PR above (if one was opened).
  2. Re-run /gh-repo-setup-protection any time — it converges and is a
     no-op when everything is already in the desired state (no empty PR).
```

On a run with file changes, the rendered files land in a PR on the
`gh-repo-setup-protection` branch (Step 7) on a single approval; the
remote settings (GHAS toggles, merge-button settings, ruleset) were
applied directly. A converged re-run with no file changes opens no PR.

---

## Convergence strategy (summary — the headline requirement)

This skill is designed to be run repeatedly across many repos and on
the same repo many times. The convergence guarantees:

- **Deterministic render.** Dependabot ecosystem blocks are emitted in
  sorted order, and CodeQL / the two gates ship a fixed full-set-armed
  workflow shape (the language/ecosystem narrowing is a runtime concern,
  not part of the rendered bytes), so the same repo always renders the
  same bytes. A second run with no repo change produces an identical
  file → no diff → nothing to commit.
- **Whole-file replace, never append.** The skill owns the shape of
  `dependabot.yml`, `codeql.yml`, and `codeql-config.yml`. It computes
  the desired content from scratch each run and replaces the file's
  contents, rather than appending entries. Appending is the classic
  source of duplicate ecosystem blocks on re-run; replacing eliminates
  it.
- **Semantic compare before write.** Before overwriting, the skill
  compares the existing file to the desired content (YAML-normalized
  for the dependabot/codeql configs). Equal → no write, reported as
  "unchanged". This keeps `git status` clean on no-op runs.
- **Halt before destroying user edits.** If the existing file contains
  `updates:`/config entries the render would drop (hand-added
  ecosystems, custom `ignore:`/`reviewers:` blocks, tuned
  `paths-ignore`), the skill shows the diff and asks before
  overwriting. Convergence never silently discards human customization.
- **Idempotent GHAS toggles.** Each security setting is read first and
  PUT/PATCH-ed only when it differs from desired; the GitHub API
  endpoints used are themselves idempotent (PUT returns 2xx whether or
  not the feature was already on). Re-running reports "was already on".
- **Idempotent merge-button settings.** The five General-settings
  merge-button fields (Step 4e) are read first and PATCH-ed convergently
  to the hardened state; re-running reports each as `unchanged` once
  converged. Like the GHAS toggles, these are remote settings applied
  directly, not file edits in the PR.
- **PR for rendered files on a single approval.** The rendered files
  (Dependabot config, CodeQL workflow when on, the gates/guard) are
  committed, pushed, and PR-ed on the `gh-repo-setup-protection` branch
  on one approval (Step 7). A no-op run with no file changes opens no PR.
  The remote settings never go through the PR.
- **Graceful entitlement degradation.** On an unentitled private repo,
  GHAS-only features (secret scanning, CodeQL) are skipped with a clear
  reason instead of erroring — so the same skill invocation works
  unchanged across a public repo, an entitled private repo, and an
  unentitled private repo.

### Read-then-converge surface audit

Every surface the skill writes must **read the existing state first**
and converge against it — never write blind. The issue #230 wedge was a
surface (server-side CodeQL setup mode) the skill wrote without reading.
This table is the audit; each row must hold on every run, including a
no-op run against an already-configured repo:

| Surface | Read before write | Step |
| --- | --- | --- |
| `dependabot.yml` | Parse YAML, semantic-compare | 3 |
| `codeql.yml` / `codeql-config.yml` | Parse YAML, semantic-compare | 5b |
| `dependency-install-gate.yml` | Parse YAML, semantic-compare | 5c |
| `dependency-install-gate.sh` | Normalized-text/byte compare | 5c |
| `dependency-pinned-gate.yml` | Parse YAML, semantic-compare | 5c-pinned |
| `dependency-pinned-gate.sh` | Normalized-text/byte compare | 5c-pinned |
| `no-back-merging-guard.yml` | Parse YAML, semantic-compare | 5d |
| `no-back-merging-guard.sh` | Normalized-text/byte compare | 5d |
| `test-no-back-merging-guard.sh` | Normalized-text/byte compare | 5d |
| CodeQL server-side setup mode | `code-scanning/default-setup` read | 5a |
| Code Security (Advanced Security) | Read status, PATCH if off | 4b |
| Dependabot alerts / security updates | PUT idempotent; read for report | 4a |
| Dependabot malware alerts / grouping | Read state; best-effort + report | 4a |
| Secret scanning / push protection | Read state, PATCH only diffs | 4c |
| Push-protection bypass lockdown | Read state; best-effort + report | 4d |
| Merge-button / PR-hygiene settings | Read state, PATCH only diffs | 4e |
| `protect-main` ruleset | List by name, read body, PUT only diffs | 6 |
| `protect-main` `bypass_actors` | Read existing, ensure admin PR-only entry, preserve others | 6d |
| Required status checks | Gated on producing workflow present in the repo this run | 6c |

Every row converges on re-run: file surfaces semantic-compare and skip
when equal; GHAS toggles are idempotent and report "was already on"; the
CodeQL setup mode disables a conflicting default setup (operator
confirmed) before installing advanced, or installs nothing if the
operator declines; the ruleset is read by name, semantic-compared, and
PUT only when it differs.

The required-status-checks row is the load-bearing one: this skill now
**owns** the `protect-main` ruleset, but it registers a required check
**only when that check's producing workflow is present in the repo this
run** (Step 6c). It installs the CodeQL *workflow* and the code
scanning / code quality required checks **together**, never the checks
alone — registering a check against a workflow that cannot produce
results is exactly how the repo wedged (issues #91, #230). Because the
no-back-merging-guard ships unconditionally, its check is always
present, which also keeps `required_status_checks` non-empty (GitHub
422s on an empty array — issue #61). The `bypass_actors` row is the
companion: the admin PR-only entry is ensured on every run and the
operator's other actors preserved, so a single-maintainer repo is not
deadlocked. A no-op run against a fully-configured repo writes nothing,
mutates no server-side state, and leaves `git status` clean.

---

## Hard constraints

- **Commit + push + PR the rendered files on a single approval, always.**
  After rendering its files (Steps 3, 5b, 5c, 5c-pinned, 5d), the skill commits,
  pushes, and opens a PR for them on a branch named after the skill
  (`gh-repo-setup-protection`), targeting the default branch — on **one**
  approval covering all three (Step 7). There is no `--commit` flag, no
  opt-out, no "am I being orchestrated?" knob: the skill always produces
  a PR for its own rendered files. The single approval still satisfies
  global rule §0 (the operator explicitly approves before any commit /
  push). A no-op run with no file changes opens no PR. The **remote API
  changes** (GHAS toggles, merge-button settings, ruleset) are applied
  directly and are never part of the PR.
- **Arm the full supported set; the Step 2b checklist only de-arms.**
  Every surface (CodeQL languages, both gates' ecosystems, Dependabot
  ecosystems) is armed with its full supported set at install time and
  narrows to the present set at runtime (CodeQL and the gates via their
  `detect` jobs; Dependabot no-ops on absent manifests). The Step 2b
  multi-tab checklist (drift-gate / pinned-gate / Dependabot / CodeQL)
  defaults to **everything armed**; the operator may only **de-arm** a
  language/ecosystem they never want. This structurally removes the
  protect-before-code ordering inversion — a new language/ecosystem's
  check/coverage appears the first time its source lands, with no skill
  re-run. Only `--dry-run` skips the checklist (arm the full set). The
  CodeQL tab bounds the *armed language set* only — it never overrides
  the on/off decision or the entitlement guard in Step 5, and de-arming
  every language does not turn CodeQL off (the runtime matrix simply
  never spawns a leg and the aggregator is green).
- **Never auto-force CodeQL.** CodeQL is opt-in: it is enabled by an
  explicit `--codeql=on` operator override or by auto-detection, and
  **auto-detection** always skips the unentitled-private repo. The skill
  never lets auto-detection turn CodeQL on for such a repo — that is what
  recreates the issue #91 phantom-check hang (see "CodeQL is opt-in" for
  the inlined rationale). An explicit `--codeql=on` is the operator's
  deliberate choice and is honored; what is forbidden is CodeQL silently
  *auto*-resolving on. (Markdown-only repos are no longer a separate
  auto-skip case: `actions` is the always-present floor, so every repo
  the skill touches has an analyzable language — the remaining auto-skip
  is the entitlement one.)
- **The CodeQL workflow can never deadlock on an absent language, and
  never leaves a conflicting default setup in place.** The workflow is
  armed with the full supported language set and narrows to the present
  languages at runtime; an empty runtime matrix spawns zero analyze legs
  and the `codeql-required` aggregator passes green, so a
  language-less repo is mergeable, not hung (this replaces the old
  install-time no-supported-language hard stop). When installing
  advanced setup, the skill first reads the server-side default-setup
  mode and disables it (with operator confirmation) so the two cannot
  coexist (issue #230).
- **Never append to a config file.** Always whole-file replace from a
  deterministic render so re-runs converge instead of duplicating.
- **Never overwrite user customization silently.** Halt and show the
  diff when the existing file has entries the render would drop.
- **Never downgrade a newer SHA-pinned action pin on converge.** When a
  repo's workflow already pins an action (`actions/checkout`,
  `github/codeql-action`, any `uses:` line) to a SHA whose upstream
  release tag is **strictly newer** than the payload's, the converge
  **keeps the repo's pin** — automatically, with no prompt, and never
  offers a downgrade (Step 5a-bis, applied by Steps 5b/5c/5c-pinned/5d). "Newer"
  is decided by resolving **both** SHAs to their upstream release tags
  and comparing by semver; the trailing `# vX.Y.Z` comment is
  display-only and is never trusted. A pin that is older, equal,
  floating (a `@vN` tag, not a 40-hex SHA), or **unresolvable** (deleted
  tag, fork, private action, API failure) converges to the payload's
  pin. "Match the payload" thus excludes downgrading a deliberately-
  newer SHA-pinned repo pin.
- **Never write a file with unresolved `__...__` placeholders.** Abort
  per the README's unresolved-placeholder rule.
- **Always write `dependabot.yml`, armed with the full supported
  ecosystem set.** Render one `updates:` block per supported ecosystem
  (`github-actions`, `npm`, `pip`, `docker`, `gomod`, `bundler`,
  `cargo`, `maven`, `gradle`, `composer`, `terraform`) minus any Step 2b
  de-arms — never narrowed to detected ecosystems. Dependabot no-ops on
  an ecosystem whose manifest is absent, so the full set adds no spurious
  update PRs; the `updates:` list is never empty and the old "no
  ecosystem detected → skip the file" path is gone. Resolve the correct
  **class variant** per ecosystem (no `versioning-strategy` on
  docker/github-actions — Dependabot rejects it; `github-actions` uses
  singular `directory: "/"` + weekly; others use recursive
  `directories: **/*` + daily) — a wrong variant makes Dependabot reject
  the whole config (Step 3).
- **CodeQL, both gates arm the full set and gate at runtime — never
  install-time-narrow.** Ship `codeql.yml`,
  `dependency-install-gate.yml`, and `dependency-pinned-gate.yml` with
  their full detect → matrix → aggregator shape (armed with the full
  supported language/ecosystem set), plus their sibling scripts
  (`codeql-language-present.sh`, `dependency-install-gate.sh`,
  `dependency-pinned-gate.sh`, all with the executable bit set). Each
  narrows to the present set at runtime via its `detect` job (the SAME
  `git ls-files` predicate the analysis/gate uses — detection defined
  once per surface). The two gates are **separate** (own workflow,
  script, and aggregator); do not fold them together. The pinned-gate's
  categorical exemptions (peerDependencies carets, `file:`/`workspace:`
  specs, `engines`/`requires-python` floors, override-value
  classification, `tag@sha256:` digests) live in the classifier script,
  never in a maintained allowlist file.
- **The required check per surface is its AGGREGATOR, never a per-leg
  name.** Add `codeql-required`, `install-gate-required`, and
  `pinned-gate-required` to `protect-main` **iff** each surface's
  workflow is present in the repo this run (Step 6c) — never a per-leg
  name like `Analyze (python)` or `Install gate (npm)`, which would hang
  a PR on a repo lacking that language/PM (issue #91/#230). Each
  aggregator passes green on an empty runtime matrix, so a repo missing
  the guarded languages/ecosystems is mergeable.
- **Swift never provisions macOS when absent.** The CodeQL detect job
  adds a `swift` matrix entry (carrying `runner: macos-latest`) only
  when `*.swift` is present; a Swift-less repo shows no swift leg and
  never bills for a macOS runner.
- **Always install the no-back-merging-guard, and its three files
  together.** The guard ships **unconditionally** (Step 5d) — no
  ecosystem gate, no disable flag; it is pure git-history hygiene.
  Install `no-back-merging-guard.yml`,
  `no-back-merging-guard.sh`, and `test-no-back-merging-guard.sh`
  together (the workflow invokes the script; the self-test verifies it);
  ship the two scripts verbatim with the executable bit set. Add the
  `no-back-merging-guard` required check to `protect-main` only when the
  workflow is present in the repo this run (Step 6c) — which, because
  the guard is unconditional, is every successful run — never
  standalone (issue #91/#230).
- **Never edit anything outside the current repo.** All file writes go
  under `<repo-root>/.github/`. Scratch work, if any, goes under
  `<repo-root>/.claude/tmp/gh-repo-setup-protection/`, never `/tmp/`.
- **Treat a missing GHAS entitlement as a skip, not a failure.** A 422
  "Advanced Security is not enabled" on a private repo is expected and
  must be reported as a graceful skip.
- **Never register a required status check whose producing workflow is
  not present in the repo this run.** Required checks in `protect-main`
  go through the Step 6c gate: a check is added iff its producing
  workflow is present in the repo this run (written/converged this run
  or already on disk). Code scanning / code quality are added iff
  CodeQL is on and its workflow is present this run. Adding a check
  against a workflow that cannot produce results is the issue #91/#230
  wedge.
- **Always ensure the admin PR-only `bypass_actors` entry, and never
  clear an existing ruleset's `bypass_actors`.** On every converge run,
  ensure the built-in Repository admin role (`actor_id: 5`,
  `actor_type: "RepositoryRole"`, `bypass_mode: "pull_request"`) is in
  `bypass_actors` (issue #61 — otherwise a single-maintainer repo
  deadlocks on last-push-approval + code-owner review), adding it if
  missing. Read the existing actors from 6a and carry them through
  unchanged — the converged list is `existing ∪ {admin PR-only}`, never
  a replacement that drops the operator's other actors. Changing the
  rest of the bypass list is a posture decision the operator owns.
- **Best-effort, never hard-fail, on under-specified GHAS toggles.**
  Malware alerts, grouped-security-updates settings enablement, and the
  push-protection bypass list have no stable public per-repo REST
  toggle. Attempt the documented shape, treat a 422/404 as "do this one
  step in the UI", and report the residual manual step — do not invent
  an endpoint or abort.

---

## Out of scope

- **Purchasing / enabling a GHAS entitlement** on a private repo. The
  skill detects the lack of entitlement and skips; buying GHAS is an
  org-billing decision for the user.
- **Tuning CodeQL queries / `paths-ignore` per repo.** The shipped
  `codeql-config.yml` is a sane default; the user refines it after the
  first scan.
- **Deleting an existing CodeQL workflow** when `--codeql=off`. Removing
  a security workflow is the user's call; the skill reports its presence
  and leaves it in place.
- **The live multi-repo verification** required by the issue's third
  acceptance criterion. The skill is built to run idempotently across
  repos (including one where CodeQL is off), but exercising it against
  the four live repos is an operational step the user performs.
