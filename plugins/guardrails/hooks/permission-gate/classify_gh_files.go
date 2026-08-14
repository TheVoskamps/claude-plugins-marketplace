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
// The mechanism is reused rather than rebuilt: pathFlagValueRefs
// (readonly_util.go, the ref-tagged half of pathFlagValues) extracts a flag's
// value in every spelling THAT WALK covers — a separate token (`-F FILE`), a
// glued short form (`-FFILE`), an `=`-joined long form (`--body-file=FILE`),
// and the value-taking tail of a short cluster, all getopt's; gh's own
// `-F=FILE` is not among them and is appended separately by
// ghPflagEqualValueRefs — and containReadSources (classify_files.go) runs the
// results through the read containment, forwarding an escape and discarding the
// ALLOW (a contained body file is no grounds to bless the publish itself; the
// verb's own tier decides that).
//
// Properties carried over from #225:
//
//   - APPENDED, never substituted. The flag values are added to the verb's
//     positional file operands, so the flag model can only ever put MORE paths
//     through containment and can never swallow a genuine operand out of the
//     walk.
//   - FAIL SAFE on an unmodelled flag. Each spec enumerates its verb's COMPLETE
//     flag set, and an unrecognized flag escalates rather than riding the verb's
//     allow — the same whitelist SHAPE ghAuthStatusEscalates holds for
//     `gh auth status`, though not the same tier: this one DEFERS with its
//     analysis (#262 rebucketed it from ask), where the `gh auth status` screen
//     is a credential-read guard and stays a hard ask. A future gh release that
//     adds another file-reading flag therefore costs a graded, deferred call,
//     not a silent publish. See ghUnmodelledFlagDefer.
//
// The specs are transcribed from `gh <noun> <verb> --help`, and that output is
// NOT gh's accepted grammar: gh parses with cobra/pflag, which accept spellings
// the help block never renders. Anything in that residue has to be modelled by
// hand, because no amount of re-reading the help finds it. What follows exhausts
// the residue as measured — an auditor re-deriving this table from help output
// will find nothing here it does not already name: `-h` (see
// ghInheritedBoolFlags) and the `-F=FILE` short form (see
// ghPflagEqualValueRefs, plus the `=` stop both cluster walks below make).
//
// A path the gate cannot resolve statically DEFERS with the analysis (it can
// never ride the allow track), and that question is asked PER TOKEN
// (ghPathTokensDynamic) rather than of the whole
// command: the ordinary agent spelling
// `gh pr create --title "$TITLE" --body-file .claude/tmp/body.md` carries a
// dynamic value on a deliberately shielded flag beside a perfectly literal body
// file, and #229 requires it to keep allowing.

// ghFileSpec models one gh noun/verb for the purpose of grading the local files
// it reads and publishes.
//
// valueFlags and boolFlags together are the verb's COMPLETE flag grammar; a flag
// in neither is unrecognized and escalates. Both start from
// `gh <noun> <verb> --help` (gh 2.97.0) and are then completed by hand wherever
// that output falls short of what gh accepts: ghInheritedBoolFlags carries `-h`
// beside the `--help` the INHERITED FLAGS block is the only one to render.
// pathValueFlags is the subset of valueFlags whose value names a LOCAL file —
// gh's own help annotates a flag's value type, and a `file` annotation puts a
// flag in this set, as does a closer read of an annotation that understates the
// file gh really opens (`--recover`, in the annotation notes on ghFileSpecs;
// `gist edit`'s `-a`/`--add`, at its own entry there).
//
// filePositionalsFrom is the index, among the verb's positional operands, of the
// first one that names a local file; -1 when the verb takes none. It exists
// because some publish verbs take their files positionally rather than by flag:
// `gh gist create [<filename>... | <pattern>... | -]` names them from index 0,
// while `gh release create [<tag>] [<filename>... | <pattern>...]`,
// `gh release upload <tag> <files>...` and
// `gh gist edit {<id>|<url>} [<filename>]` reserve the first positional for
// a tag / gist id and name files from index 1. `gh release edit <tag>` carries 1
// as well although its grammar has no file positional at all: an operand gh
// would itself reject is then graded rather than left ungraded.
//
// A `<pattern>` operand needs no handling of its own. It reaches the gate as
// one word, containment resolves its escaping prefix without expanding it, and
// the verdict is the one the prefix earns: `gh release create v1
// '../sib/*.tgz'` denies, while a contained `gh gist create '*.md'` is not
// denied for a path the gate could not expand — it falls through to its verb's
// own tier, which for both gist verbs is the publish ASK (#229).
//
// defaultsToStdin marks a verb that reads STDIN when the invocation gives it no
// file operand at all — the implicit spelling of the `-` marker, which has no
// token for the `-` substitution in ghPublishedFileRefs to fire on. See its
// one member in ghFileSpecs.
type ghFileSpec struct {
	valueFlags          map[string]bool
	boolFlags           map[string]bool
	pathValueFlags      map[string]bool
	filePositionalsFrom int
	defaultsToStdin     bool
}

