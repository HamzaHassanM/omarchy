#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
export HOME="$test_dir/home" TEST_LOG="$test_dir/log" OMARCHY_PATH="$ROOT"
mkdir -p "$HOME" "$test_dir/bin"
export PATH="$test_dir/bin:$ROOT/bin:$PATH"
: > "$TEST_LOG"

# Relocate system-owned entrypoints into the fixture; never run the host CLI.
sed -e "s|/usr/lib/openclaw/bootstrap|$test_dir/bootstrap|g" \
  -e "s|/usr/bin/openclaw|$test_dir/bin/openclaw|g" \
  "$ROOT/bin/omarchy-install-openclaw-cli" > "$test_dir/bin/omarchy-install-openclaw-cli"
cat > "$test_dir/bootstrap-source" <<'STUB'
#!/bin/bash
printf 'bootstrap:%s\n' "$*" >> "$TEST_LOG"
case "$1" in
--check) [[ -f $HOME/ready ]] ;;
--prefix) echo "$HOME/.local/share/openclaw/runtime" ;;
--install) [[ ${TEST_INSTALL_FAIL:-0} == 0 ]] || exit 7; touch "$HOME/ready" ;;
esac
STUB
cat > "$test_dir/bin/omarchy-pkg-add" <<STUB
#!/bin/bash
printf 'pkg-add:%s\n' "\$*" >> "\$TEST_LOG"
[[ \${TEST_OLD_PACKAGE:-0} == 0 ]] || exit 0
cp "$test_dir/bootstrap-source" "$test_dir/bootstrap"
chmod +x "$test_dir/bootstrap"
STUB
cat > "$test_dir/bin/omarchy-pkg-present" <<'STUB'
#!/bin/bash
[[ ${TEST_PACKAGE_PRESENT:-1} == 1 ]]
STUB
cat > "$test_dir/bin/openclaw" <<'STUB'
#!/bin/bash
printf 'openclaw:%s\n' "$*" >> "$TEST_LOG"
if [[ $* == 'gateway install --force' ]]; then
  sed -i "s|/usr/lib/node_modules/openclaw|$HOME/.local/share/openclaw/runtime/lib/node_modules/openclaw|g" "$HOME/.config/systemd/user/openclaw-gateway.service"
elif [[ $* == 'gateway status --json' ]]; then
  jq -n --arg entry "$HOME/.local/share/openclaw/runtime/lib/node_modules/openclaw/dist/index.js" \
    --argjson ready "${TEST_GATEWAY_READY:-true}" \
    '{rpc:{ok:$ready},service:{command:{programArguments:["node",$entry,"gateway"]}}}' 
fi
STUB
cat > "$test_dir/bin/mise" <<'STUB'
#!/bin/bash
printf 'mise:%s\n' "$*" >> "$TEST_LOG"
STUB
cat > "$test_dir/bin/systemctl" <<'STUB'
#!/bin/bash
printf 'systemctl:%s\n' "$*" >> "$TEST_LOG"
[[ ${TEST_MANAGER_UNAVAILABLE:-false} != true ]] || exit 1
case "$*" in
  *is-enabled*)
    if [[ -n ${TEST_ENABLED_STATE:-} ]]; then echo "$TEST_ENABLED_STATE"
    else [[ ${TEST_SERVICE_RUNNING:-true} == true ]] && echo enabled || echo disabled; fi ;;
  *is-active*)
    if [[ -n ${TEST_ACTIVE_STATE:-} ]]; then echo "$TEST_ACTIVE_STATE"
    else [[ ${TEST_SERVICE_RUNNING:-true} == true ]] && echo active || echo inactive; fi ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$test_dir/bin/sleep"
chmod +x "$test_dir/bin/"*

if omarchy-install-openclaw-cli --check; then fail "cold bootstrap is not a ready runtime"; fi
omarchy-install-openclaw-cli --now >/dev/null
omarchy-install-openclaw-cli --check || fail "setup makes runtime ready"
grep -qx 'pkg-add:openclaw' "$TEST_LOG" || fail "setup installs launcher package"
grep -qx 'bootstrap:--install' "$TEST_LOG" || fail "setup provisions the user runtime"
pass "fresh setup installs package and provisions user runtime"

: > "$TEST_LOG"
omarchy-install-openclaw-cli --now
! grep -q '^pkg-add:' "$TEST_LOG" || fail "ready bootstrap is not reinstalled"
pass "existing bootstrap is reused"

if TEST_INSTALL_FAIL=1 omarchy-install-openclaw-cli --now; then fail "bootstrap failure aborts setup"; fi
pass "bootstrap failure propagates"

unit="$HOME/.config/systemd/user/openclaw-gateway.service"
mkdir -p "$(dirname "$unit")"
cat > "$unit" <<'UNIT'
[Service]
ExecStart=/usr/bin/node --max-old-space-size=2048 /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789
Environment=OPENCLAW_SERVICE_KIND=gateway
UNIT
: > "$TEST_LOG"
omarchy-install-openclaw-cli --migrate
sed -n '/^openclaw:/p' "$TEST_LOG" > "$test_dir/actual"
printf '%s\n' 'openclaw:gateway install --force' 'openclaw:gateway status --json' > "$test_dir/expected"
cmp "$test_dir/actual" "$test_dir/expected" || fail "migration rebinds and verifies legacy gateway"
pass "legacy gateway is rebound and verified"
grep -E '^(systemctl:--user stop|openclaw:gateway install)' "$TEST_LOG" > "$test_dir/stop-order"
printf '%s\n' 'systemctl:--user stop openclaw-gateway.service' 'openclaw:gateway install --force' > "$test_dir/expected-stop-order"
cmp "$test_dir/stop-order" "$test_dir/expected-stop-order" || fail "legacy Gateway releases state before new CLI starts"
pass "legacy Gateway is stopped before state migration"

