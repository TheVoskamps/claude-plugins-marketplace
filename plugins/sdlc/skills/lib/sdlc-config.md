# sdlc config contract (`skills/lib/sdlc-config.md`)

This file is the single statement of **where** sdlc's config files
live, **what** they hold, **how** the three of them resolve into one
value per key, and **how** a writer updates one. It is reference prose,
not an executable script.

No agent reads these files. The orchestrator resolves them once per
run, and a value a teammate needs travels in that teammate's brief.
The one exception is the `reload-after-compact` hook, which resolves
`reload-after-compact-token-budget` itself on every compaction, per
"Reading", because it runs outside any orchestrate run and has no brief
to receive a value. It checks only a file's read, its `schema-version`
and that key's value, reading `schema-version` off its own top-level
line, the key off the one line shape its description allows, and
ignoring every other line, so YAML malformed elsewhere in the file goes
unchecked. Where "Reading" aborts on one of those checks it uses the
key's default instead and names the path and the error in the text it
appends, so the compaction still completes.

## The tiers

| Tier | Path | Tracked |
| --- | --- | --- |
| 1. Global user | `${XDG_CONFIG_HOME:-$HOME/.config}/sdlc/user-config.yml` | no |
| 2. Shared repo | `<repo-root>/.sdlc/repo-config.yml` | yes |
| 3. Repo user | `<repo-root>/.sdlc/user-config.yml` | no (gitignored) |

`$XDG_CONFIG_HOME` is used when it is set and non-empty, `$HOME/.config`
when it is unset or empty. Resolve it by reading the environment
(`printenv XDG_CONFIG_HOME`, `printenv HOME`) and use the absolute path.
`<repo-root>` is what `git rev-parse --show-toplevel` prints.

Every key may be set at every tier. When a key is set in more than one
file, the highest-numbered tier wins; a key set in none takes its
default.

## The shape

Plain YAML, one document, no front-matter fences. `schema-version` is
the first key; every key is kebab-case.

```yaml
schema-version: 1
seed-review: auto-accept
merge-poll-interval-seconds: 300
```

## The keys

| Key | Values | Default |
| --- | --- | --- |
| `seed-review` | `ask` \| `auto-accept` | `ask` |
| `merge-wait` | `monitor` \| `skip` | `monitor` |
| `merge-poll-interval-seconds` | positive integer, at most `540` | `120` |
| `merge-max-unchanged-polls` | positive integer | `15` |
| `reload-after-compact-token-budget` | plain decimal integer, at least `64000` | `100000` |

- **`seed-review`** — `ask` stops for the human's ruling on the seed
  theorem list. `auto-accept` accepts every seed theorem as the
  generator emitted it and does not wait.
- **`merge-wait`** — `monitor` spawns `pr-monitor` after a PR's ready
  flip. `skip` spawns none; the PR is left ready and unmonitored.
- **`merge-poll-interval-seconds`** — the wait between two
  `pr-monitor` polls. `sdlc-pr-monitor` refuses a wait above `540`,
  so a higher value aborts at pre-flight instead.
- **`merge-max-unchanged-polls`** — how many consecutive polls with no
  change in state `pr-monitor` runs before it asks whether to keep
  waiting.
- **`reload-after-compact-token-budget`** — how many tokens, counted
  as characters ÷ 4, of skill and rule-file text the
  `reload-after-compact` hook appends to a compacted conversation.
  The files past it are listed by path, to be read before acting on
  them. The floor of `64000` holds an orchestrate run's whole working
  set past its opening, about 42k tokens, with headroom for the files
  the run's own work reads. The value is valid only on a line that
  starts at column 0 with `reload-after-compact-token-budget:`, then
  whitespace, then a decimal integer of at least `64000` with no sign,
  leading zero, underscore or quote, then at most whitespace and a `#`
  comment. Any other value, a smaller number included, and any
  other line that writes the key — quoted, indented, in a flow mapping,
  with its value on the next line, or a second time — is outside its
  allowed values. A line whose first non-blank character is `#` is a
  comment and sets nothing.

## Reading

The pin is **`schema-version: 1`**. Read tier 1, then tier 2, then
tier 3, each with the `Read` tool, and handle every file by the first
of these that applies:

- **The read ran and reported that the file does not exist** — the
  tier contributes no keys.
- **The read did not run, or failed for any other reason**, whatever
  refused it — abort, naming the path and quoting the error. A refused
  read says nothing about whether the file exists, so it is never
  treated as a missing one.
- **The YAML is malformed, or `schema-version` is absent** — abort,
  naming the path.
- **`schema-version` is lower than the pin** — abort, naming the path
  and both versions.
- **A key from the table above holds a value outside its allowed
  values** — abort, naming the path and the key. A positive integer is
  a YAML integer of 1 or more; `0`, a negative, a float and a quoted
  string are all outside it, and so is an integer above the key's
  stated maximum. A key whose description states a narrower shape
  takes only that shape.
- **Otherwise** — the tier contributes every key from the table above
  that it sets. A key the table does not list is ignored, and so is a
  `schema-version` above the pin.

Validate every file before resolving any key, so a bad value at a tier
that a higher tier overrides still aborts. Then resolve each key per
"The tiers", recording the tier its value came from — `global user`,
`shared repo`, `repo user`, or `default`.

## Writing

Each writer owns one tier's file and runs these steps against it.

1. **Resolve the lower tiers.** Read every tier below the writer's own
   per "Reading", with the same aborts, and resolve each key over those
   tiers and the defaults alone. Tier 1 has no lower tier, so its
   writer resolves to the defaults.
2. **Read the writer's own file.** Absent, it will be created. Present,
   read it with the same aborts as "Reading", except that a
   `schema-version` below the pin is re-stamped to the pin rather than
   aborted on. Keep every key in it, the ones the table does not list
   included.
3. **Ask, one key at a time**, in table order. Before each question,
   show the value the lower tiers resolve to and the tier it comes
   from, and the value the writer's own file sets now, if any. Offer
   every allowed value and **leave unchanged**. A positive-integer key
   takes a typed value, re-asked until it is within the key's allowed
   values.
4. **Merge.** Replace only the keys answered with a value this run.
   A key left unchanged keeps its current value, or stays absent if it
   was absent — the writer never writes a key the user left unset, and
   never deletes one. Set `schema-version: 1` as the first key; keep
   every other key in its existing order and append new keys after
   them.
5. **Show the merged file and wait for a yes** that names the write.
   Then write it whole with the `Write` tool, which creates a missing
   parent directory.
6. **Report** the path written, the keys changed, and the keys kept.

A writer commits nothing and pushes nothing. A tracked file it writes
is the user's to commit.