// readsLocalFiles reports whether the gate models ANY local-file surface on this
// verb: a path-valued flag, a file positional, or the stdin default. Roughly half
// the table's verbs have none — `pr close`, `issue pin`, `label edit`,
// `cache delete` and their neighbours write to GitHub and read nothing off the
// local disk — and the unmodelled-flag analysis words itself on that, so it does
// not report a body-file risk the command cannot have.
func (s ghFileSpec) readsLocalFiles() bool {
	return len(s.pathValueFlags) > 0 || s.filePositionalsFrom >= 0 || s.defaultsToStdin
}

// ghInheritedValueFlags and ghInheritedBoolFlags are gh's per-command inherited
// flags (`gh <noun> <verb> --help` → INHERITED FLAGS). `-R`/`--repo` is accepted
// AFTER the noun as well as before it — ghExplicitRepoTarget already scans the
// command path for exactly that spelling — so every spec must recognize it or
// the routine `gh issue comment -R owner/repo N -F body.md` would escalate on a
// flag gh documents. They are merged into each spec by ghSpec rather than
// repeated in 26 literals.
//
// The inheritance is not quite uniform: `--help` reaches all 26 pairs, while
// `-R`/`--repo` reaches 24. `gist create` and `gist edit` render no repo entry
// in their INHERITED FLAGS block and answer both spellings with `unknown flag`
// / `unknown shorthand flag` (measured, gh 2.97.0) — a gist is not a repository
// resource. ghSpec folds the pair into those two specs anyway: modelling a flag
// gh itself rejects withholds an escalation from an invocation that cannot run.
var ghInheritedValueFlags = map[string]bool{"-R": true, "--repo": true}

// `--help` is the spelling gh's INHERITED FLAGS block renders; `-h` is the one
// it accepts without rendering. gh's root command registers the long form as a
// persistent flag with NO shorthand (`cmd.PersistentFlags().Bool("help", false,
// …)` in cli/cli's pkg/cmd/root/root.go), and pflag then supplies the short form
// itself: parseSingleShortArg answers an UNREGISTERED `h` shorthand with
// f.usage() and ErrHelp rather than an error, which gh surfaces as the command's
// help text and exit 0. Measured on gh 2.97.0: `gh <noun> <verb> -h` exits 0 for
// all 26 pairs in ghFileSpecs, none of which renders a `-h` of its own, so one
// entry covers the table. Without it a help invocation would be the one
// documented gh spelling this whitelist escalates.
var ghInheritedBoolFlags = map[string]bool{"--help": true, "-h": true}

// ghSpec builds a ghFileSpec, folding gh's inherited flags into the verb's own
// sets. pathValueFlags must be a subset of the verb's valueFlags; that is
// asserted by TestGhFileSpecsPathFlagsAreValueFlags_229 rather than at run time.
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

