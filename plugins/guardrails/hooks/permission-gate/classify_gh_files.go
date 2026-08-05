package main

import (
	"fmt"
	"strings"
)

// Read containment for the LOCAL FILES a `gh` command publishes to GitHub
// (issue #229).
//
// `gh`'s body-file flags read a file off the local disk and send its contents to
// GitHub, where the destination may be public and outlives any local cleanup.
// The gate already holds the verdict that says whether a path may be read — the
// same Engine B containment that answers `cat /etc/passwd` with a cross-repo
// deny — but classifyGh never asked for it: the operand was consumed as an
// ordinary flag value and never reached containment, so
// `gh pr comment 227 -F /etc/passwd` published the file under an outright ALLOW.
//
// This is the converse of issue #225's class 1. There a LOCAL redirect
// (`gh pr diff > .claude/tmp/x`) exfiltrates nothing, because the bytes stay in
// a worktree the agent can already read and write. Here the bytes genuinely
// leave, so the read source is graded exactly as the read tracks grade theirs.
//
// The mechanism is reused rather than rebuilt: pathFlagValues (readonly_util.go)
// extracts a flag's value in all four spellings — a separate token
// (`-F FILE`), a glued short form (`-FFILE`), an `=`-joined long form
// (`--body-file=FILE`), and the value-taking tail of a short cluster — and
// containReadSources (classify_files.go) runs the results through the read
// containment, forwarding an escape and discarding the ALLOW (a contained body
// file is no grounds to bless the publish itself; the verb's own tier decides
// that).
//
// Two properties carried over from #225:
//
//   - APPENDED, never substituted. The flag values are added to the verb's
//     positional file operands, so the flag model can only ever put MORE paths
//     through containment and can never swallow a genuine operand out of the
//     walk.
//   - FAIL SAFE on an unmodelled flag. Each spec enumerates its verb's COMPLETE
//     flag set, and an unrecognized flag escalates rather than riding the verb's
//     allow — the same whitelist shape ghAuthStatusEscalates holds for
//     `gh auth status`. A future gh release that adds another file-reading flag
//     therefore costs one human click, not a silent publish.

// ghFileSpec models one gh noun/verb for the purpose of grading the local files
// it reads and publishes.
//
// valueFlags and boolFlags together are the verb's COMPLETE flag grammar, taken
// from `gh <noun> <verb> --help` (gh 2.97.0); a flag in neither is unrecognized
// and escalates. pathValueFlags is the subset of valueFlags whose value names a
// LOCAL file — gh's own help annotates a flag's value type, and the `file`
// annotation is what puts a flag in this set.
//
// filePositionalsFrom is the index, among the verb's positional operands, of the
// first one that names a local file; -1 when the verb takes none. It exists
// because two publish verbs take their files positionally rather than by flag:
// `gh gist create <filename>...` names them from index 0, while
// `gh release create <tag> [<filename>...]`, `gh release upload <tag> <files>...`
// and `gh gist edit {<id>|<url>} [<filename>]` reserve the first positional for
// a tag / gist id and name files from index 1.
type ghFileSpec struct {
	valueFlags          map[string]bool
	boolFlags           map[string]bool
	pathValueFlags      map[string]bool
	filePositionalsFrom int
}

// ghInheritedValueFlags and ghInheritedBoolFlags are gh's per-command inherited
// flags (`gh <noun> <verb> --help` → INHERITED FLAGS). `-R`/`--repo` is accepted
// AFTER the noun as well as before it — ghExplicitRepoTarget already scans the
// command path for exactly that spelling — so every spec must recognize it or
// the routine `gh issue comment -R owner/repo N -F body.md` would escalate on a
// flag gh documents. They are merged into each spec by ghSpec rather than
// repeated in 26 literals.
var ghInheritedValueFlags = map[string]bool{"-R": true, "--repo": true}

var ghInheritedBoolFlags = map[string]bool{"--help": true}

