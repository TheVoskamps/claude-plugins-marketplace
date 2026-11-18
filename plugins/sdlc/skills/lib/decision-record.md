# Putting a decision to the human (`skills/lib/decision-record.md`)

This file is the single statement of **how** an sdlc skill puts a
decision to the human. `bin/sdlc-decision` is the only route: the record
it checks is what makes a reply mappable to the problem it answers, and
what lets a later run count how the human rules each class. A decision
is any question that asks the human to choose. Which prompts a skill
keeps out of this route, and what it keys its records on, are the
skill's own.

1. **Write one record for the turn**, a YAML file in the session
   scratchpad, holding every problem the turn puts to the human, in the
   shape `bin/sdlc-decision`'s header defines. Each problem names its
   class from the class list that script defines, `unclassified` when
   none fits, and its evidence is what you ran or read. `ask` checks a
   `file:` evidence against the file on disk, so a line on a branch no
   checkout on disk holds is a `command:` evidence: the command that
   printed it and what it printed.
2. **Ask:**

   ```bash
   sdlc-decision ask (--pr <ref> | --issue <ref>) [--ruling <class>=<value>]… <record-file>
   ```

   with the `--ruling` arguments `skills/lib/sdlc-config.md` →
   "Standing rulings" calls for. A refusal names each slot it failed
   on; fix the record and ask again.
3. **Print what it printed, verbatim, as the turn's question**, last in
   the reply, and end the turn. A relayed report and your own analysis
   go above it, and name each problem it printed as
   `resolved by <class>: <value>`.
4. **Record the reply:**

   ```bash
   sdlc-decision answer (--pr <ref> | --issue <ref>) --decision <n> \
     --pick P<i>=<option id>… --reply-file <path>
   ```

   with the reply written verbatim to a scratchpad file, `none` as the
   pick for a problem the reply answered in its own words, and no pick
   for one it did not address, which goes into the next turn's record.
