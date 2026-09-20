# issues-jira

The Jira backend for the `issues` plugin: the contract the `issues:*`
verbs follow when a repo's tracker is Jira, reached through the
Atlassian CLI (`acli`) over a browser SSO session.

## Why

The `issues` plugin's verbs — create, view, update, link, and set
fields on an issue — are written against a tracker interface, and the
GitHub side of that interface ships with `issues` itself. A team whose
issues live in Jira wants the same verbs, with the same flags, and
without an Atlassian API token: some Atlassian sites no longer issue
one. This plugin supplies the Jira side, through `acli`'s web login,
which rides the SSO session already open in your browser. Install it
and the `issues` verbs work against Jira with nothing else to learn.

## Prerequisites

- **The `issues` plugin.** This plugin is a backend for it and declares
  it as a dependency; it does nothing on its own.
- **`acli`**, the Atlassian CLI, installed on the host and on `PATH`.
  The verbs detect its absence and stop; none installs it.
- **`acli jira auth login --web` completed.** The verbs check the
  session, and when it is missing or expired they run that login once
  and wait for you to finish the browser flow. They never read or
  script around the credential store.

## How to use

There is no command to run from this plugin. Its only skill,
`jira-lib`, is not user-invocable: it is reference material the
`issues` verbs consult. The entry point is the `issues:*` verbs.

The backend activates when `.issues/repo-config.md` carries
`issues: Jira`. That file is written by `/repo-config`, whose
interview asks which tracker the repo uses and, for Jira, discovers
the project's issue types, statuses and custom fields through `acli`
and records them:

```text
/issues:repo-config
```

Commit the file it writes. From then on the verbs address Jira work
items by key — a bare number is completed with the project's key
prefix from the config — and a typical run reads the same as it would
on GitHub:

```text
/issue-create --title "Cache resolved field IDs" --body-file body.md
              --type Bug --priority High --status Ready
/issue-set-parent PROJ-412 PROJ-380
/issue-view PROJ-412
```

## What it does not do

- It ships no user-invocable command and no executable code. It is
  the `acli` contract the `issues` verbs follow — the command
  templates, the auth expectation, and the rules for resolving a
  human-readable name to a Jira identifier — not a tool in its own
  right.
- It documents no per-verb behavior. What each verb does on Jira —
  its flags, defaults and echo format — is documented in
  `plugins/issues/README.md` and the verbs' own skill files.
- It offers no path around `acli`. A host without it, or a session
  the web login cannot establish, is reported rather than worked
  around: there is no fallback to the Jira REST API or to a
  token-based CLI.