// ghSpec builds a ghFileSpec, folding gh's inherited flags into the verb's own
// sets. pathValueFlags must be a subset of the verb's valueFlags; that is
// asserted by TestGhFileSpecsAreWellFormed rather than at run time.
func ghSpec(valueFlags, boolFlags, pathValueFlags map[string]bool, filePositionalsFrom int) ghFileSpec {
	merged := make(map[string]bool, len(valueFlags)+len(ghInheritedValueFlags))
	for f := range valueFlags {
		merged[f] = true
	}
	for f := range ghInheritedValueFlags {
		merged[f] = true
	}
	bools := make(map[string]bool, len(boolFlags)+len(ghInheritedBoolFlags))
	for f := range boolFlags {
		bools[f] = true
	}
	for f := range ghInheritedBoolFlags {
		bools[f] = true
	}
	return ghFileSpec{
		valueFlags:          merged,
		boolFlags:           bools,
		pathValueFlags:      pathValueFlags,
		filePositionalsFrom: filePositionalsFrom,
	}
}

// ghBodyFileFlags is the `-F`/`--body-file` pair shared by every pr/issue verb
// that accepts a body: gh spells the flag identically across all of them.
var ghBodyFileFlags = map[string]bool{"-F": true, "--body-file": true}

// ghNotesFileFlags is the release-verb spelling of the same idea
// (`-F`/`--notes-file`).
var ghNotesFileFlags = map[string]bool{"-F": true, "--notes-file": true}

