# github-setup changelog

## 0.11.6 — 2026-09-11

Internal only: the App-permission rationale in two skills no longer
cites a rules file outside the plugin.

## 0.11.5 — 2026-08-20

The PR-automation App's starter permission set gains `Checks: read` and
`Commit statuses: read`. Without them an App gets a 403 on the REST
check-run and commit-status reads, and a `FORBIDDEN` error from the
`statusCheckRollup` read the rendered workflows gate on.

Scopes added to an already-registered App stay inactive until every
installing account approves them. Until then such an App fails the
permission check and the calling skill aborts with its
missing-permissions report. `/gh-create-app`'s report tells an operator
reusing an older App to do both.

The plugin also gains a README.

## 0.11.4 — 2026-08-06

The PR-automation App's starter permission set gains `issues: write`.
GitHub closes linked issues under the merging token's authority, so an
App without the scope merged PRs and silently left their issues open.

`/gh-repo-setup-pr-automation` now aborts on an App provisioned before
this scope joined the set, rather than installing workflows that merge
but never close. The fix is two steps, both documented in the report:
edit the App's permissions in GitHub's UI, then have every installing
account approve the addition.

## 0.11.3 — 2026-07-21

The npm check in `dependency-pinned-gate` understands pnpm catalogs, so
catalog monorepos no longer fail on every consumer of a catalog entry.

- `catalog:` and `catalog:<name>` specs in a `package.json` are exempt,
  like `workspace:` and `file:`.
- Entries under `catalog:` and `catalogs:` in `pnpm-workspace.yaml` must
  be an exact `x.y.z`, and a violation is reported once, at its source.

## 0.11.2 — 2026-07-17

The npm lockfile check in `dependency-pinned-gate` is workspace-aware.
A member `package.json` may rely on a root lockfile when a pnpm, npm or
yarn workspace declaration covers its directory, so workspace monorepos
no longer fail `pinned-gate-required` permanently. A stray manifest no
workspace covers still fails.

## 0.11.1 — 2026-07-15

The rendered `auto-enable-automerge` workflow also runs on `synchronize`.
GitHub runs no `pull_request` workflow against a conflicting PR, so a PR
marked ready while conflicting never had auto-merge re-armed. The push
that resolves the conflict now re-arms it.

## 0.11.0 — 2026-07-14

`/gh-repo-setup-protection` arms the full supported set at install time,
and each member activates by itself the first time matching source
appears, with no re-run. Protection is no longer absent when a language
or ecosystem first lands, and an armed but empty leg no longer hangs.

- CodeQL and both dependency gates detect what is present at run time
  and run a leg only for that. A macOS runner is provisioned only when
  Swift is present.
- The required status checks are now the stable `codeql-required`,
  `install-gate-required` and `pinned-gate-required`, which also pass
  when nothing applies. Never require a per-leg name.
- Dependabot renders one block per supported ecosystem, and absent
  manifests are a no-op.
- The skill's language and ecosystem checklist now de-arms members,
  defaulting to everything armed.

## 0.10.1 — 2026-06-29

`/gh-repo-setup-protection` adds `dependency-pinned-gate`, which fails a
PR when a declared dependency is not pinned to an exact version, across
npm, pip, GitHub Actions, Docker and Go. It complements
`dependency-install-gate`, catching floating specs such as `^`, `>=`,
`@v4` and `:latest` that resolve differently over time. An npm manifest
that declares dependencies must also have a lockfile.

Some specs are exempt by category rather than by an allowlist file,
among them `peerDependencies` carets, `file:` and `workspace:` specs,
and Docker digests.

## 0.9.1 — 2026-06-27

`/gh-repo-setup-pr-automation` installs unattended Dependabot handling.

- A new merge job REST-merges a green Dependabot PR, resolving required
  checks from the live rulesets, rebasing a behind head in the workflow,
  and pinning the merge to a SHA so a moved head cannot merge unverified.
  It runs as workflows complete, with a daily backstop.
- The rebase sweep skips Dependabot PRs unless someone else has pushed
  to them. `/rebase` still acts on them.
- A new pass regenerates a desynced npm lockfile when the
  `dependency-install-gate` npm check is red, for any PR author, and
  force-pushes so the gate re-runs.

The merge job drops out with no required-check workflow, and the
lockfile pass with no install-gate workflow. Waiving review on
code-owned PRs also needs the App added as a ruleset bypass actor, which
this skill leaves to the operator.

## 0.8.5 — 2026-06-22

The plugin at the start of this history, provisioning a GitHub repo's
automation and posture:

- `/gh-create-app` registers the App identity the workflows use.
- `/gh-repo-setup-pr-automation` installs auto-merge and auto-rebase
  workflows.
- `/gh-repo-setup-protection` converges security settings, Dependabot,
  CodeQL, `dependency-install-gate` and a no-back-merging guard.
- `/repo-public-mirror-setup` creates a filtered read-only public mirror.
- `/gh-repo-scrub-history` rewrites history to purge a string.
- `/gh-repo-setup-public` promotes a private repo to public.
