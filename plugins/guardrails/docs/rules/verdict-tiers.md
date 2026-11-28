# Verdict tiers

**Who reads this and when:** any agent adding a permission-gate verdict,
moving a call between verdicts, or reviewing a PR that does.

The gate buckets a call by what it settles better than the downstream
auto mode evaluator, an LLM judge reading the call in context, and never
by how confident it is. A gate ask is a hard prompt that bypasses that
judge, so spending one on uncertainty buys prompt fatigue, not safety.
Membership in each tier follows from that.

## Deny, with teaching

A known-bad call for which a prescriptive redirect exists. The reason
is fed back to the model, which corrects itself on its next call, so
the reason names what to do instead.

- The redirect must be **total**. A deny that leaves some legitimate use
  with nowhere to go is a dead end, and that call defers instead.
- A shape with no legitimate use at all (`gh api --hostname`,
  `aws --endpoint-url`, `gh auth switch`) strands nothing, so it denies;
  its reason says to drop the shape and stay on the sanctioned one.
- An inline environment assignment on a `git`, `gh` or `aws` command
  denies, whatever the variable and whatever the subcommand, written as
  a prefix (`FOO=bar git status`) or through `env`
  (`env FOO=bar git status`); its reason says to drop the assignment.
  It is keyed on the program, not the variable: on any other program
  the assignment alone does not deny, and `FOO=bar ls` allows.
- Totality is graded per input, not per element. A redirectable GraphQL
  mutation denies when it is the document's only mutation, or is bundled
  only with allow-listed ones. A document bundling it with one the gate
  can only refuse defers, in either field order, because the deny would
  teach about one field and leave the other with nowhere to go.

## Allow, with positive grounds

Proven read-only operations and contained writes, held to the bar
`BucketAllow` states in `decision.go`. This tier keeps the hot path off
the evaluator entirely.

## Hard ask

A short, enumerated tier of calls where policy demands a human decision
however good the judge is, which an LLM must not be able to waive. A
member asks only when no check that runs ahead of the tier settles the
call first: an argv that is not all static literals, or an inline
environment assignment, denies any of them, as does each case an entry
below names. The whole tier:

- **Publish verbs:** `gh release create`, `gh gist create` and
  `gh gist edit` in every spelling, and `gh repo edit --visibility`. A
  local file one of the first three would publish denies when it
  resolves outside containment, and a flag on them the gate does not
  model defers.
- **History-destroying pushes:** `git push` with `--force` or `-f` as
  an argument of its own, or with a `+<src>:<dst>` refspec, unless
  `--force-with-lease` or `--force-if-includes` is also given. A
  colon-less `+<ref>` and a `-f` combined with other short flags, as in
  `-fu`, allow; `--mirror` and `--prune` deny.
- **Credential reads and mints:** the `aws` operations
  `awsCredentialRead` and `awsCredentialMint` in `rules.go` match,
  `gh auth token`, `gh auth status -t`/`--show-token` and its
  unknown-flag screen, and `gh auth login` with `--hostname` or `-h` as
  an argument of its own, or with `--hostname=<host>`.

Ask rather than deny where a human has legitimate reasons to proceed:
the gate governs interactive sessions as well as agent ones, and one
click preserves those where a deny does not.

That a hook ask outranks a downstream `settings.json` allow or auto mode
judgment is the design intent of this tier, and no test measures it.
Never cite it as established. An enumerated policy call belongs here
whether or not the precedence holds, since a defer is waivable either
way; a measurement showing a downstream allow winning calls for a
different mechanism, not a reworded tier.

## Defer

The judgment middle, and everything else: every arm where the gate
cannot statically classify the call, the generic remote mutations, and
the context-dependent operations. A site with an account to give uses
`deferJudgment`, so the evolution log records it.

A broad static allow rule in `settings.json`, such as `Bash(<prog>:*)`,
matches before auto mode sees a deferred call of that program. The fix
for such a rule is tightening it; a gate ask in its place only buys the
prompt back.
