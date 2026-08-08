---
name: gh-help-flag-annotations-are-the-source
description: gh's own --help output annotates each flag's VALUE TYPE (file/string/name/branch/login), which is the authoritative way to decide whether a gh flag names a local path — but `--recover`, `gist edit --add` and the per-verb `--template` need a closer read than the annotation, and help is not the whole accepted grammar (pflag adds `-h` and `-F=FILE`).
metadata:
  type: reference
---

`gh <noun> <verb> --help` prints a FLAGS block whose every value-taking
entry carries a value-TYPE word: `-F, --body-file file`,
`-t, --title string`, `-a, --assignee login`, `-B, --base branch`,
`-T, --template name`. When you need to know whether a gh flag names a
local file, that annotation is the source — not memory, and not the
prose description.

**Not on a publishing verb.** The root `CLAUDE.md` forbids invoking
`gist create`/`gist edit`/`release create`/`release upload`/`pr
create`/`issue create`/`pr comment`/`issue comment` in any spelling,
`--help` included. For those verbs read the command's own registration
block instead — `gh api "repos/cli/cli/contents/<path>?ref=<tag>" --jq
.content | base64 -d` — which gives the complete flag set and is the
parser's own input, so it is better evidence than help anyway.

Machine-extract it rather than eyeballing; a script per invocation
avoids the gate's multi-construct-one-liner DENY (see
[[permission-gate-self-hosting]]):

```bash
gh $c --help 2>&1 | awk '/^FLAGS$/{f=1;next} /^INHERITED FLAGS$/{f=0} f'
```

`awk '/^USAGE$/{getline; print; exit}'` gets the positional grammar the
same way, which is what tells you `gh gist create [<filename>...]` names
files from index 0 while `gh release create [<tag>] [<filename>...]`
names them from index 1.

**Why:** guessing a gh flag's arity or value type desyncs any walk over
its argv, and guessing which flags exist at all produces a whitelist
that spuriously escalates routine commands. gh 2.97.0 was the version
audited for #229.

**How to apply:** whenever gate work (or any argv parser) needs gh's
flag grammar. Two things the extraction alone will not give you, both
already written down in `classify_gh_files.go` — read the annotation
notes on `ghFileSpecs` rather than re-deriving them:

- The annotation understates the file gh really opens for a few flags,
  and `--template` differs BY VERB, which is why the spec table is
  keyed by noun AND verb rather than unioned. Settle such a case
  against `cli/cli`'s own source (`gh api
  "repos/cli/cli/contents/<path>?ref=v<VER>"`) or the verb's EXAMPLES
  block, never by inference from the FLAGS description.
- The annotation is the source for a flag's TYPE; it is not the whole
  accepted grammar. gh parses with cobra/pflag, and pflag accepts
  spellings help never prints (`-h` on every verb, and `-F=FILE`, where
  pflag strips the `=` and getopt does not). Model those by hand; no
  re-reading of `--help` will surface them, and the containment
  consequence is in the gate's own comments and tests.
