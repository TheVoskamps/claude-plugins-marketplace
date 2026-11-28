#!/usr/bin/env bash
#
# config-keys-test.sh -- bin/claude-vm-config-keys prints the key table in
# lib/config.sh (CLAUDE_VM_CONFIG_KEYS), one key per line as the
# tab-separated fields key, file, type, shape, default, and the sets the merge
# and the placement gates use are the ones that table derives.
#
# The expected lines are built from the array itself rather than from a copy
# of it here, so the assertion is that the script prints the table, whatever
# the table holds. The derived sets are compared against the table the same
# way. Each script run happens under the bash on PATH and again under
# /bin/bash, the 3.2 a stock macOS resolves to, since the wizards run the
# script on whatever host they are on.
#
# No VM, no network, no yq; bash only.
#
# Run directly:
#
#   plugins/claude-vm/payload/test/config-keys-test.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/config.sh"
BIN="$TEST_DIR/../../bin/claude-vm-config-keys"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  echo "ok   - $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "        $2"
}

# shellcheck source=../lib/config.sh
. "$LIB"

SCRATCH="$(claude_vm_mktemp -d claude-vm-config-keys-test)"
EXPECTED="$SCRATCH/expected.tsv"
: >"$EXPECTED"
i=0
n="${#CLAUDE_VM_CONFIG_KEYS[@]}"
while [ "$i" -lt "$n" ]; do
  printf '%s\t%s\t%s\t%s\t%s\n' "${CLAUDE_VM_CONFIG_KEYS[$i]}" \
    "${CLAUDE_VM_CONFIG_KEYS[$((i + 1))]}" "${CLAUDE_VM_CONFIG_KEYS[$((i + 2))]}" \
    "${CLAUDE_VM_CONFIG_KEYS[$((i + 3))]}" "${CLAUDE_VM_CONFIG_KEYS[$((i + 4))]}" \
    >>"$EXPECTED"
  i=$((i + 5))
done

# ---------------------------------------------------------------------
# 1. The table itself is well-formed: whole rows, and every file and shape
#    value is one the fields admit.
# ---------------------------------------------------------------------
if [ $((n % 5)) -eq 0 ] && [ "$n" -gt 0 ]; then
  ok "the key table holds whole five-field rows ($((n / 5)) keys)"
else
  bad "the key table holds whole five-field rows" "$n elements"
fi
i=0
malformed=""
while [ "$i" -lt "$n" ]; do
  case "${CLAUDE_VM_CONFIG_KEYS[$((i + 1))]}" in
    bake | boot | both) : ;;
    *) malformed="$malformed ${CLAUDE_VM_CONFIG_KEYS[$i]}(file)" ;;
  esac
  case "${CLAUDE_VM_CONFIG_KEYS[$((i + 3))]}" in
    list | scalar) : ;;
    *) malformed="$malformed ${CLAUDE_VM_CONFIG_KEYS[$i]}(shape)" ;;
  esac
  i=$((i + 5))
done
if [ -z "$malformed" ]; then
  ok "every row's file is bake/boot/both and its shape list/scalar"
else
  bad "every row's file is bake/boot/both and its shape list/scalar" "$malformed"
fi

# ---------------------------------------------------------------------
# 2. The script prints exactly the table, under each bash.
# ---------------------------------------------------------------------
for shell in bash /bin/bash; do
  if ! command -v "$shell" >/dev/null 2>&1; then
    echo "skip - no $shell on this host"
    continue
  fi
  "$shell" "$BIN" >"$SCRATCH/actual.tsv" 2>"$SCRATCH/actual.err"
  rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$SCRATCH/actual.err" ]; then
    ok "$shell: claude-vm-config-keys exits 0 with no stderr"
  else
    bad "$shell: claude-vm-config-keys exits 0 with no stderr" "rc=$rc: $(head -3 "$SCRATCH/actual.err")"
  fi
  if cmp -s "$EXPECTED" "$SCRATCH/actual.tsv"; then
    ok "$shell: the output is the key table, one key per line, five tab-separated fields"
  else
    bad "$shell: the output is the key table, one key per line, five tab-separated fields" \
      "$(diff "$EXPECTED" "$SCRATCH/actual.tsv" | head -5)"
  fi
  "$shell" "$BIN" extra >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "$shell: an argument exits 2"
  else
    bad "$shell: an argument exits 2" "rc=$rc"
  fi
