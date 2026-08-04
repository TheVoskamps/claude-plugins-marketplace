---
name: old-code-claim-hits-a-different-guard
description: A "here is what the pre-fix code did" sentence in your comment or PR body is a prediction, and it is usually wrong in the same way — the misparsed value lands in the wrong slot and then trips an UNRELATED downstream guard before reaching the consequence you named; drive the old code with the exact record and read its log
metadata:
  type: project
---

When you fix a misparse, the natural comment is "the old read took X as Y,
**so it then did Z**". That trailing clause is a claim about code you are
deleting, so nothing you build or test afterwards can falsify it — and it is
the half most likely to be false. The wrong value does not travel far: it
lands in a slot that some *other* validator already guards, and the observable
damage is a confident diagnostic about a thing that does not exist, not the
downstream action you predicted.

**Measured on PR #228 (issue #226), final round.** The fix hand-split
`boot_plugin_phase`'s two-field marketplace record, and the comment asserted
that the old tab-IFS read "asked the CLI whether a marketplace literally
called `https://…` was registered, and then ran `marketplace add` with an
EMPTY url". Driving HEAD's own extracted phase with the exact record showed
it never reached `marketplace add` at all: an ordinary https url tripped the
loop's *name charset* guard (`*[!A-Za-z0-9._-]*`) two lines earlier and logged
`name 'https://…' contains characters outside …`. Only a charset-clean url (a bare
host) got as far as the no-url branch. Same shape in the PR body's claim that
"the guest's boot phase carried a marketplace called `https://…`" — it
rejected one instead. Both sentences were written from reasoning; one `bash`
run of the pre-change function settled them in under a minute.

**How to apply.** The pre-change tree is one `git archive <sha> | tar -x` away
(that same hybrid tree — old payload, new test file overlaid — is also how you
negation-check the round's new assertions: on #228 it showed 16 of 24 new
assertions failing there, the 8 survivors being exactly the premise records,
regression guards and the controls). Extract the old function by line range,
stub its `log` to print, feed it the offending record, and quote what it
actually emitted. Then write the comment. Related:
[[drive-every-path-a-summary-claims]] (an enumeration of paths is a thing to
RUN), [[verify-a-predicted-verdict-before-implementing-it]] (a stated verdict
about current behavior is a prediction), and
[[missing-key-and-explicit-empty-differ]] (the emitter-side twin of this:
probe both spellings before calling a case impossible).