// ghStdinDefault marks a spec whose verb reads STDIN when the invocation carries
// no file operand at all, so the walk grades the input redirect exactly as it
// grades an explicit `-`.
func ghStdinDefault(s ghFileSpec) ghFileSpec {
	s.defaultsToStdin = true
	return s
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
// plus the publish verbs that are not in that map at all — `release create`,
// `gist create` and `gist edit`, which reach the publish ASK tier above
// isGhRecoverableWrite and would otherwise escalate on the verb while never
// grading the path. Their spec is what makes an ESCAPING operand DENY instead of
// being offered as a click-through on the publish prompt.
//
// Read verbs are deliberately absent. A read sends nothing of the local disk to
// GitHub, so it has no publish surface to grade, and its output-redirect surface
// is already graded by credentialedRedirectVerdict.
//
// Flag sets transcribed from `gh <noun> <verb> --help` (gh 2.97.0). A flag gh
// annotates `file` is a pathValueFlag; one it annotates `string`, `text`,
// `name`, `title`, `login`, `handle`, `branch`, `number`, `numbers` or `SHA`
// is not. Those, together with `file` itself, are the whole annotation
// vocabulary of the VALUE-TAKING flags these verbs' own FLAGS blocks render;
// the inherited `-R`/`--repo` adds `[HOST/]OWNER/REPO`, which names a
// repository and not a path. (A bool renders no value type of its own, so the
// `--all` in `cache delete`'s `--succeed-on-no-caches --all` line is not one: gh
// registers that flag with BoolVar and a usage string carrying a backquoted
// `--all`, which pflag's UnquoteUsage lifts into the type column.)
// These annotations needed a closer read than the type alone; `gist edit`'s
// `-a`/`--add` needed one as well, and is documented at its own entry below:
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
		// `gh release create [<tag>] [<filename>... | <pattern>...]` uploads every positional
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
		// `gh release edit <tag>` takes no file positional in gh's own grammar;
		// grading from index 1 therefore normally finds nothing, and grades a
		// stray extra operand rather than ignoring it.
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
		// `gh gist create [<filename>... | <pattern>... | -]` — every positional
		// is a local file whose contents become the gist. `-f`/`--filename` is
		// NOT a path: it supplies the NAME the gist gives content read from stdin.
		//
		// It is also the ONE verb in this table that reads stdin with no marker of
		// any kind: gh's createRun does `if len(filenames) == 0 { filenames =
		// []string{"-"} }`, and its Args validator accepts zero operands whenever
		// stdin is not a TTY, so `gh gist create < /etc/passwd` publishes the file
		// with nothing in argv naming it. ghStdinDefault is what puts that
		// implicit `-` through the same grading the explicit one gets. No other
		// verb here reads stdin unless the invocation NAMES it, so none of the
		// others carries the marker: `pr comment` and `release create` document
		// `-` on their `-F` flag, and `gist edit` reads a `-` in its file
		// positional (see its entry below) but never without one.
		"create": ghStdinDefault(ghSpec(
			map[string]bool{"-d": true, "--desc": true, "-f": true, "--filename": true},
			map[string]bool{"-p": true, "--public": true, "-w": true, "--web": true},
			nil, 0)),
		// `gh gist edit {<id>|<url>} [<filename>]` — the second positional is a
		// LOCAL file whose contents replace a gist file, and `-a`/`--add` names a
		// local file to add. `-f`/`--filename` and `-r`/`--remove` name files
		// INSIDE the gist and open nothing locally. Like its `create` sibling the
		// verb reaches the publish ASK rather than an outright ALLOW (#229), so
		// this spec is what keeps an ESCAPING operand a DENY rather than a
		// click-through on that prompt.
		//
		// That positional also accepts gh's stdin marker, which its help does not
		// render: cli/cli v2.97.0's edit.go binds `opts.SourceFile = args[1]` and
		// then switches `case src == "-": input = opts.IO.In`, in the `--add`
		// branch and the plain-edit branch alike. The `-` substitution in
		// ghPublishedFileRefs is origin-agnostic, so it fires on that positional
		// as it does on a flag value and `gh gist edit <id> - < /etc/passwd`
		// denies. No `defaultsToStdin` though: with no second positional the verb
		// opens an EDITOR rather than reading stdin, so there is nothing to
		// synthesize a marker for.
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

// The `--public` SCREEN this file used to carry (`ghGistCreateIsPublic`, and the
// pflag cluster walk `ghBoolFlagNamed` under it) is gone: `gh gist create`
// escalates on the verb alone now, in every spelling of every flag, because a
// gist created without `--public` is unlisted rather than private and is
// therefore exposure too (#229). Nothing else consulted the screen, so reading
// the flag would only have decorated a message with a distinction the gate
// cannot state honestly — the walk reported the flag being NAMED, not the value
// it carried, so `--public=false` (a SECRET gist) would have been described as a
// public one. The tier's own message states both visibilities instead.
//
// What the screen shared with the two walks below survives at their own sites:
// the `=`-after-a-shorthand rule is documented and relied on in
// ghFilePositionalRefs and ghUnmodelledFlagDefer, and `-p`/`--public` stays in the
// `gist create` spec's boolFlags so the unmodelled-flag screen still recognizes
// it.

// ghPublishedFileEscalates grades the LOCAL files a gh publish command reads and
// sends to GitHub, and returns a terminal decision when one of them cannot be
// vouched for. cmd is the flag-stripped command path (noun verb …) that
// parseGhGlobals produced — it still carries the verb's own flags and operands,
// which is what this walk reads.
//
// The order of the checks is the failure asymmetry: a containment DENY is the
// strongest verdict and is returned first, so an escaping path denies even when
// the same command also carries an unmodelled flag. The unknown-flag DEFER
// follows, then the verb's own tier (publish hard-ASK, foreign-target DEFER,
// recoverable-write ALLOW) decides the rest back in classifyGh.
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

	refs := ghPublishedFileRefs(rest, spec, sc)
	if len(refs) > 0 {
		// A path built from an expansion the gate cannot resolve statically
		// cannot be contained. Most dynamic spellings never get this far — the
		// non-static-argv deny takes them, `gh pr comment -F $BODY` included,
		// because a FIELD flag shields its value only when the `key=` is
		// statically pinned. What does reach here is a dynamic value on a
		// non-field entry of gh's shield table (classify_command.go), whose value
		// was established as non-classification-bearing for `gh api`: `--template`
		// is one, and on `gh pr create` that flag names a local template FILE, so
		// its value IS classification-bearing now. Only that LONG spelling reaches
		// here — the shield table's `-t` is `gh pr create`'s `--title` and names no
		// file, and the verb's short template flag `-T` is not shielded at all, so
		// `gh pr create -T $X` still denies at the precondition. DEFER with the
		// analysis — the same posture the read and write tracks hold for a
		// dynamic path.
		//
		// The question is asked of the PATH TOKENS, not of the whole command: a
		// dynamic value on a SHIELDED non-path flag leaves a literal body file
		// perfectly gradable, and `gh pr create --title "$TITLE" --body-file
		// .claude/tmp/body.md` is the ordinary agent spelling, which #229 requires
		// to keep allowing.
		if ghPathTokensDynamic(refs, rest, sc) {
			return deferJudgment("gh publish-file:dynamic-path (#229)", fmt.Sprintf(
				"'%s' reads a local file whose path is built from an expansion the gate cannot resolve "+
					"statically, and it publishes that file's contents to GitHub, so containment cannot grade "+
					"what leaves the machine.", label)), true
		}
		if d, hit := cdInvalidDefer(label, sc); hit {
			return d, true
		}
		// containReadSources forwards an escape verdict and discards the ALLOW: a
		// contained body file is no grounds to bless the publish, which the verb's
		// own tier decides.
		if d, clean := containReadSources(label, ghRefPaths(refs), sc, ev); !clean {
			return d, true
		}
	}

	if d, hit := ghUnmodelledFlagDefer(label, rest, spec); hit {
		return d, true
	}
	return Decision{}, false
}

