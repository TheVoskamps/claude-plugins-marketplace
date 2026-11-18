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

## Ask through `sdlc-decision ask`

```bash
sdlc-decision ask (--pr <ref> | --issue <ref>) [--ruling <class>=<value>]… <record-file>
```

Pass the `--ruling` arguments `skills/lib/sdlc-config.md` → "Standing
rulings" calls for. A refusal names each slot it failed on; fix the
record and ask again.

## End the turn on what `ask` printed

When every problem `ask` printed reads `resolved by <class>: <value>`,
nothing was asked: apply each ruling, name it in the run's report, and
carry on, with no turn ended and no reply to record. Otherwise what it
printed goes last in the reply, and the turn ends there. A relayed report and your
own analysis go above it, and name each problem it printed as
`resolved by <class>: <value>`.

## Record the reply to a record that asked

```bash
sdlc-decision answer (--pr <ref> | --issue <ref>) --decision <n> \
  --pick P<i>=<option id>… --reply-file <path>
```

Write the reply verbatim to a scratchpad file first. Pick `none` for a
problem the reply answered in its own words, and give no pick for one it
did not address, which goes into the next turn's record.
