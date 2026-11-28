# memory-record.jq -- render one memory-capture record as YAML, from the
# --arg values kind, source_path, tool, session_id, branch and captured_at
# and the --rawfile value content. Run with jq -n -j.

# The characters a literal block cannot carry: the ones YAML 1.2 calls
# non-printable, a carriage return, which YAML reads back as a line feed,
# and U+0085, U+2028 and U+2029, which YAML 1.1 does.
def unblockable: "[\\x{0}-\\x{8}\\x{b}-\\x{1f}\\x{7f}-\\x{9f}\\x{2028}\\x{2029}\\x{fffe}\\x{ffff}]";

def hex4:
  [(. / 4096 | floor) % 16, (. / 256 | floor) % 16, (. / 16 | floor) % 16, . % 16]
  | map("0123456789abcdef"[.:. + 1]) | add;

# A double-quoted scalar: a JSON string, whose escapes YAML reads the same,
# with the characters of unblockable that JSON leaves raw escaped as \uXXXX
# too, since YAML 1.2 refuses them raw or YAML 1.1 folds them away.
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

# A literal block scalar, or a double-quoted scalar for content holding a
# character a literal block cannot carry. The chomping indicator keeps the
# trailing newlines exactly: strip for none, clip for one, keep for more or
# for a value of newlines alone. The indentation indicator is explicit when
# the first line is blank or opens with a space, either of which defeats
# YAML's indentation detection.
def block:
  if . == "" or test(unblockable) then quoted + "\n"
  else
    (if endswith("\n") and (.[:-1] | test("^\n*$")) then "+"
     elif endswith("\n\n") then "+"
     elif endswith("\n") then ""
     else "-"
     end) as $chomp
    | (if test("^[ \t]*(\n|$)") or startswith(" ") then "2" else "" end) as $indent
    | (if endswith("\n") then .[:-1] else . end)
    | "|" + $indent + $chomp + "\n"
      + (split("\n") | map(if . == "" then "" else "  " + . end) | join("\n"))
      + "\n"
  end;

"kind: " + ($kind | scalar) + "\n"
+ "source-path: " + ($source_path | scalar) + "\n"
+ "tool: " + ($tool | scalar) + "\n"
+ "session-id: " + ($session_id | scalar) + "\n"
+ "branch: " + ($branch | scalar) + "\n"
+ "captured-at: " + ($captured_at | scalar) + "\n"
+ "content: " + ($content | block)
