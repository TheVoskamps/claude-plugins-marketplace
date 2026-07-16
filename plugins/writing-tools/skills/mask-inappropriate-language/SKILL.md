---
name: mask-inappropriate-language
description: Replace inappropriate language (profanity, slurs, strong insults) in provided text or a file with asterisks, character-for-character, preserving everything else.
---

# mask-inappropriate-language

Mask inappropriate language in the text the user provides — either inline
text or the contents of a file — by replacing each offending word with
asterisks (`*`), **one asterisk per character** so the masked span is the
same length as the original. Everything that is not inappropriate is left
exactly as-is.

## Invocation forms

The skill accepts these argument forms:

- **Inline text** — everything after the skill name is the text to mask:

  ```text
  /mask-inappropriate-language <text to mask...>
  ```

- **A file** — read the file, mask its contents:

  ```text
  /mask-inappropriate-language --file <path>
  ```

  By default the masked result is **printed** and the file on disk is left
  untouched. To overwrite the file in place, add `--in-place`:

  ```text
  /mask-inappropriate-language --file <path> --in-place
  ```

- **No arguments** — ask the user what text or file they want masked, then
  proceed. Do not guess.

### Flags

- `--file <path>` — treat the argument as a path and mask the file's
  contents instead of inline text. The path is resolved relative to the
  current working directory. Confirm the path is inside the current repo
  before reading; if it is outside the repo, stop and report rather than
  reading arbitrary filesystem locations.
- `--in-place` — only meaningful with `--file`. Overwrite the file on disk
  with the masked contents instead of printing. There is deliberately **no
  short alias** for this flag (`-i` conventionally means "input" or
  "case-insensitive" in other tools, so it is not reused here). If
  `--in-place` is passed without `--file`, stop and tell the user it only
  applies to file input.

If an unrecognized flag is passed, stop and report it rather than silently
treating it as text to mask.

## What counts as "inappropriate"

Mask these categories:

1. **Profanity / vulgar terms** — swear words and crude/obscene terms.
2. **Slurs** — derogatory terms targeting a group (race, ethnicity,
   gender, sexuality, religion, disability, etc.).
3. **Strong insults** — demeaning or harassing terms directed at a person,
   even when they are not classic profanity.

Use judgment rather than a fixed word list, so that obfuscated spellings
(e.g. letters swapped for symbols, extra characters, leetspeak) and
context-dependent uses are still caught. Merely negative-but-clean words
(ordinary criticism, disagreement, or neutral vocabulary) are **not**
masked — only the three categories above.

When a term is genuinely ambiguous (a word that is offensive in one sense
and innocuous in another), prefer to mask it only when the surrounding
context makes the offensive reading clear. If you are unsure whether to
mask something, note it to the user rather than silently deciding.

## Masking rules

- **Character-for-character.** Replace each character of the offending word
  with a single `*`. A 4-letter word becomes `****`; a 7-letter word
  becomes `*******`. Do not use a fixed-length mask.
- **Mask letters/digits, preserve structure.** Replace the alphanumeric
  characters of the offending token with `*`. Leading/trailing and
  interior punctuation that is part of normal writing (spaces, commas,
  periods, quotes, hyphens joining separate words) stays in place so the
  text still reads naturally. Internal symbols used *as* letters in an
  obfuscated spelling are masked along with the rest of the token.
- **Preserve everything else exactly** — capitalization of surrounding
  words, whitespace, line breaks, Markdown/formatting, code, and all
  non-offending words are left byte-for-byte unchanged. Only the offending
  spans change.
- **Do not add or remove words.** The output is the input with offending
  spans replaced by equal-length asterisk runs — nothing else.

## Output

- For inline text and for `--file` without `--in-place`: print the fully
  masked text. If nothing was masked, say so and echo the text back
  unchanged.
- For `--file --in-place`: write the masked contents back to the file,
  then report how many spans were masked and confirm the file was
  overwritten. If nothing needed masking, leave the file untouched and say
  so rather than rewriting an identical file.

Briefly summarize what was masked (a count is enough — do **not** re-print
the offensive words themselves in the summary).
