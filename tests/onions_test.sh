#!/usr/bin/env bash
# Tests for bin/onions. Requires bash >= 4.4 and base64.
set -uo pipefail

ONIONS="$(cd "$(dirname "$0")/.." && pwd)/bin/onions"
KEY_V3='PT0gZWQyNTUxOXYxLXNlY3JldDogdHlwZTAgPT0AAACArobDQYyZAWXei4QZwr++j96H1X/gq14N
wLRZ2O5DXuL0EzYKkdhZSILY85q+kfwZH8z4ceqe7u1F+0pQi/sM'
ONION_V3='xwjtp3mj427zdp4tljiiivg2l5ijfvmt5lcsfaygtpp6cw254kykvpyd.onion'

failures=0
tests=0
TMP=

setup() {
    TMP=$(mktemp -d)
    mkdir -p "$TMP/hs" "$TMP/secrets"
    : >"$TMP/hosts"
    cat >"$TMP/fake-tor" <<'EOF'
#!/bin/sh
echo "16:FAKEHASH"
EOF
    chmod +x "$TMP/fake-tor"
}

teardown() { rm -rf "$TMP"; }

# run_onions [VAR=value...] -- [onions args...]
run_onions() {
    local -a vars=()
    while (($#)) && [[ $1 != -- ]]; do
        vars+=("$1")
        shift
    done
    shift
    env -i PATH="$PATH" \
        HIDDEN_SERVICE_DIR="$TMP/hs" \
        ONIONS_TORRC="$TMP/torrc" \
        ONIONS_SECRETS_DIR="$TMP/secrets" \
        ONIONS_HOSTS_FILE="$TMP/hosts" \
        ONIONS_TOR_BIN="$TMP/fake-tor" \
        "${vars[@]}" bash "$ONIONS" "$@"
}

fail() {
    printf '    FAIL: %s\n' "$*"
    failed=1
}

assert_contains() { grep -qxF -- "$2" <<<"$1" || fail "missing line '$2'"; }
assert_not_contains() { ! grep -qF -- "$2" <<<"$1" || fail "unexpected '$2'"; }
assert_count() {
    local n
    n=$(grep -cxF -- "$2" <<<"$1")
    ((n == $3)) || fail "expected $3 x '$2', got $n"
}
assert_eq() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }

run_test() {
    local name=$1
    failed=0
    tests=$((tests + 1))
    setup
    "$name"
    teardown
    if ((failed)); then
        failures=$((failures + 1))
        printf 'FAIL %s\n' "$name"
    else
        printf 'ok   %s\n' "$name"
    fi
}

test_ports() {
    run_onions SERVICE1_PORTS=80:80 SERVICE2_PORTS=80:80,81:8000 \
        SERVICE3_PORTS=80:unix://unix.socket -- --setup-hosts || fail "setup failed"
    local torrc
    torrc=$(cat "$TMP/torrc")
    assert_contains "$torrc" "HiddenServiceDir $TMP/hs/service1"
    assert_contains "$torrc" "HiddenServicePort 80 service1:80"
    assert_contains "$torrc" "HiddenServicePort 80 service2:80"
    assert_contains "$torrc" "HiddenServicePort 81 service2:8000"
    assert_contains "$torrc" "HiddenServicePort 80 unix://unix.socket"
    assert_count "$torrc" "HiddenServiceVersion 3" 3
    assert_contains "$torrc" "SocksPort 0"
    assert_contains "$torrc" "ExitRelay 0"
    assert_not_contains "$torrc" "ControlPort"
}

test_docker_links() {
    cat >"$TMP/hosts" <<'EOF'
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
172.17.0.2	service1 bf447f22cdba compose_service1_1
172.17.0.2	service1_1 bf447f22cdba compose_service1_1
172.17.0.2	compose_service1_1 bf447f22cdba
EOF
    run_onions \
        COMPOSE_SERVICE1_1_PORT_80_TCP=tcp://172.17.0.2:80 \
        COMPOSE_SERVICE1_1_NAME=/compose_env_1/compose_service1_1 \
        SERVICE1_PORT=tcp://172.17.0.2:80 \
        SERVICE1_PORT_80_TCP=tcp://172.17.0.2:80 \
        SERVICE1_PORT_80_TCP_ADDR=172.17.0.2 \
        SERVICE1_PORT_8000_TCP=tcp://172.17.0.2:8000 \
        SERVICE1_PORT_8000_TCP_ADDR=172.17.0.2 \
        SERVICE1_NAME=/compose_env_1/service1 \
        SERVICE1_1_NAME=/compose_env_1/service1_1 \
        -- --setup-hosts || fail "setup failed"
    local torrc
    torrc=$(cat "$TMP/torrc")
    assert_count "$torrc" "HiddenServiceVersion 3" 1
    assert_contains "$torrc" "HiddenServiceDir $TMP/hs/service1"
    assert_contains "$torrc" "HiddenServicePort 80 service1:80"
    assert_contains "$torrc" "HiddenServicePort 8000 service1:8000"
}

test_key_v3() {
    run_onions GROUP1_TOR_SERVICE_HOSTS=80:service1:80,81:service2:80 \
        GROUP1_TOR_SERVICE_VERSION=3 "GROUP1_TOR_SERVICE_KEY=$KEY_V3" \
        -- --setup-hosts || fail "setup failed"
    local key="$TMP/hs/group1/hs_ed25519_secret_key"
    [[ -f $key ]] || fail "key not written"
    cmp -s "$key" <(tr -d '\n' <<<"$KEY_V3" | base64 -d) || fail "key content differs"
    assert_eq "$(stat -c %a "$key")" 600
    assert_eq "$(stat -c %a "$TMP/hs/group1")" 700
}

test_env_key_overrides_disk_and_drops_stale_hostname() {
    mkdir -p "$TMP/hs/group1"
    echo stale >"$TMP/hs/group1/hs_ed25519_secret_key"
    echo stale.onion >"$TMP/hs/group1/hostname"
    run_onions GROUP1_TOR_SERVICE_HOSTS=80:service1:80 "GROUP1_TOR_SERVICE_KEY=$KEY_V3" \
        -- --setup-hosts || fail "setup failed"
    cmp -s "$TMP/hs/group1/hs_ed25519_secret_key" <(tr -d '\n' <<<"$KEY_V3" | base64 -d) ||
        fail "env key did not override disk key"
    [[ ! -e $TMP/hs/group1/hostname ]] || fail "stale hostname kept"
}

test_invalid_key_is_rejected() {
    local out
    out=$(run_onions GROUP1_TOR_SERVICE_HOSTS=80:service1:80 \
        GROUP1_TOR_SERVICE_KEY=aGVsbG8K -- --setup-hosts 2>&1)
    assert_contains "$(grep -o 'not seem to be a valid ed25519 tor key' <<<"$out")" \
        "not seem to be a valid ed25519 tor key"
    [[ ! -e $TMP/hs/group1/hs_ed25519_secret_key ]] || fail "invalid key written"
}

test_key_in_secret() {
    tr -d '\n' <<<"$KEY_V3" | base64 -d >"$TMP/secrets/group3"
    run_onions GROUP2_TOR_SERVICE_HOSTS=80:service2:80 \
        GROUP3_TOR_SERVICE_HOSTS=80:service3:80 GROUP3_TOR_SERVICE_VERSION=3 \
        -- --setup-hosts || fail "setup failed"
    [[ ! -e $TMP/hs/group2/hs_ed25519_secret_key ]] || fail "group2 should let tor generate a key"
    cmp -s "$TMP/hs/group3/hs_ed25519_secret_key" "$TMP/secrets/group3" || fail "secret not installed"
}

test_disk_key_wins_over_secret() {
    tr -d '\n' <<<"$KEY_V3" | base64 -d >"$TMP/secrets/group3"
    mkdir -p "$TMP/hs/group3"
    echo existing >"$TMP/hs/group3/hs_ed25519_secret_key"
    run_onions GROUP3_TOR_SERVICE_HOSTS=80:service3:80 -- --setup-hosts || fail "setup failed"
    assert_eq "$(cat "$TMP/hs/group3/hs_ed25519_secret_key")" existing
}

test_configuration() {
    local extra=$'HiddenServiceNonAnonymousMode 1\nHiddenServiceSingleHopMode 1'
    run_onions \
        SERVICE1_SERVICE_NAME=group1 SERVICE2_SERVICE_NAME=group1 SERVICE3_SERVICE_NAME=group2 \
        SERVICE1_PORTS=80:80 SERVICE2_PORTS=81:80,82:8000 SERVICE3_PORTS=80:unix://unix.socket \
        GROUP3_TOR_SERVICE_HOSTS=80:service4:888,81:service5:8080 \
        GROUP4_TOR_SERVICE_VERSION=3 GROUP4_TOR_SERVICE_HOSTS=81:unix://unix2.sock \
        GROUP3V3_TOR_SERVICE_VERSION=3 GROUP3V3_TOR_SERVICE_HOSTS=80:service4:888,81:service5:8080 \
        SERVICE5_TOR_SERVICE_HOSTS=80:service5:80 \
        "TOR_EXTRA_OPTIONS=$extra" \
        -- --setup-hosts || fail "setup failed"
    local torrc g
    torrc=$(cat "$TMP/torrc")
    for g in group1 group2 group3 group4 group3v3 service5; do
        assert_contains "$torrc" "HiddenServiceDir $TMP/hs/$g"
        [[ -d $TMP/hs/$g ]] || fail "$TMP/hs/$g not created"
    done
    assert_contains "$torrc" "HiddenServicePort 80 service1:80"
    assert_contains "$torrc" "HiddenServicePort 81 service2:80"
    assert_contains "$torrc" "HiddenServicePort 82 service2:8000"
    assert_contains "$torrc" "HiddenServicePort 80 unix://unix.socket"
    assert_count "$torrc" "HiddenServicePort 80 service4:888" 2
    assert_count "$torrc" "HiddenServicePort 81 service5:8080" 2
    assert_count "$torrc" "HiddenServicePort 80 service5:80" 1
    assert_count "$torrc" "HiddenServicePort 81 unix://unix2.sock" 1
    assert_count "$torrc" "HiddenServiceVersion 3" 6
    assert_contains "$torrc" "HiddenServiceNonAnonymousMode 1"
    assert_contains "$torrc" "HiddenServiceSingleHopMode 1"
    assert_not_contains "$torrc" "ControlPort"
}

test_control_port_ip() {
    run_onions TOR_CONTROL_PORT=172.0.1.0:7867 TOR_CONTROL_PASSWORD=secret \
        -- --setup-hosts || fail "setup failed"
    local torrc
    torrc=$(cat "$TMP/torrc")
    assert_contains "$torrc" "ControlPort 172.0.1.0:7867"
    assert_contains "$torrc" "HashedControlPassword 16:FAKEHASH"
}

test_control_port_default_port_and_ipv6() {
    run_onions TOR_CONTROL_PORT=172.16.111.10 -- --setup-hosts || fail "setup failed"
    assert_contains "$(cat "$TMP/torrc")" "ControlPort 172.16.111.10:9051"
    run_onions 'TOR_CONTROL_PORT=[::1]:9999' -- --setup-hosts || fail "setup failed"
    assert_contains "$(cat "$TMP/torrc")" "ControlPort [::1]:9999"
}

test_control_port_unix() {
    run_onions TOR_CONTROL_PORT=unix:/path/to.socket -- --setup-hosts || fail "setup failed"
    assert_contains "$(cat "$TMP/torrc")" "ControlPort unix:/path/to.socket"
}

test_control_port_invalid_fails() {
    if run_onions TOR_CONTROL_PORT=not-an-ip:9051 -- --setup-hosts 2>/dev/null; then
        fail "setup should fail"
    fi
    [[ ! -e $TMP/torrc ]] || fail "torrc should not be written"
}

test_socks_and_exit_relay() {
    run_onions TOR_SOCKS_PORT=0.0.0.0:9050 TOR_EXIT_RELAY=true -- --setup-hosts || fail "setup failed"
    local torrc
    torrc=$(cat "$TMP/torrc")
    assert_contains "$torrc" "SocksPort 0.0.0.0:9050"
    assert_contains "$torrc" "ExitRelay 1"
}

test_not_valid_share_port() {
    local out
    out=$(run_onions SERVICE1_SERVICE_NAME=group1 SERVICE2_SERVICE_NAME=group1 \
        SERVICE3_SERVICE_NAME=group2 SERVICE1_PORTS=80:80 SERVICE2_PORTS=80:80,82:8000 \
        SERVICE3_PORTS=80:unix://unix.socket -- --setup-hosts 2>&1)
    grep -q "Same port for multiple services in group1 group" <<<"$out" || fail "no error: $out"
    assert_not_contains "$(cat "$TMP/torrc")" "hs/group1"
    assert_contains "$(cat "$TMP/torrc")" "HiddenServiceDir $TMP/hs/group2"
}

test_not_valid_no_ports() {
    local out
    out=$(run_onions SERVICE1_SERVICE_NAME=group1 -- --setup-hosts 2>&1)
    grep -q "Service service1 has not ports set" <<<"$out" || fail "no error: $out"
    assert_not_contains "$(cat "$TMP/torrc")" "HiddenServiceDir"
}

test_socket_with_other_services() {
    local out
    out=$(run_onions 'G_TOR_SERVICE_HOSTS=80:unix:/s.sock,81:web:80' -- --setup-hosts 2>&1)
    grep -q "Cannot use socket and ports" <<<"$out" || fail "no error: $out"
}

test_unsupported_version() {
    local out
    out=$(run_onions G_TOR_SERVICE_VERSION=2 -- --setup-hosts 2>&1)
    grep -q "Url version 2 is not supported" <<<"$out" || fail "no error: $out"
}

test_output_and_json() {
    run_onions SERVICE1_SERVICE_NAME=group1 SERVICE2_SERVICE_NAME=group1 \
        SERVICE3_SERVICE_NAME=group2 SERVICE1_PORTS=80:80 SERVICE2_PORTS=81:80,82:8000 \
        SERVICE3_PORTS=80:unix://unix.socket -- --setup-hosts || fail "setup failed"
    echo "$ONION_V3" >"$TMP/hs/group1/hostname"
    echo "group2onion.onion" >"$TMP/hs/group2/hostname"

    local out
    out=$(run_onions -- 2>&1)
    assert_contains "$out" "group1: $ONION_V3:80, $ONION_V3:81, $ONION_V3:82"
    assert_contains "$out" "group2: group2onion.onion:80"

    out=$(run_onions -- --json)
    assert_eq "$out" "{\"group1\": [\"$ONION_V3:80\", \"$ONION_V3:81\", \"$ONION_V3:82\"], \"group2\": [\"group2onion.onion:80\"]}"
}

test_output_before_tor_started() {
    run_onions A_TOR_SERVICE_HOSTS=80:a:80 -- --setup-hosts || fail "setup failed"
    assert_contains "$(run_onions --)" "a: onion address not generated yet (is tor running?)"
    assert_eq "$(run_onions -- --json)" '{"a": []}'
}

test_no_onion_site() {
    assert_eq "$(run_onions --)" "No onion site"
    assert_eq "$(run_onions -- --json)" "{}"
}

for t in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    run_test "$t"
done

printf '\n%d tests, %d failures\n' "$tests" "$failures"
((failures == 0))
