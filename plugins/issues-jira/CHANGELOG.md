# issues-jira changelog

## 0.3.1 — 2026-09-27

The plugin no longer declares a dependency on `issues`, because it
invokes nothing and the invocation runs the other way. It still does
nothing on its own, so install both.

## 0.3.0 — 2026-09-19

Adds a README for anyone deciding whether to install the plugin: what it
is for, what it needs, and that the `issues:*` verbs are its entry point.
Behavior is unchanged.

## 0.2.0 — 2026-08-24

The Jira reference now names `.issues/repo-config.md`, following the
`issues` plugin's move of its config out of `.claude/rules/`.

## 0.1.1 — 2026-07-30

Wording change: the reference describes the multi-issue orchestrator
instead of naming a command outside its scope. Behavior is unchanged.

## 0.1.0 — 2026-06-22

The Jira backend for the `issues` plugin, reached through the Atlassian
CLI (`acli`) over a browser SSO session rather than an API token.

- A non-invocable `jira-lib` reference holds the `acli` command templates
  that the `issues` verbs and `/repo-config` follow.
- It covers `acli jira auth login --web`, discovery of projects, issue
  types, statuses and custom fields, and writes for work items, comments
  and links.
- A missing `acli` or a session the login cannot establish is reported.
  There is no fallback to the REST API or a token-based CLI.
- A value not among a slot's configured options aborts with the valid
  list rather than falling back to a default.
- Declares the `issues` plugin as a dependency.
