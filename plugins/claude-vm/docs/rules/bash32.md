# bash 3.2 in claude-vm

## Every script runs under bash 3.2

Every claude-vm script is `#!/usr/bin/env bash`, so the interpreter is
whatever `bash` PATH resolves to — on a stock macOS, `/bin/bash` 3.2. No
part of `lib/config.sh` needs bash 4, and the file is run end to end
under `/bin/bash`.

## A guard must not fail open

A construct that behaves differently on 3.2 is worst in a config-load
guard. The guard runs early and decides whether a mount or a key is
safe, so the construct does not stop the launch: it changes the answer
the guard gives. A guard must not fail open on the way to someone
else's error.

## A config-test failure is a defect, never a baseline

`test/config-test.sh` carries the same shebang and is under the same
rule, at a different cost: a 3.2-only construct in an assertion gives a
false FAIL on correct code, while the same construct in a guard ships a
hole. Say which a given failure is. `/bin/bash test/config-test.sh` is
green with no baselined failing set; a failure there is a defect to fix,
never a number to record.

## The shapes that have bitten

- **A backslash-escaped delimiter in the replacement half of
  `${var//pattern/replacement}`.** Bash 4.3 and later unescape `\/`; 3.2
  keeps the backslash, so `${path//\/\//\/}` returns `/mnt/repo\` on 3.2
  and every guard built on that normalization is defeated. Hold the
  literals in variables (`local sl=/ dbl=// dotseg=/./`).
- **`"${arr[@]}"` on an empty array under `set -u`.** 3.2 treats it as
  unbound and kills the shell. Write `${arr[@]+"${arr[@]}"}`.
- **A `case` inside `$( )`.** 3.2 ends the substitution at the pattern's
  `)`, returning a fragment of the source. Lift the `case` into a
  function and call that.
- **An associative array (`local -A`, `declare -A`).** 3.2 prints a
  diagnostic for the declaration and carries on, then evaluates every
  `map["$key"]=` subscript arithmetically: a numeric key writes the wrong
  slot and an identifier key, such as a plugin ref, dies under `set -u`.
  Use two parallel indexed arrays and a linear scan to the end, last
  match winning.
- **`$BASHPID`.** Absent on 3.2.

## Pinning a hazard

Pin a 3.2 hazard by running the real code under the host's pre-4 bash,
beside a negative control that runs the spelling the code avoids, so the
control stops differing if the hazard ever goes away. Drive a guard
through the real `claude_vm_merge_config` in the launcher's own argument
shape, over input that reaches the branch — a ref that leads with an
identifier, not a digits-only one. Assert an abort by its diagnostic,
not by a non-zero exit, since a bash-4 construct anywhere in the
function also exits non-zero on 3.2. On a host with no old bash, skip
the block rather than faking it. A parse-time hazard needs no assertion:
running the suite under `/bin/bash` is the check.