// ghFileSpecs is the grading table, keyed by noun then verb. Its membership is
// the set of gh commands that PUBLISH content: every verb ghRecoverableWriteVerbs
// maps true (the enumerated recoverable writes, which reach an outright ALLOW),
// plus `release create` and `gist create`, which reach the publish ASK tier
// above isGhRecoverableWrite and would otherwise escalate on the verb while
// never grading the path.
//
// Read verbs are deliberately absent. A read sends nothing of the local disk to
// GitHub, so it has no publish surface to grade, and its output-redirect surface
// is already graded by credentialedRedirectAsk.
//
// Flag sets transcribed from `gh <noun> <verb> --help` (gh 2.97.0). A flag gh
// annotates `file` is a pathValueFlag; one it annotates `string`, `text`,
// `name`, `title`, `login`, `handle`, `branch`, `number` or `numbers` is not.
// Two annotations needed a closer read than the type alone:
//
//   - `--recover` (pr create, issue create) is annotated `string` but names a
//     JSON file gh reads to prefill the title and body it then publishes. It is
//     a path.
//   - `--template` differs BY VERB, which is the whole reason this table is
//     per-verb rather than one union: `gh pr create -T` is annotated `file`
//     (a template file path) and is graded, while `gh issue create -T` is
//     annotated `name` (an issue-template name resolved server-side) and is not.
var ghFileSpecs = map[string]map[string]ghFileSpec{
	"pr": {
		"create": ghSpec(
			map[string]bool{
				"-a": true, "--assignee": true, "-B": true, "--base": true,
				"-b": true, "--body": true, "-F": true, "--body-file": true,
				"-H": true, "--head": true, "-l": true, "--label": true,
				"-m": true, "--milestone": true, "-p": true, "--project": true,
				"--recover": true, "-r": true, "--reviewer": true,
				"-T": true, "--template": true, "-t": true, "--title": true,
			},
			map[string]bool{
				"-d": true, "--draft": true, "--dry-run": true, "-e": true, "--editor": true,
				"-f": true, "--fill": true, "--fill-first": true, "--fill-verbose": true,
				"--no-maintainer-edit": true, "-w": true, "--web": true,
			},
			map[string]bool{
				"-F": true, "--body-file": true,
				"-T": true, "--template": true,
				"--recover": true,
			}, -1),
		"comment": ghSpec(
			map[string]bool{"-b": true, "--body": true, "-F": true, "--body-file": true},
			map[string]bool{
				"--create-if-none": true, "--delete-last": true, "--edit-last": true,
				"-e": true, "--editor": true, "-w": true, "--web": true, "--yes": true,
			},
			ghBodyFileFlags, -1),
		"edit": ghSpec(
			map[string]bool{
				"--add-assignee": true, "--add-label": true, "--add-project": true,
				"--add-reviewer": true, "-B": true, "--base": true,
				"-b": true, "--body": true, "-F": true, "--body-file": true,
				"-m": true, "--milestone": true, "--remove-assignee": true,
				"--remove-label": true, "--remove-project": true, "--remove-reviewer": true,
				"-t": true, "--title": true,
			},
			map[string]bool{"--remove-milestone": true},
			ghBodyFileFlags, -1),
		"merge": ghSpec(
			map[string]bool{
				"-A": true, "--author-email": true, "-b": true, "--body": true,
				"-F": true, "--body-file": true, "--match-head-commit": true,
				"-t": true, "--subject": true,
			},
			map[string]bool{
				"--admin": true, "--auto": true, "-d": true, "--delete-branch": true,
				"--disable-auto": true, "-m": true, "--merge": true,
				"-r": true, "--rebase": true, "-s": true, "--squash": true,
			},
			ghBodyFileFlags, -1),
		"close": ghSpec(
			map[string]bool{"-c": true, "--comment": true},
			map[string]bool{"-d": true, "--delete-branch": true},
			nil, -1),
		"ready": ghSpec(
			nil,
			map[string]bool{"--undo": true},
			nil, -1),
		"reopen": ghSpec(
			map[string]bool{"-c": true, "--comment": true},
			nil,
			nil, -1),
		"review": ghSpec(
			map[string]bool{"-b": true, "--body": true, "-F": true, "--body-file": true},
			map[string]bool{
				"-a": true, "--approve": true, "-c": true, "--comment": true,
				"-r": true, "--request-changes": true,
			},
			ghBodyFileFlags, -1),
	},
	"issue": {
		"create": ghSpec(
			map[string]bool{
				"-a": true, "--assignee": true, "--blocked-by": true, "--blocking": true,
				"-b": true, "--body": true, "-F": true, "--body-file": true,
				"-l": true, "--label": true, "-m": true, "--milestone": true,
				"--parent": true, "-p": true, "--project": true, "--recover": true,
				"-T": true, "--template": true, "-t": true, "--title": true, "--type": true,
			},
			map[string]bool{"-e": true, "--editor": true, "-w": true, "--web": true},
			map[string]bool{"-F": true, "--body-file": true, "--recover": true}, -1),
		"comment": ghSpec(
			map[string]bool{"-b": true, "--body": true, "-F": true, "--body-file": true},
			map[string]bool{
				"--create-if-none": true, "--delete-last": true, "--edit-last": true,
				"-e": true, "--editor": true, "-w": true, "--web": true, "--yes": true,
			},
			ghBodyFileFlags, -1),
		"edit": ghSpec(
			map[string]bool{
				"--add-assignee": true, "--add-blocked-by": true, "--add-blocking": true,
				"--add-label": true, "--add-project": true, "--add-sub-issue": true,
				"-b": true, "--body": true, "-F": true, "--body-file": true,
				"-m": true, "--milestone": true, "--parent": true,
				"--remove-assignee": true, "--remove-blocked-by": true,
				"--remove-blocking": true, "--remove-label": true,
				"--remove-project": true, "--remove-sub-issue": true,
				"-t": true, "--title": true, "--type": true,
			},
			map[string]bool{
				"--remove-milestone": true, "--remove-parent": true, "--remove-type": true,
			},
			ghBodyFileFlags, -1),
		"close": ghSpec(
			map[string]bool{
				"-c": true, "--comment": true, "--duplicate-of": true,
				"-r": true, "--reason": true,
			},
			nil, nil, -1),
		"reopen": ghSpec(
			map[string]bool{"-c": true, "--comment": true},
			nil, nil, -1),
		"pin":    ghSpec(nil, nil, nil, -1),
		"unpin":  ghSpec(nil, nil, nil, -1),
		"lock":   ghSpec(map[string]bool{"-r": true, "--reason": true}, nil, nil, -1),
		"unlock": ghSpec(nil, nil, nil, -1),
	},
	"release": {
		// `gh release create [<tag>] [<filename>...]` uploads every positional
		// after the tag as a release asset, so the positionals are graded from
		// index 1 as well as the `--notes-file` value. The verb ASKs on the
		// publish tier either way; grading it here is what turns an ESCAPING
		// asset path into a deny instead of a click-through.
		"create": ghSpec(
			map[string]bool{
				"--discussion-category": true, "-n": true, "--notes": true,
				"-F": true, "--notes-file": true, "--notes-start-tag": true,
				"--target": true, "-t": true, "--title": true,
			},
			map[string]bool{
				"-d": true, "--draft": true, "--fail-on-no-commits": true,
				"--generate-notes": true, "--latest": true, "--notes-from-tag": true,
				"-p": true, "--prerelease": true, "--verify-tag": true,
			},
			ghNotesFileFlags, 1),
		// `gh release edit <tag>` takes no file positional.
		"edit": ghSpec(
			map[string]bool{
				"--discussion-category": true, "-n": true, "--notes": true,
				"-F": true, "--notes-file": true, "--tag": true, "--target": true,
				"-t": true, "--title": true,
			},
			map[string]bool{
				"--draft": true, "--latest": true, "--prerelease": true, "--verify-tag": true,
			},
			ghNotesFileFlags, 1),
		// `gh release upload <tag> <files>...` — every positional after the tag is
		// a local file published as a release asset.
		"upload": ghSpec(nil, map[string]bool{"--clobber": true}, nil, 1),
	},
	"label": {
		"create": ghSpec(
			map[string]bool{"-c": true, "--color": true, "-d": true, "--description": true},
			map[string]bool{"-f": true, "--force": true},
			nil, -1),
		"edit": ghSpec(
			map[string]bool{
				"-c": true, "--color": true, "-d": true, "--description": true,
				"-n": true, "--name": true,
			},
			nil, nil, -1),
		// `gh label clone <source-repository>` — the positional is a repo, not a file.
		"clone": ghSpec(nil, map[string]bool{"-f": true, "--force": true}, nil, -1),
	},
	"gist": {
		// `gh gist create [<filename>...]` — every positional is a local file
		// whose contents become the gist. `-f`/`--filename` is NOT a path: it
		// supplies the NAME the gist gives content read from stdin.
		"create": ghSpec(
			map[string]bool{"-d": true, "--desc": true, "-f": true, "--filename": true},
			map[string]bool{"-p": true, "--public": true, "-w": true, "--web": true},
			nil, 0),
		// `gh gist edit {<id>|<url>} [<filename>]` — the second positional is a
		// LOCAL file whose contents replace a gist file, and `-a`/`--add` names a
		// local file to add. `-f`/`--filename` and `-r`/`--remove` name files
		// INSIDE the gist and open nothing locally.
		"edit": ghSpec(
			map[string]bool{
				"-a": true, "--add": true, "-d": true, "--desc": true,
				"-f": true, "--filename": true, "-r": true, "--remove": true,
			},
			nil,
			map[string]bool{"-a": true, "--add": true}, 1),
	},
	"cache": {
		// `gh cache delete [<cache-id> | <cache-key>]` — the positional is a cache
		// key, not a file.
		"delete": ghSpec(
			map[string]bool{"-r": true, "--ref": true},
			map[string]bool{"-a": true, "--all": true, "--succeed-on-no-caches": true},
			nil, -1),
	},
}