// ghPathTokensDynamic reports whether any token that CONTRIBUTED one of these
// published paths is a word the gate could not resolve statically.
//
// It is the per-token narrowing of simpleCommand.hasUnknownExpansion, which
// answers only "was anything dynamic anywhere" and so escalated a static,
// contained body file whenever the same command carried a dynamic value on a
// deliberately SHIELDED flag (`--title "$TITLE"`, `--body "$MSG"`).
// unshieldedDynamicArg holds the same narrowing for the non-static-argv
// precondition, and for the same reason: the shield table exists precisely
// because those values cannot occupy a position the gate classifies on. This
// track therefore inherits that premise and no more — the command only reaches
// here because the precondition already accepted the same dynamic token on the
// same grounds.
//
// It fails closed — back to the whole-command bool — wherever the per-token
// answer is not available: a hand-built simpleCommand carrying no
// argMeta, and a path with no argv token of its own. The latter is an
// input-redirect source substituted for a `-`: a redirect WORD's dynamism sets
// hasUnknownExpansion but occupies no argv slot, so there is no per-token
// `exact` to read, and a partially-resolved redirect target (`< ./$X` reduces to
// `./`) would otherwise read as contained.
func ghPathTokensDynamic(refs []pathRef, args []string, sc simpleCommand) bool {
	exact, ok := ghArgExactness(args, sc)
	if !ok {
		return sc.hasUnknownExpansion
	}
	for _, r := range refs {
		if r.arg < 0 || r.arg >= len(exact) {
			if sc.hasUnknownExpansion {
				return true
			}
			continue
		}
		if !exact[r.arg] {
			return true
		}
	}
	return false
}

