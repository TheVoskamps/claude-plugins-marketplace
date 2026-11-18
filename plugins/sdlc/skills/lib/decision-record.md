# Putting a decision to the human (`skills/lib/decision-record.md`)

This file is the single statement of **how** an sdlc skill puts a
decision to the human through `bin/sdlc-decision`. The record it checks
is what makes a reply mappable to the problem it answers, and what lets
a later run count how the human rules each class. A decision
is any question that asks the human to choose. Which prompts a skill
keeps out of this route, and what it keys its records on, are the
skill's own.

## Write one record for the turn

The record is a YAML file in the session scratchpad, holding every
problem the turn puts to the human, in the shape `bin/sdlc-decision`'s
header defines. Each problem names its class from the class list that
script defines, `unclassified` when none fits, and its evidence is what
you ran or read.

A `file:` evidence names a file on disk where `ask` runs, which it
reads to check the quote. Text no such file holds — an issue's body, a
PR's comment, a line on a branch the working tree does not have checked
out — is a `command:` evidence instead: the command that printed it,
such as `issue-view <N>` or `git show <branch>:<path>`, and the lines
it printed that the option rests on as its `output:`.

## Fit a list of candidates to two to four options

`ask` refuses a problem with fewer than two options or more than four.
When a problem's options come from a list — the values a field
accepts, the issues an invocation named, the board options that could
stand in for a status — fit them so. A decision is one the human can
decline unless the skill asking it says otherwise.

- **A decision the human can decline** carries an option that skips
  the question and leaves things as they are, whatever the list's
  length: beside every entry when the list has three or fewer, and
  beside the three you rank first when it is longer.
- **Any other decision** offers every entry when the list has four or
  fewer, and otherwise the three you rank first and an option to name
  another, which the reply then names in its own words.

A list with no entry offers nothing to choose, so it is not put to the
human. Nor is a list of one for a decision the human cannot decline:
its one entry is taken as the pick, and no record is written for it.

## Ask through `sdlc-decision ask`

```bash
sdlc-decision ask (--pr <ref> | --issue <ref>) [--ruling <class>=<value>]… <record-file>
```

Pass the `--ruling` arguments `skills/lib/sdlc-config.md` → "Standing
rulings" calls for. A refusal names each slot it failed on; fix the
record and ask again.

## End the turn on what `ask` printed

A problem `ask` printed as `resolved by <class>: <value>` was not
asked: apply its ruling, and carry it to wherever your skill says a
decision a standing ruling resolved is carried. When every problem
reads so, nothing was asked: carry on, with no turn ended and no reply
to record. Otherwise what it printed goes last in the reply, and the
turn ends there. A relayed report and your own analysis go above it.

## Record the reply to a record that asked

```bash
sdlc-decision answer (--pr <ref> | --issue <ref>) --decision <n> \
  --pick P<i>=<option id>… --reply-file <path>
```

Write the reply verbatim to a scratchpad file first. Pick `none` for a
problem the reply answered in its own words, and give no pick for one it
did not address, which goes into the next turn's record.