sed -i "s|$HOME/.local/share/openclaw/runtime/lib/node_modules/openclaw|/usr/lib/node_modules/openclaw|g" "$unit"
: > "$TEST_LOG"
if TEST_GATEWAY_READY=false omarchy-install-openclaw-cli --migrate >/dev/null 2>&1; then fail "failed Gateway readiness leaves migration pending"; fi
[[ -f $HOME/.local/state/omarchy/openclaw-runtime-migration ]] || fail "retry marker survives failed readiness"
! grep -q '/usr/lib/node_modules/openclaw' "$unit" || fail "failure fixture rewrites legacy entrypoint"
: > "$TEST_LOG"
if TEST_GATEWAY_READY=false omarchy-install-openclaw-cli --migrate >/dev/null 2>&1; then fail "retry still verifies rewritten Gateway"; fi
grep -qx 'openclaw:gateway status --json' "$TEST_LOG" || fail "retry probes actual Gateway"
omarchy-install-openclaw-cli --migrate
[[ ! -e $HOME/.local/state/omarchy/openclaw-runtime-migration ]] || fail "successful retry clears marker"
pass "readiness failures stay pending after the legacy unit is rewritten"

sed -i "s|$HOME/.local/share/openclaw/runtime/lib/node_modules/openclaw|/usr/lib/node_modules/openclaw|g" "$unit"
if TEST_MANAGER_UNAVAILABLE=true omarchy-install-openclaw-cli --migrate >/dev/null 2>&1; then fail "unavailable manager cannot be interpreted as disabled"; fi
[[ ! -e $HOME/.local/state/omarchy/openclaw-runtime-migration ]] || fail "unknown service state is not persisted"
pass "unavailable user manager leaves desired service state untouched"

: > "$TEST_LOG"
TEST_SERVICE_RUNNING=false TEST_GATEWAY_READY=false omarchy-install-openclaw-cli --migrate
grep -qx 'systemctl:--user disable openclaw-gateway.service' "$TEST_LOG" || fail "disabled service stays disabled"
grep -qx 'systemctl:--user stop openclaw-gateway.service' "$TEST_LOG" || fail "stopped service stays stopped"
pass "migration preserves disabled and stopped service state"

sed -i "s|$HOME/.local/share/openclaw/runtime/lib/node_modules/openclaw|/usr/lib/node_modules/openclaw|g" "$unit"
: > "$TEST_LOG"
if TEST_ACTIVE_STATE=failed TEST_GATEWAY_READY=false omarchy-install-openclaw-cli --migrate >/dev/null 2>&1; then fail "enabled failed service requires health recovery"; fi
grep -qx 'true true' "$HOME/.local/state/omarchy/openclaw-runtime-migration" || fail "enabled failed service is intended to run"
[[ $(grep -cx 'systemctl:--user stop openclaw-gateway.service' "$TEST_LOG") == 1 ]] || fail "enabled failed service must not be stopped after repair"
omarchy-install-openclaw-cli --migrate
pass "enabled failed Gateway is recovered and health checked"

sed -i "s|$HOME/.local/share/openclaw/runtime/lib/node_modules/openclaw|/usr/lib/node_modules/openclaw|g" "$unit"
: > "$TEST_LOG"
TEST_ENABLED_STATE=disabled TEST_ACTIVE_STATE=failed TEST_GATEWAY_READY=false omarchy-install-openclaw-cli --migrate
grep -qx 'systemctl:--user stop openclaw-gateway.service' "$TEST_LOG" || fail "disabled failed service remains stopped"
pass "disabled failed Gateway remains stopped"

sed -i "s|$HOME/.local/share/openclaw/runtime/lib/node_modules/openclaw|/usr/lib/node_modules/openclaw|g" "$unit"
sed -i '/OPENCLAW_SERVICE_KIND/d' "$unit"
cp "$unit" "$test_dir/custom-unit"
: > "$TEST_LOG"
if omarchy-install-openclaw-cli --migrate 2>/dev/null; then fail "custom legacy service requires manual migration"; fi
cmp "$unit" "$test_dir/custom-unit" || fail "custom legacy service preserved"
! grep -q '^openclaw:' "$TEST_LOG" || fail "custom legacy service is not reinstalled"
pass "custom legacy service preserved"

: > "$TEST_LOG"
TEST_PACKAGE_PRESENT=0 omarchy-install-openclaw-cli --migrate
[[ ! -s $TEST_LOG ]] || fail "migration ignores users without package"
pass "migration ignores noninstallations"

rm "$test_dir/bootstrap"
if TEST_OLD_PACKAGE=1 omarchy-install-openclaw-cli --now > "$test_dir/old-output" 2>&1; then fail "old package cannot satisfy bootstrap contract"; fi
grep -q 'bootstrap package is required' "$test_dir/old-output" || fail "old package has clear upgrade instruction"
pass "package release gate fails clearly"

mkdir -p "$HOME/.local/share/openclaw/runtime"
touch "$HOME/.local/share/openclaw/runtime/.omarchy-managed"
: > "$TEST_LOG"
"$ROOT/bin/omarchy-remove-dev-env" node > "$test_dir/remove-output" 2>&1
printf '%s\n' 'mise:uninstall node --all' 'mise:rm -g node' > "$test_dir/expected-node-removal"
cmp "$TEST_LOG" "$test_dir/expected-node-removal" || fail "development Node removal only removes mise's Node"
[[ -f $HOME/.local/share/openclaw/runtime/.omarchy-managed ]] || fail "development Node removal preserves OpenClaw"
pass "development Node can be removed independently of OpenClaw"