done

# Every line carries exactly four tabs, an empty default included.
tabs_off="$(awk -F'\t' 'NF != 5 { print NR": "$0 }' "$SCRATCH/actual.tsv")"
if [ -z "$tabs_off" ]; then
  ok "every line has exactly five fields, an empty default included"
else
  bad "every line has exactly five fields, an empty default included" "$tabs_off"
fi

# ---------------------------------------------------------------------
# 3. The sets the merge and the gates read are the table's.
# ---------------------------------------------------------------------
want="$(awk -F'\t' '$4 == "list" { print "." $1 }' "$EXPECTED")"
got="$(printf '%s\n' "${CLAUDE_VM_LIST_KEYS[@]}")"
if [ "$want" = "$got" ]; then
  ok "CLAUDE_VM_LIST_KEYS is every list-shaped row, in table order"
else
  bad "CLAUDE_VM_LIST_KEYS is every list-shaped row, in table order" "want [$want] got [$got]"
fi

check_subkeys() { # <label> <parent> <file> <array values...>
  local label="$1" parent="$2" file="$3" want got
  shift 3
  want="$(awk -F'\t' -v p="$parent." -v f="$file" '
    index($1, p) == 1 && $2 == f { s = substr($1, length(p) + 1); if (s !~ /\./) print s }
  ' "$EXPECTED")"
  got="$(printf '%s\n' "$@")"
  if [ "$want" = "$got" ]; then
    ok "$label is the table's $parent sub-keys with file $file"
  else
    bad "$label is the table's $parent sub-keys with file $file" "want [$want] got [$got]"
  fi
}
check_subkeys CLAUDE_VM_PLUGIN_BAKE_ONLY_KEYS claude.plugins bake "${CLAUDE_VM_PLUGIN_BAKE_ONLY_KEYS[@]}"
check_subkeys CLAUDE_VM_PLUGIN_BOOT_ONLY_KEYS claude.plugins boot "${CLAUDE_VM_PLUGIN_BOOT_ONLY_KEYS[@]}"
check_subkeys CLAUDE_VM_ENV_BOOT_ONLY_KEYS env boot "${CLAUDE_VM_ENV_BOOT_ONLY_KEYS[@]}"

# The scalar fallbacks the library applies are the table's defaults.
defaults_off=""
for pair in \
  update_at_boot:CLAUDE_VM_DEFAULT_PACKAGES_UPDATE_AT_BOOT \
  add_apt_uris_to_allowlist:CLAUDE_VM_DEFAULT_PACKAGES_ADD_APT_URIS_TO_ALLOWLIST \
  claude.permission_mode:CLAUDE_VM_DEFAULT_CLAUDE_PERMISSION_MODE \
  claude.plugins.update_at_boot:CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_UPDATE_AT_BOOT \
  claude.plugins.add_marketplace_uris_to_allowlist:CLAUDE_VM_DEFAULT_CLAUDE_PLUGINS_ADD_MARKETPLACE_URIS_TO_ALLOWLIST; do
  key="${pair%%:*}"
  var="${pair#*:}"
  want="$(awk -F'\t' -v k="$key" '$1 == k { print $5 }' "$EXPECTED")"
  eval "got=\${$var}"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    defaults_off="$defaults_off $var=[$got]/table=[$want]"
  fi
done
if [ -z "$defaults_off" ]; then
  ok "every CLAUDE_VM_DEFAULT_* fallback is its key's table default"
else
  bad "every CLAUDE_VM_DEFAULT_* fallback is its key's table default" "$defaults_off"
fi

rm -rf "$SCRATCH"

echo ""
echo "config-keys-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
