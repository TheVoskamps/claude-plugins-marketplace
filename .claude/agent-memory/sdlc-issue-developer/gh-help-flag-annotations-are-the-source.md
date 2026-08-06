---
name: gh-help-flag-annotations-are-the-source
description: gh's own --help output annotates each flag's VALUE TYPE (file/string/name/branch/login), which is the authoritative way to decide whether a gh flag names a local path — but two flags need a closer read than the annotation, and help is not the whole accepted grammar (pflag adds `-h` and `-F=FILE`).
metadata:
  type: reference
---

`gh <noun> <verb> --help` prints a FLAGS block whose every value-taking
entry carries a value-TYPE word: `-F, --body-file file`,
`-t, --title string`, `-a, --assignee login`, `-B, --base branch`,
`-T, --template name`. When you need to know whether a gh flag names a
local file, that annotation is the source — not memory, and not the
prose description.

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
flag grammar. Two exceptions the annotation alone gets wrong, both
found in #229:

- `--recover` on `pr create` / `issue create` is annotated `string` but
  IS a file path — gh calls `shared.FillFromJSON(opts.IO,
  opts.RecoverFile, state)` on it. Verified against
  `cli/cli` `pkg/cmd/pr/create/create.go`, not inferred.
- `--template` differs BY VERB: `gh pr create -T` is annotated `file`,
  `gh issue create -T` is annotated `name` (resolved server-side). A
  union flag table across verbs would flatten that distinction, which is
  why `ghFileSpecs` is keyed by noun AND verb.

`gh gist edit`'s help EXAMPLES block is what settles its two
filename-ish flags: `--filename` selects a file inside the gist,
`--add` names a LOCAL file. The FLAGS block alone ("Select a file to
edit" / "Add a new file to the gist") does not distinguish them.

The annotation is the source for a flag's TYPE; it is not the whole
accepted grammar, and #232's review round found the gap. gh parses with
cobra/pflag, and pflag accepts two spellings help never prints: `-h`
(unregistered `h` → `f.usage()` + `ErrHelp`, so it works on every verb
though only `--help` is rendered) and `-F=FILE`, where pflag strips the
`=` (`len(shorthands) > 2 && shorthands[1] == '='`) and getopt does not
— so a getopt-shaped walk reads `-F=/etc/passwd` as the in-repo
`=/etc/passwd`. Its bool sibling `-p=f` is `--public=false` and ENDS the
token. Model those by hand; no re-reading of `--help` will surface them.
