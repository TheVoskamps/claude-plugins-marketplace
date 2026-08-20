# github-setup

Skills that provision a GitHub repo's automation and posture:
`/gh-create-app` registers the org- or enterprise-scoped App the
workflows authenticate as, `/gh-repo-setup-pr-automation` installs the
auto-merge / auto-rebase workflows that run under it,
`/gh-repo-setup-protection` converges the security and merge-button
surface, `/repo-public-mirror-setup` stands up a filtered read-only
mirror, `/gh-repo-scrub-history` rewrites history to purge a leaked
string, and `/gh-repo-setup-public` promotes a private repo to public.
`skills/lib/gh-app.md` is the shared find/verify library every
App-consuming skill calls rather than re-implementing.

## Sweep every App-permission surface when the starter set changes

The PR-automation GitHub App's permission set is restated as a literal
list in several places here, each a separate edit:

- `skills/gh-create-app/SKILL.md` — the *Starter permission set* table,
  the per-scope rationale paragraphs between it and the
  `required_permissions` code block, that code block, the "Permissions →
  Repository permissions" bullets the user is told to click through
  during registration, the scopes named as the worked example in the
  App-resolution step's missing-permissions branch, the
  `__APP_PERMISSIONS__` rendering example in the metadata-doc step, and
  the reused-App upgrade note in the final report.
- `skills/gh-repo-setup-pr-automation/SKILL.md` — the *Required GitHub
  App permissions* block, the per-scope prose under it saying what each
  scope covers, and the `required_permissions = { … }` line in its
  App-resolution step.
- `skills/lib/gh-app.md` — the `required_permissions` example in the
  caller-passes list, and the paragraphs under it that name a scope
  callers forget.

`payload/gh-create-app/app-metadata.md` renders the set from
`__APP_PERMISSIONS__` and holds no literal list, so it never takes this
edit — hard-coding a map there would freeze one caller's scopes into
every rendered metadata doc.
`plugins/github-claude-identity/skills/gh-create-identity-app/SKILL.md`
does carry a literal permission list, but it belongs to a **different**
App (the per-user commit identity, provisioned with its own scopes).
Never sweep it along with this set.

Widening the set has a converge-time consequence worth stating wherever
the new scope is introduced: a scope added to an already-registered App
is not live until every installing account approves it
(`skills/lib/gh-app.md` → "Granting a missing permission to an existing
App"), so every previously-provisioned App fails the library's
permission filter until that approval lands.

That failure is determinate in every caller: the library aborts the
calling skill with its "missing permissions" report and the pointer to
the two-step remediation — on the discovery path from Step 3's
no-suitable-candidates branch, on the `--app-name` path from that
path's own permission check. No caller routes such an App into
registration instead.
