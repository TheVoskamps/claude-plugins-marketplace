# Doc-updater memory index

- [github-setup docs locality](project_github-setup-docs-locality.md) —
  gh-repo-setup-protection behavior lives in its own SKILL.md; other
  docs reference it by name only and stay accurate across gate changes.
- [claude-vm two preflights](project_claude-vm-two-preflights.md) —
  launcher has a trust-path preflight AND a dependency preflight; docs
  must cover both, and list python3+gpg as required host tools.
- [sdlc agent baseline docs locality](project_sdlc-agent-baseline-docs-locality.md)
  — agent model tier, tools list, permissionMode support, and
  foreground enforcement documented only in orchestrate/SKILL.md +
  agent frontmatter; README/docs describe agents by roster only.
- [plugin docs locality](project_plugin-docs-locality.md) — new plugin:
  update root README roster; hook-EVENT facts go to
  docs/hook-event-notes.md, packaging-system facts to
  plugin-authoring-constraints.md; never touch plugin-migration-plan.md.
