# Doc-updater memory index

- [Read the worktree, not the primary clone](feedback_read-the-worktree-not-the-primary-clone.md)
  — build paths from `git rev-parse --show-toplevel`; a primary-clone Read
  silently returns pre-PR prose. Tell: grep -n and Read disagree on line numbers.

- [Branch claimed by a manual-test worktree](feedback_branch-claimed-by-a-manual-test-worktree.md)
  — checkout fails naming Edwin's live test worktree: detach at
  `origin/<branch>`, push `HEAD:<branch>`, skip the branch -D. Never remove it.

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
  N-before-list defects when sweeping that README. A TIER change
  falsifies worked examples in paragraphs about OTHER mechanisms that
  borrowed the verb; slurp comment BLOCKS, and replay every quoted
  example through the binary.
- [gh pr diff and active gate](feedback_gh-pr-diff-and-active-gate.md)
  — `gh pr diff` can silently drop text files from a PR with binary
  commits (cross-check with `git diff --stat`); the active
  permission-gate blocks heredoc `git commit -m`, use `commit -F`.
- [issue-ref sweep artifacts](project_issue-ref-sweep-artifacts.md) —
  a mechanical `#N`-removal sweep breaks grammar ACROSS comment line
  wraps (line greps miss it) and turns refs into unnamed "this issue"
  pointers; join comment blocks and read the old→new diff pairs.
- [known gaps are a doc surface](project_issue-known-gaps-are-a-doc-surface.md)
  — an issue's "Known gaps left in place" section is the part the
  developer reliably never carries into the README; check it every run.
- [checkout-contract doc surfaces](project_checkout-contract-doc-surfaces.md)
  — attached→detached checkout changes break orchestrate's "Both run in
  fresh worktrees" paragraph and sibling agents' cleanup examples.
- [no blanket predicate over a list](feedback_no-blanket-predicate-over-a-list.md)
  — `<these files> all <predicate>` is one claim per file; open each
  before writing it, and treat a shared predicate as weak warrant when
  reading one.
- [widened enumeration, trailing clause](feedback_widened-enumeration-trailing-clause.md)
  — widening a list leaves the "only/except" clause after it scoped to the
  old narrow set; vfkit is installed here, so parse claims are one probe away.
- [claude-vm config-redesign stale-comment classes](project_claude-vm-config-redesign-stale-comment-classes.md)
  — after a claude-vm config-model redesign, grep for the OLD filename
  and OLD deleted function names plugin-wide; a thorough README pass
  still misses file headers, user-facing error messages, and
  security-provenance comments elsewhere in the same/sibling files; also
  covers helper headers that name a downstream consumer that never calls
  them — grep for the helper name; and gate prose that names the state a
  gate approximates rather than the one it tests (the claude-vm
  declaration-vs-image-state seam itself is in the root CLAUDE.md).
- [skill-extraction doc surfaces](project_skill-extraction-doc-surfaces.md)
  — a round that extracts duplicated cross-plugin behavior into a new
  skill misses docs/plugin-authoring-constraints.md's pattern list and
  the consumer README's new `dependencies` edge; no CLAUDE.md sweep
  section.
- [agent-variant doc surfaces](project_agent-variant-doc-surfaces.md)
  — adding an sdlc agent variant / preloaded-instruction skill leaves
  docs/plugin-authoring-constraints.md's pattern list and fresh count
  words unswept.
- [agent-retirement doc surfaces](project_agent-retirement-doc-surfaces.md)
  — retiring an agent leaves issues/lib repo-config's per-field consumer
  claims and "previously performed / mirrors what" history sentences false;
  no sdlc file pins schema-version, whatever that lib says.
- [Qualifier that contradicts the next paragraph](feedback_qualifier-that-contradicts-the-next-paragraph.md)
  — a first exception gets patched with a vague hedge ("every teammate
  you spawn by name") that still includes the exception; read the
  statement together with the paragraph after it.
- [diagnostic detail claims](feedback_diagnostic-detail-claims.md) —
  "aborts with the path named" is a claim per BRANCH of the validator;
  read the message strings, then sweep — that sentence is always copied
  to several doc surfaces.
- [Widened guard, narrow prose](feedback_widened-guard-narrow-prose.md)
  — after equality is widened to a relation (overlap/ancestor/range),
  the rationale comment on each protected VALUE still spells the narrow
  case; grep the old vocabulary, not the guard.
- [Probe the gate binary, not the walk](feedback_probe-the-gate-binary-not-the-walk.md)
  — settle a gate reach-claim ("descends into every X") with a throwaway
  _test.go calling classifyBash; the helper is right, its call sites are
  the scope. Never prescribe a spelling you have not run.
- [Gate Go comment edits need a binary rebuild](project_permgate-go-comment-edits-need-binary-rebuild.md)
  — Go embeds file:line, so a comment-only edit under
  hooks/permission-gate/ invalidates all three committed binaries;
  gofmt, rebuild, stage them in the doc commit.
- [Bash probes race on process substitution](feedback_bash-probe-procsubst-race.md)
  — a `<(cmd)` child is async: sleep before checking the marker or a
  shape bash DOES run reads as "did not run"; run probes from a
  scratchpad script, on both /bin/bash 3.2 and homebrew bash 5.
- [Sourcing order decides who wins](feedback_sourcing-order-decides-who-wins.md)
  — "the launcher's value always wins" is a claim about read order, not
  ownership; compare line numbers in the consumer. Restated on 7 surfaces
  in claude-vm and backwards on all of them.
- [claude-vm bash-3.2 rule surface pair](project_claude-vm-bash32-rule-surface-pair.md)
  — that rule lives on exactly two surfaces (root CLAUDE.md + payload
  README's oldest-bash section); check scope, severity clause and
  pinning on both, and never cite a bullet by list position.
- [The PR description is a doc surface](feedback_pr-description-is-a-doc-surface.md)
  — when the spawn prompt says so, verify and repair the PR body like a
  README; the closing keyword is untouchable and nothing else on the PR
  is yours.
- [Measure the declared-safe counter-case](feedback_measure-the-declared-safe-counter-case.md)
  — a fix's prose exempts a sibling gate ("sits inside a list element,
  no prune reaches it"); the round measured only what it changed. Read
  the recursive operator's expression, then probe the sibling.
