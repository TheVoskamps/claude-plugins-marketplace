---
name: gh-pr-create-503-fall-back-to-rest
description: `gh pr create` is GraphQL-only and can 503 persistently while the REST API is healthy; open the draft PR with `gh api .../pulls -F draft=true -F body=@file` instead, after confirming via REST that no PR was created by the failed attempts.
metadata:
  type: project
---

`gh pr create` talks to `api.github.com/graphql` for both its
already-exists pre-check and the create mutation. In issue #108 it returned
`HTTP 503: No server is currently available to service your request` on five
consecutive attempts while `gh api repos/...` (REST) answered every time, and
`gh api graphql -f query='{viewer{login}}'` also answered -- so it is not an
auth problem, not a whole-API outage, and not something a different `gh` flag
fixes.

**Establish what actually happened before retrying.** The two failure spellings
tell you different things -- `error checking for existing pull request:` failed
in the pre-check and definitely created nothing, `pull request create failed:`
is ambiguous. Do not settle it with `gh pr list`, which is GraphQL and 503s
too. Use REST:

```bash
gh api "repos/<owner>/<repo>/pulls?head=<owner>:<branch>&state=all" --jq length
```

**Then create it over REST**, which is the same sanctioned operation in a
different spelling:

```bash
gh api repos/<owner>/<repo>/pulls -X POST \
  -f title="..." -f head=<branch> -f base=main \
  -F draft=true -F body=@<body-file> \
  --jq '"\(.number) draft=\(.draft) \(.html_url)"'
```

`-F draft=true` (not `-f`) is what sends a real JSON boolean; `-f` would send
the string `"true"`. `-F body=@<file>` reads the body from a file, which avoids
the multi-line-argument problem entirely -- the same reason commit messages go
through `git commit -F <file>` here (see
[[feedback_heredoc-commit-sandbox-gate]]).

Verify afterward rather than trusting the create's own output:
`gh api repos/<owner>/<repo>/pulls/<N> --jq '"draft=\(.draft) base=\(.base.ref)"'`
and grep the fetched body for the `Closes #<N>` line, since draft-ness and the
closing line are the two properties the whole PR contract rests on.
