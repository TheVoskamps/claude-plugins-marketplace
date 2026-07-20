---
name: aws-gh-acli-credential-read-surface
description: Which convention-based read-verb classifiers in permission-gate share the credential-leak class, and which don't — sweep reference for future default-deny work.
metadata:
  type: project
---

When sweeping the permission-gate's "convention-based read-verb allow"
classifiers for the credential-leak class (an allow floor reachable by a
credential-returning read), the three tools split like this:

- **aws** (`classifyAws`/`awsReadOnlyOp`/`awsCredentialRead`): DID leak.
  `get-*` reads return credential material for many services the exact-pair
  blacklist never covered (`eks get-token`, `redshift get-cluster-credentials`,
  `sso get-role-credentials`, `lightsail get-instance-access-details`, …).
  Fixed in #97 by a structural credential-material name-token signal scoped to
  the `get-` prefix. `list-*`/`describe-*` do NOT leak — they return
  collections/metadata (`iam list-access-keys`, `codecatalyst
  list-access-tokens` return identifiers, never the secret), verified against
  the CLI reference.
- **gh** (`isGhReadOnly`/`classifyGh`): does NOT leak. `gh auth token` prints
  the active token, but noun `auth` is absent from `knownNouns`, so it already
  falls to the #163 fail-closed ASK. Pinned by `TestGhAuthTokenFailsClosedToAsk_97`.
- **acli** (`classifyAcli`): does NOT leak. Its `get` read-verb matches
  Jira/Confluence/Bitbucket **entity** reads (issues, projects) — none returns
  credential material. acli's `auth` subcommand is login/logout/status/switch,
  none a `get` and none returning credentials. So there is no concrete leak to
  fix; `classifyAcli` was deliberately left unchanged in #97 (changing it would
  be gold-plating).

**Why:** #97 asked to sweep the class. The durable finding is which classifiers
actually share the leak (only aws did), so a future default-deny pass doesn't
re-investigate gh/acli from scratch.

**How to apply:** if a new tool classifier or a new acli/gh surface is added
that allows on a bare read-verb convention, re-check ONLY whether that tool has
a credential-returning read reachable by the convention — that is the trigger,
not the mere presence of a `get`/`view`/`list` verb. See
[[permission-gate-self-hosting]] for testing the rebuilt binary.
