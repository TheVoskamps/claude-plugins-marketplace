# writing-tools

Writing and text-editing helpers for Claude Code, packaged as skills. The
plugin is a home for small, focused prose/text utilities; it currently
ships one skill, with room to grow.

## Skills

- **`mask-inappropriate-language`** — replace inappropriate language
  (profanity, slurs, strong insults) in provided text or a file with
  asterisks, **character-for-character**, leaving everything else
  unchanged.

## `/mask-inappropriate-language`

Mask inappropriate language in the text the user provides — either inline
text or the contents of a file — by replacing each offending word with a
run of asterisks the same length as the original word. Everything that is
not inappropriate is left exactly as-is.

### Invocation

```text
# Mask inline text (prints the masked result)
/mask-inappropriate-language <text to mask...>

# Mask a file's contents (prints the masked result; file untouched)
/mask-inappropriate-language --file <path>

# Mask a file and overwrite it on disk
/mask-inappropriate-language --file <path> --in-place

# No arguments: the skill asks what to mask
/mask-inappropriate-language
```

### Flags

- `--file <path>` — mask the contents of a file instead of inline text.
  The path is resolved relative to the current working directory and must
  be inside the current repo; a path outside the repo stops with a report
  rather than reading arbitrary filesystem locations.
- `--in-place` — only meaningful with `--file`. Overwrite the file on disk
  with the masked contents instead of printing. There is deliberately
  **no `-i` short alias**, because `-i` conventionally means "input" or
  "case-insensitive" in other tools; passing `--in-place` without
  `--file` is an error.

An unrecognized flag stops with a report rather than being silently
treated as text to mask.

## What counts as "inappropriate"

Three categories are masked:

1. **Profanity / vulgar terms** — swear words and crude/obscene terms.
2. **Slurs** — derogatory terms targeting a group.
3. **Strong insults** — demeaning or harassing terms directed at a
   person, even when they are not classic profanity.

The skill uses judgment rather than a fixed word list, so obfuscated
spellings (symbol substitutions, extra characters, leetspeak) and
context-dependent uses are still caught. Ordinary clean-but-negative
words (plain criticism or disagreement) are **not** masked. Genuinely
ambiguous terms are masked only when the context makes the offensive
reading clear, and flagged to the user when unsure.

## How the masking works

- **Character-for-character.** Each character of an offending word becomes
  a single `*`, so the masked span is the same length as the original: a
  4-letter word becomes `****`, a 7-letter word becomes `*******`.
- **Structure preserved.** Surrounding whitespace, punctuation,
  capitalization of other words, line breaks, Markdown/formatting, and
  every non-offending word are left byte-for-byte unchanged. Only the
  offending spans change.
- **No add/remove.** The output is the input with offending spans replaced
  by equal-length asterisk runs — nothing added, nothing dropped.

The run summary reports how many spans were masked without re-printing the
offensive words themselves.

## Scope

This plugin covers text/writing helpers only. It does not touch git,
issues, GitHub setup, or the harness — those live in their own plugins in
this marketplace.
