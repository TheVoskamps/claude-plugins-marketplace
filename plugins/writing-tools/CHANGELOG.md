# writing-tools changelog

## 0.1.0 — 2026-07-16

Adds the plugin with its first skill, `/mask-inappropriate-language`.

The skill replaces profanity, slurs and strong insults with asterisks,
character for character, so a masked word keeps its length and all other
text stays byte-for-byte unchanged.

- Pass inline text, or `--file <path>`, and it prints the masked result.
- Add `--in-place` to `--file` to overwrite the file. There is
  deliberately no `-i` alias.
- With no arguments, it asks what to mask.
