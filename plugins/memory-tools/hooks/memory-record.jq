# memory-record.jq -- render one memory-capture record as YAML, from the
# --arg values kind, source_path, tool, session_id, branch and captured_at
# and the --rawfile value content. Run with jq -n -j.

# The four lowercase hex digits of a code point below U+10000.
def hex4:
  [(. / 4096 | floor) % 16, (. / 256 | floor) % 16, (. / 16 | floor) % 16, . % 16]
  | map("0123456789abcdef"[.:. + 1]) | add;

# A double-quoted scalar: a JSON string, whose escapes YAML reads the same,
# with the C1 controls, U+2028, U+2029, U+FFFE and U+FFFF, which JSON leaves
# raw, escaped as \uXXXX too, since YAML 1.2 refuses some of them raw and
# YAML 1.1 folds the line breaks among them away.
def quoted:
  tojson
  | gsub("(?<c>[\\x{80}-\\x{9f}\\x{2028}\\x{2029}\\x{fffe}\\x{ffff}])"; "\\u" + (.c | explode[0] | hex4));

# A scalar is written plain when YAML 1.1 and 1.2 both read it back as the
# same string, and double-quoted otherwise: the empty string among them, and
# every value opening with a digit, ".", "+" or "-", the openings of every
# YAML number, timestamp, infinity and not-a-number.
def scalar:
  if test("^[A-Za-z_/~][A-Za-z0-9_./~@+=:-]*$")
    and (test(":$") | not)
    and (test("^(true|false|null|yes|no|on|off|y|n|~)$"; "i") | not)
  then .
  else quoted
  end;

"kind: " + ($kind | scalar) + "\n"
+ "source-path: " + ($source_path | scalar) + "\n"
+ "tool: " + ($tool | scalar) + "\n"
+ "session-id: " + ($session_id | scalar) + "\n"
+ "branch: " + ($branch | scalar) + "\n"
+ "captured-at: " + ($captured_at | scalar) + "\n"
+ "content: " + ($content | quoted) + "\n"