// ghPublishedFileEscalates grades the LOCAL files a gh publish command reads and
// sends to GitHub, and returns a terminal decision when one of them cannot be
// vouched for. cmd is the flag-stripped command path (noun verb …) that
// parseGhGlobals produced — it still carries the verb's own flags and operands,
// which is what this walk reads.
//
// The order of the checks is the failure asymmetry: a containment DENY is the
// strongest verdict and is returned first, so an escaping path denies even when
// the same command also carries an unmodelled flag. The unknown-flag ASK follows,
// then the verb's own tier (publish ASK, foreign-target ASK, recoverable-write
// ALLOW) decides the rest back in classifyGh.
func ghPublishedFileEscalates(cmd []string, sc simpleCommand, ev *Event) (Decision, bool) {
	if len(cmd) < 2 {
		return Decision{}, false
	}
	noun, verb := cmd[0], cmd[1]
	verbs, ok := ghFileSpecs[noun]
	if !ok {
		return Decision{}, false
	}
	spec, ok := verbs[verb]
	if !ok {
		return Decision{}, false
	}
	rest := cmd[2:]
	label := "gh " + noun + " " + verb

	paths := ghPublishedFilePaths(rest, spec, sc)
	if len(paths) > 0 {
		// A path built from an expansion the gate cannot resolve statically
		// cannot be contained. It reaches here rather than the non-static-argv
		// deny because `-F`/`-t`/`-b` are on gh's shield table (their values were
		// established as non-classification-bearing for `gh api`, where `-F` is a
		// request FIELD). On a publish verb `-F` is the body-file flag and its
		// value IS classification-bearing now, so fail closed ASK — the same
		// posture the read and write tracks hold for a dynamic path.
		if sc.hasUnknownExpansion {
			return ask("gh publish-file:dynamic-path (#229)", fmt.Sprintf(
				"Blocked: '%s' reads a local file whose path is built from an expansion the gate cannot resolve "+
					"statically, and it publishes that file's contents to GitHub. Escalating to a human decision "+
					"(fail-closed). Spell the path literally so containment can grade it.", label)), true
		}
		if d, hit := cdInvalidAsk(label, sc); hit {
			return d, true
		}
		// containReadSources forwards an escape verdict and discards the ALLOW: a
		// contained body file is no grounds to bless the publish, which the verb's
		// own tier decides.
		if d, clean := containReadSources(label, paths, sc, ev); !clean {
			return d, true
		}
	}

	if d, hit := ghUnmodelledFlagAsk(label, rest, spec); hit {
		return d, true
	}
	return Decision{}, false
}

