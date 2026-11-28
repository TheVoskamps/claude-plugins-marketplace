# memory-record.jq -- render one memory-capture record as YAML, from the
# --arg values kind, source_path, tool, session_id, branch and captured_at
# and the --rawfile value content. Run with jq -n -j.

# A scalar is written plain when YAML reads it back as the same string, and
# as a JSON string, which YAML reads as a double-quoted scalar, otherwise:
# the empty string among them.
def scalar:
  if test("^[A-Za-z0-9_./~+-][A-Za-z0-9_./~@+=:-]*$")
    and (test(":$") | not)
    and (test("^(true|false|null|yes|no|on|off|y|n|~|[-+.0-9]+)$"; "i") | not)
  then .
  else tojson
  end;

# A literal block scalar. The chomping indicator keeps the trailing newlines
# exactly: strip for none, clip for one, keep for more or for a value of
# newlines alone. The indentation indicator is explicit when the first line
# is blank or opens with a space, either of which defeats YAML's indentation
# detection.
def block:
  if . == "" then "\"\""
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