// ghArgExactness returns a slice parallel to args reporting, per token, whether
// it expanded to a static literal, and false when that cannot be established.
//
// args is the tail of the gh invocation this classifier walks, which is by
// construction a SUFFIX of sc.args (classifySimpleCommand passes sc.args[1:] to
// classifyGh, parseGhGlobals drops the leading globals, and the noun and verb
// come off the front). The alignment is verified rather than assumed: every
// token must match at the offset the length difference implies, and any
// mismatch — or an absent argMeta, which a hand-built simpleCommand has — reports
// false so the caller falls back to the whole-command bool.
func ghArgExactness(args []string, sc simpleCommand) ([]bool, bool) {
	if len(sc.argMeta) != len(sc.args) || len(args) > len(sc.args) {
		return nil, false
	}
	off := len(sc.args) - len(args)
	out := make([]bool, len(args))
	for i, a := range args {
		if sc.args[off+i] != a {
			return nil, false
		}
		out[i] = sc.argMeta[off+i].exact
	}
	return out, true
}

// ghRefPaths is the deduped path list of a ref set, for the containment call. A
// path named both as a bare operand and as a flag value would otherwise be
// contained twice and, on an escape, named twice in one deny message.
func ghRefPaths(refs []pathRef) []string {
	paths := make([]string, 0, len(refs))
	for _, r := range refs {
		paths = append(paths, r.path)
	}
	return dedupeOperands(paths)
}

// ghPublishedFileRefs returns every LOCAL path this invocation reads and
// publishes, each tagged with the argv token it came from (see pathRef): the
// verb's positional file operands plus the values of its path-valued flags, with
// a `-` (gh's read-from-stdin marker) replaced by the command's input-redirect
// sources.
//
// The flag values are APPENDED to the positional walk, never substituted for it,
// so a mismodelled flag arity can only ever add a path to containment — it can
// never swallow a genuine file operand out of the walk. That is the same
// property utilitySpec.operands relies on, and pathFlagValueRefs is the same
// extractor pathFlagValues wraps, so every flag spelling that walk covers is
// covered here for free. The one spelling it does not cover is gh's alone, and
// ghPflagEqualValueRefs appends that reading too.
//
// The `-` substitution closes the alternate spelling of the same publish:
// `gh pr comment 227 -F - < /etc/passwd` sends the file just as
// `-F /etc/passwd` does, and only the redirect names it. A `-` with no input
// redirect contributes nothing — the bytes then come from the terminal or from a
// pipe whose producer the walk classifies on its own terms. A substituted path
// carries arg -1: it came from a redirect word, not from an argv token.
func ghPublishedFileRefs(args []string, spec ghFileSpec, sc simpleCommand) []pathRef {
	flagRefs := pathFlagValueRefs(args, spec.valueFlags, spec.pathValueFlags)
	refs := append(ghFilePositionalRefs(args, spec), flagRefs...)
	refs = append(refs, ghPflagEqualValueRefs(args, flagRefs)...)
	out := make([]pathRef, 0, len(refs))
	for _, r := range refs {
		if r.path == "-" {
			for _, t := range sc.inputRedirectTargets {
				out = append(out, pathRef{path: t, arg: -1})
			}
			continue
		}
		out = append(out, r)
	}
	return out
}