// ghPublishedFilePaths returns every LOCAL path this invocation reads and
// publishes: the verb's positional file operands plus the values of its
// path-valued flags, with a `-` (gh's read-from-stdin marker) replaced by the
// command's input-redirect sources.
//
// The flag values are APPENDED to the positional walk, never substituted for it,
// so a mismodelled flag arity can only ever add a path to containment — it can
// never swallow a genuine file operand out of the walk. That is the same
// property utilitySpec.operands relies on, and pathFlagValues is the same
// extractor, so all four flag spellings are covered here for free.
//
// The `-` substitution closes the alternate spelling of the same publish:
// `gh pr comment 227 -F - < /etc/passwd` sends the file just as
// `-F /etc/passwd` does, and only the redirect names it. A `-` with no input
// redirect contributes nothing — the bytes then come from the terminal or from a
// pipe whose producer the walk classifies on its own terms.
func ghPublishedFilePaths(args []string, spec ghFileSpec, sc simpleCommand) []string {
	paths := append(ghFilePositionals(args, spec), pathFlagValues(args, spec.valueFlags, spec.pathValueFlags)...)
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		if p == "-" {
			out = append(out, sc.inputRedirectTargets...)
			continue
		}
		out = append(out, p)
	}
	return dedupeOperands(out)
}

