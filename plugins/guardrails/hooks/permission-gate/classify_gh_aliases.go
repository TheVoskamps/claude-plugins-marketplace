package main

// Resolution of `gh`'s own command aliases to their canonical spelling
// (issue #229).
//
// gh finds a subcommand by matching a token against a command's NAME or any of
// its cobra aliases, so `gh gist new` runs `gh gist create` — verified by help
// dispatch, where every alias spelling renders the canonical command's own
// USAGE line (`gh gist new --help` prints `gh gist create [<filename>… …]`).
// Every tier in classifyGh dispatches by name alone, so an alias matched none of
// them and fell through to the fail-closed "unrecognized command" ASK. That
// turned a documented respelling into a click-through past a verdict the gate
// had already reached: `gh gist create /etc/passwd` earns the #229 containment
// DENY while `gh gist new /etc/passwd` earned an ask, and the ALIASES block that
// names the respelling sits in the very help output ghFileSpecs was transcribed
// from.
//
// Resolving the alias BEFORE any tier runs gives each alias the verdict its
// canonical command already has — deny, ask or allow — rather than a verdict
// computed from the spelling. The fail-closed floor is untouched: a token that
// is in neither table is left exactly as written and still reaches the
// unrecognized-command ASK.
//
// PROVENANCE. The two tables below are the complete cobra-alias set of gh
// 2.97.0, derived twice and reconciled:
//
//   - by walking `gh <path> --help` over all 228 commands reachable from
//     `gh --help` and reading each ALIASES block;
//   - by grepping every `Aliases:` declaration in cli/cli at tag v2.97.0
//     (45 of them, `grep -rn "Aliases:" --include "*.go" | grep -v _test.go`;
//     no command sets `.Aliases` any other way).
//
// The two agree except for `gh accessibility`, which `gh --help` lists under
// HELP TOPICS rather than under a COMMANDS section, so only the source grep
// reaches its `a11y` alias. It is carried below for completeness.
//
// Those declarations reconcile against the tables as 7 + 33 + 5 = 45. The 7
// name a noun and produce the 10 entries of ghNounAliases (two declarations
// spell several aliases for one noun); the 33 name a verb one level down and
// are ghVerbAliases entry for entry; the 5 name a verb TWO levels down
// (`repo autolink new`, plus `ls` on `repo autolink`, `repo deploy-key`,
// `repo gitignore` and `repo license`) and are deliberately absent, because
// cmd[2] is a position no dispatch reads — see ghCanonicalCommand.
//
// The COLLISION CHECK that decided this is a fix rather than a wider hole: no
// alias name on any noun classifyGh models is a member of either allow table —
// the alias names are `ls`, `new`, `co`, `remove` and the noun aliases, while
// isGhReadOnly's read verbs are view/list/status/diff/checks/get and
// ghRecoverableWriteVerbs holds create/comment/merge/close/edit/… — so before
// this change every aliased spelling landed on the fail-closed ASK, and none
// rode an outright ALLOW. Resolution retires the question either way: an alias
// is rewritten before any table is consulted, so a future gh release that names
// an alias after an existing verb inherits that verb's canonical verdict rather
// than colliding with it.
//
// NOT covered, deliberately: gh's OTHER alias mechanism, the user-editable
// `aliases:` map in `~/.config/gh/config.yml` that `gh alias set` writes. gh
// ships one such alias by default (`co: pr checkout`, in cli/cli's
// internal/config/config.go), and it expands before dispatch just as a cobra
// alias does. The gate does not read the user's gh config, so those spellings
// keep the fail-closed ASK — which is the correct floor rather than a hole,
// because `gh alias set` refuses any name that is "already a gh command or
// extension", so a config alias can never shadow a noun this gate models. The
// shipped `co` diverges from nothing today: `gh co` and `gh pr checkout` both
// ASK, the latter because `checkout` is in neither allow table.

// ghNounAliases maps an alias spelling of a gh top-level noun to its canonical
// noun.
var ghNounAliases = map[string]string{
	"cs":          "codespace",
	"rs":          "ruleset",
	"skills":      "skill",
	"at":          "attestation",
	"ext":         "extension",
	"extensions":  "extension",
	"agent":       "agent-task",
	"agents":      "agent-task",
	"agent-tasks": "agent-task",
	"a11y":        "accessibility",
}

// ghVerbAliases maps, per CANONICAL noun, an alias spelling of that noun's verb
// to the canonical verb. Keyed by the canonical noun because ghCanonicalCommand
// resolves the noun first, so `gh rs ls` finds its verb under `ruleset`.
//
// Nouns classifyGh does not model are listed too, so the table is the measured
// set rather than a filtered one: filtering would hold an invariant ("these are
// the nouns the classifier touches") that goes stale the moment a noun joins
// isGhReadOnly's known set, and the entries cost nothing — an unmodelled noun's
// verdict is the fail-closed ASK whichever spelling it arrives in.
var ghVerbAliases = map[string]map[string]string{
	// Nouns classifyGh models.
	"pr":       {"new": "create", "ls": "list", "co": "checkout"},
	"issue":    {"new": "create", "ls": "list"},
	"gist":     {"new": "create", "ls": "list"},
	"release":  {"new": "create", "ls": "list"},
	"repo":     {"new": "create", "ls": "list"},
	"label":    {"ls": "list"},
	"cache":    {"ls": "list"},
	"run":      {"ls": "list"},
	"workflow": {"ls": "list"},
	"project":  {"ls": "list"},
	"ruleset":  {"ls": "list"},
	"secret":   {"ls": "list", "remove": "delete"},
	"variable": {"ls": "list", "remove": "delete"},

	// Nouns it does not.
	"org":        {"ls": "list"},
	"discussion": {"ls": "list"},
	"codespace":  {"ls": "list"},
	"alias":      {"ls": "list"},
	"config":     {"ls": "list"},
	"gpg-key":    {"ls": "list"},
	"ssh-key":    {"ls": "list"},
	"extension":  {"ls": "list", "uninstall": "remove"},
	"skill":      {"ls": "list", "add": "install", "show": "preview"},
}

// ghCanonicalCommand rewrites the NOUN and VERB positions of a gh command path
// from an alias spelling to gh's canonical one, and returns cmd unchanged when
// neither is an alias. Every other token is copied verbatim, so the tail this
// function returns is the same slice of flags and operands the caller received —
// which is what keeps ghArgExactness able to align it against the parsed
// simpleCommand.
//
// Only those two positions are rewritten because they are the only ones any
// dispatch reads: every tier in classifyGh branches on cmd[0] and cmd[1] alone.
// gh's third-level aliases (`gh repo autolink new`, `gh repo deploy-key ls`, …)
// therefore need no entry — their canonical spellings classify identically,
// since cmd[1] is `autolink` / `deploy-key`, which is in neither allow table, so
// both spellings reach the same fail-closed ASK.
//
// The result is a fresh slice whenever anything changed: cmd is a subslice of
// the caller's args, which classifyGhAPI still reads, so rewriting in place
// would corrupt it.
func ghCanonicalCommand(cmd []string) []string {
	if len(cmd) == 0 {
		return cmd
	}
	noun, nounAliased := ghNounAliases[cmd[0]]
	if !nounAliased {
		noun = cmd[0]
	}
	verb, verbAliased := "", false
	if len(cmd) >= 2 {
		verb, verbAliased = ghVerbAliases[noun][cmd[1]]
	}
	if !nounAliased && !verbAliased {
		return cmd
	}
	out := make([]string, len(cmd))
	copy(out, cmd)
	out[0] = noun
	if verbAliased {
		out[1] = verb
	}
	return out
}
