# Doc-updater memory index

- [github-setup docs locality](project_github-setup-docs-locality.md) —
  gh-repo-setup-protection behavior lives in its own SKILL.md; other
  docs reference it by name only and stay accurate across gate changes.
  SKILL.md's own exemption-family prose repeats 3x and isn't always
  pre-updated by the developer (#177 counterexample).
- [plugin docs locality](project_plugin-docs-locality.md) — new plugin:
  update root README roster; hook-EVENT facts go to
  docs/hook-event-notes.md, packaging-system facts to
  plugin-authoring-constraints.md; never touch plugin-migration-plan.md.
- [guardrails package comment sweep](project_guardrails-package-comment-sweep.md)
  — permission-gate duplicates containment-behavior doc comments per
  entry point; grep the whole directory after a containment-rule
  change, don't trust the developer's call-site edit alone.
- [guardrails permgate docs locality](project_guardrails-permgate-docs-locality.md)
  — permission-gate classifier behavior lives in its own README.md +
  Go doc comments, kept current by developer/fixer, usually already
  current by the time doc-updater runs; watch for recurring
  N-before-list defects when sweeping that README.
- [gh pr diff and active gate](feedback_gh-pr-diff-and-active-gate.md)
  — `gh pr diff` can silently drop text files from a PR with binary
  commits (cross-check with `git diff --stat`); the active
  permission-gate blocks heredoc `git commit -m`, use `commit -F`.
- [claude-vm config-wizard skills lag](project_claude-vm-config-wizard-skills-lag.md)
  — claude-vm feature work leaves the two config-WIZARD SKILL.md files stale;
  a wrong bake/boot placement there makes the wizard write a config that
  cannot launch; also check payload/README.md's helper-function list.
- [issue-ref sweep artifacts](project_issue-ref-sweep-artifacts.md) —
  a mechanical `#N`-removal sweep breaks grammar ACROSS comment line
  wraps (line greps miss it) and turns refs into unnamed "this issue"
  pointers; join comment blocks and read the old→new diff pairs.
- [known gaps are a doc surface](project_issue-known-gaps-are-a-doc-surface.md)
  — an issue's "Known gaps left in place" section is the part the
  developer reliably never carries into the README; check it every run.
- [no blanket predicate over a list](feedback_no-blanket-predicate-over-a-list.md)
  — `<these files> all <predicate>` is one claim per file; open each
  before writing it, and treat a shared predicate as weak warrant when
  reading one.
- [claude-vm config-redesign stale-comment classes](project_claude-vm-config-redesign-stale-comment-classes.md)
  — after a claude-vm config-model redesign, grep for the OLD filename
  and OLD deleted function names plugin-wide; a thorough README pass
  still misses file headers, user-facing error messages, and
  security-provenance comments elsewhere in the same/sibling files.
- [skill-extraction doc surfaces](project_skill-extraction-doc-surfaces.md)
  — a round that extracts duplicated cross-plugin behavior into a new
  skill misses docs/plugin-authoring-constraints.md's pattern list and
  the consumer README's new `dependencies` edge; no CLAUDE.md sweep
  section.