// ghFilePositionals returns the positional operands of a gh command that name
// local files, per the verb's own usage grammar: those at or after
// spec.filePositionalsFrom. A verb with no file positional
// (filePositionalsFrom < 0) returns none, which is why
// `gh pr comment 227 -F body.md` never tests `227` as a path and
// `gh label clone owner/repo` never tests the repo slug as one.
//
// Flag values are consumed rather than returned, in every spelling gh accepts,
// so a value is not mistaken for a positional. An UNRECOGNIZED flag is treated
// as taking no value, which leaves its value counted as a positional: that
// direction only adds a path to containment, and the unmodelled flag escalates
// on its own account anyway.
func ghFilePositionals(args []string, spec ghFileSpec) []string {
	if spec.filePositionalsFrom < 0 {
		return nil
	}
	var positionals []string
	sawDashDash := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if sawDashDash {
			positionals = append(positionals, a)
			continue
		}
		switch {
		case a == "--":
			sawDashDash = true
		case !strings.HasPrefix(a, "-"), a == "-":
			positionals = append(positionals, a)
		case strings.HasPrefix(a, "--"):
			if strings.IndexByte(a, '=') >= 0 {
				continue // `--flag=value` carries its own value
			}
			if spec.valueFlags[a] && i+1 < len(args) {
				i++ // consume the separate value token
			}
		default:
			// A single-dash token: one short flag, or a bundle. The first
			// value-taking character consumes the rest of the cluster as its value
			// (getopt semantics), or the next token when it sits at the end.
			for j := 1; j < len(a); j++ {
				f := "-" + string(a[j])
				if !spec.valueFlags[f] {
					continue
				}
				if j+1 >= len(a) && i+1 < len(args) {
					i++ // consume the separate value token
				}
				break
			}
		}
	}
	if len(positionals) <= spec.filePositionalsFrom {
		return nil
	}
	return positionals[spec.filePositionalsFrom:]
}

// ghUnmodelledFlagAsk screens a publish verb's flags against the verb's complete
// modelled grammar and returns a terminal ASK for the first token the gate does
// not recognize. This is the whitelist half of the fix: without it, a gh release
// that adds a second file-reading flag would ride the verb's existing ALLOW and
// publish an ungraded file, exactly as `-F` did before this change.
//
// It is the same shape ghAuthStatusEscalates holds for `gh auth status` and
// parseGhGlobals holds for an unknown leading global: a recognized flag continues,
// anything else escalates, and the cost of being wrong is one human click rather
// than a silent publish. A POSITIONAL token is not screened — the verbs here take
// issue numbers, tags, gist ids and filenames positionally, and those are graded
// by containment (when they name files) or carry no local read at all.
func ghUnmodelledFlagAsk(label string, args []string, spec ghFileSpec) (Decision, bool) {
	unknown := func(tok string) (Decision, bool) {
		return ask("gh publish-file:unknown-flag (#229)", fmt.Sprintf(
			"'%s %s' carries a flag the permission gate does not model. This command publishes to GitHub and can "+
				"read a local file to do it (via a body-file / notes-file flag), so an unmodelled flag could name a "+
				"file that leaves the machine without ever being graded against the repository boundary. Escalating "+
				"to a human rather than allowing it. If the flag is a routine one, it can be added to the gate's "+
				"per-verb flag model.", label, tok)), true
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			return Decision{}, false // the rest are operands
		}
		if !strings.HasPrefix(a, "-") || a == "-" {
			continue // a positional
		}
		if strings.HasPrefix(a, "--") {
			name := a
			glued := false
			if eq := strings.IndexByte(a, '='); eq >= 0 {
				name, glued = a[:eq], true
			}
			if spec.boolFlags[name] {
				continue // `--latest` and `--latest=false` are both gh-legal
			}
			if spec.valueFlags[name] {
				if !glued && i+1 < len(args) {
					i++ // consume the separate value token
				}
				continue
			}
			return unknown(a)
		}
		// A single-dash token: one short flag, a glued value (`-Fbody.md`), or a
		// bundle of bools. Every character up to the first value-taking one must be
		// a modelled bool; the value-taking one consumes the remainder.
		for j := 1; j < len(a); j++ {
			f := "-" + string(a[j])
			if spec.valueFlags[f] {
				if j+1 >= len(a) && i+1 < len(args) {
					i++ // the value is the next token
				}
				break
			}
			if !spec.boolFlags[f] {
				return unknown(a)
			}
		}
	}
	return Decision{}, false
}