// ghPflagEqualValueRefs adds pflag's reading of a `-F=FILE` value to a ref set
// that pathFlagValueRefs extracted with getopt semantics.
//
// gh parses with pflag, and on this ONE spelling pflag and getopt disagree.
// pflag's parseSingleShortArg takes an `=` immediately after a shorthand as the
// separator (`if len(shorthands) > 2 && shorthands[1] == '=' { value =
// shorthands[2:] }`), so `gh pr comment 227 -F=/etc/passwd` opens
// `/etc/passwd` — measured against gh 2.97.0, where
// `gh pr comment 232 -F=/nonexistent/xyz.md` fails with
// `open /nonexistent/xyz.md`, naming the stripped path. getopt has no such rule
// and the shared extractor faithfully reports the value as `=/etc/passwd`, which
// is a relative name INSIDE the repo: contained, and the publish allowed.
//
// Both readings are graded rather than the getopt one replaced. The shared
// extractor keeps the semantics its getopt callers need (`grep -f=x` really does
// open `=x`), and appending preserves this walk's guarantee that it can only
// ever put MORE paths through containment.
//
// Only the GLUED SHORT spelling is normalized, which is why the ref's own token
// is re-read rather than the path alone tested: a separate-token value
// (`-F =x`) is the literal `=x` to pflag as well, and a long `--body-file==x`
// keeps everything after its first `=`. An empty remainder is dropped — `-F=`
// is under pflag's `len(shorthands) > 2` threshold and opens the literal `=`,
// which the getopt reading already carries.
func ghPflagEqualValueRefs(args []string, refs []pathRef) []pathRef {
	var out []pathRef
	for _, r := range refs {
		if !strings.HasPrefix(r.path, "=") || r.arg < 0 || r.arg >= len(args) {
			continue
		}
		tok := args[r.arg]
		if !strings.HasPrefix(tok, "-") || strings.HasPrefix(tok, "--") {
			continue // a separate-token value, or a long `=`-joined one
		}
		if v := r.path[1:]; v != "" {
			out = append(out, pathRef{path: v, arg: r.arg})
		}
	}
	return out
}

// ghFilePositionalRefs returns the positional operands of a gh command that name
// local files, per the verb's own usage grammar: those at or after
// spec.filePositionalsFrom. A verb with no file positional
// (filePositionalsFrom < 0) returns none, which is why
// `gh pr comment 227 -F body.md` never tests `227` as a path and
// `gh label clone owner/repo` never tests the repo slug as one.
//
// A verb whose spec sets defaultsToStdin and that received NO positional at all
// yields the `-` marker gh itself substitutes there, so the input redirect is
// graded: `gh gist create < /etc/passwd` publishes the file with nothing in argv
// naming it. The marker is synthetic, so it carries arg -1.
//
// Flag values are consumed rather than returned, in every spelling gh accepts,
// so a value is not mistaken for a positional. An UNRECOGNIZED flag is treated
// as taking no value, which leaves its value counted as a positional: that
// direction only adds a path to containment, and the unmodelled flag escalates
// on its own account anyway.
func ghFilePositionalRefs(args []string, spec ghFileSpec) []pathRef {
	var positionals []pathRef
	sawDashDash := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		if sawDashDash {
			positionals = append(positionals, pathRef{path: a, arg: i})
			continue
		}
		switch {
		case a == "--":
			sawDashDash = true
		case !strings.HasPrefix(a, "-"), a == "-":
			positionals = append(positionals, pathRef{path: a, arg: i})
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
				if a[j] == '=' && j > 1 {
					// pflag ends the token at an `=` that follows a shorthand and
					// hands the remainder to THAT flag (`-p=false`), so nothing
					// after it is a flag and no later token is its value. No
					// character before j was VALUE-TAKING — one would have broken
					// out below — but this walk consults valueFlags only, so the
					// `=` may follow a modelled bool (`-p=false`) or a character
					// the spec models not at all (`-Zp=f`), which gh itself
					// rejects and which ghUnmodelledFlagDefer escalates on its own
					// account. Stopping is the safe direction for both: it can
					// only leave MORE tokens in the positional walk. Missing it
					// would let `gh gist create -p=f /etc/passwd` read the
					// trailing `f` as `--filename` and swallow the escaping
					// operand out of that walk.
					break
				}
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
	// gh's own default: no file operand at all means it reads stdin.
	if len(positionals) == 0 && spec.defaultsToStdin {
		return []pathRef{{path: "-", arg: -1}}
	}
	if spec.filePositionalsFrom < 0 || len(positionals) <= spec.filePositionalsFrom {
		return nil
	}
	return positionals[spec.filePositionalsFrom:]
}

// ghUnmodelledFlagDefer screens a publish verb's flags against the verb's complete
// modelled grammar and returns a terminal DEFER for the first token the gate does
// not recognize (#262 rebucketed it from ask, and renamed it to match). This is
// the whitelist half of the fix: without it, a gh release
// that adds a second file-reading flag would ride the verb's existing ALLOW and
// publish an ungraded file, exactly as `-F` did before this change.
//
// It is the same whitelist SHAPE ghAuthStatusEscalates holds for `gh auth
// status` and parseGhGlobals holds for an unknown leading global — a recognized
// flag continues, anything else escalates — but not the same tier: this one
// grades a command whose class is otherwise established, so it withholds the
// allow and hands the call to the evaluator, where the `gh auth status` screen
// is a credential-read guard and stays a hard ask and parseGhGlobals denies. The
// cost of being wrong here is a graded call rather than a silent publish. A
// POSITIONAL token is not screened — the verbs here take
// issue numbers, tags, gist ids and filenames positionally, and those are graded
// by containment (when they name files) or carry no local read at all.
func ghUnmodelledFlagDefer(label string, args []string, spec ghFileSpec) (Decision, bool) {
	unknown := func(tok string) (Decision, bool) {
		// The risk clause is branched on the verb's own modelled surface. Roughly
		// half this table's verbs read no local file at all (`gh pr close`,
		// `gh issue pin`, `gh label edit`, `gh cache delete`, …), and telling a
		// downstream reader that such a command "can read a local file via a
		// body-file flag" reports a risk the command does not have.
		risk := "This command writes to GitHub, and an unmodelled flag could change what that write does — or " +
			"give the verb a local-file surface its model does not have — so the gate cannot vouch for it."
		if spec.readsLocalFiles() {
			risk = "This command publishes to GitHub and can read a local file to do it (via a body-file / " +
				"notes-file flag, or a file operand), so an unmodelled flag could name a file that leaves the " +
				"machine without ever being graded against the repository boundary."
		}
		return deferJudgment("gh publish-file:unknown-flag (#229)", fmt.Sprintf(
			"'%s %s' carries a flag the permission gate does not model. %s If the flag is a routine one, it "+
				"can be added to the gate's per-verb flag model.", label, tok, risk)), true
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
			if a[j] == '=' && j > 1 {
				// pflag's `-p=false`: the `=` after a shorthand ends the token and
				// the remainder is that flag's value, so there is no further flag
				// here to screen. gh accepts the spelling for every bool it
				// documents, and screening the `=` as a flag character would
				// escalate it. Restricted to j > 1 so a leading `-=x`, which pflag
				// rejects outright, still reaches the unmodelled-flag screen.
				break
			}
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
