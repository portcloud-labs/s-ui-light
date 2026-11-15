#!/bin/sh
set -eu
_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -f "$_ROOT/install.sh" ]; then _SCRIPT="$_ROOT/install.sh"; else _SCRIPT="$_ROOT/scripts/install.sh"; fi
SUI_LIB_ONLY=1
export SUI_LIB_ONLY
. "$_SCRIPT"
_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT HUP INT TERM
INSTALL_DIR="$_TMP"
PUBLIC_IPS_READY=true
PUBLIC_IPV4=''
PUBLIC_IPV6=2606:4700:4700::1111
ensure_session() { return 0; }
lookup_node_label() { NODE_LABEL='🇺🇸美国节点'; }
panel_request() {
    case "$2" in
        settings) printf '%s' '{"success":true,"obj":{}}' ;;
        *) printf '%s' '{"success":true,"obj":{"inbounds":[{"id":1,"type":"hysteria2","tag":"hysteria2-23456","listen_port":23456,"addrs":[]},{"id":2,"type":"vless","tag":"vless-reality-443","listen_port":443,"addrs":[]},{"id":3,"type":"hysteria2","tag":"hysteria2-34567","listen_port":34567,"addrs":[]}]}}' ;;
    esac
}
panel_save() {
    if [ "$1" = inbounds ]; then
        _test_id=$(printf '%s' "$3" | jq -r .id)
        printf '%s' "$3" > "$_TMP/inbound-$_test_id"
    elif [ "$1" = clients ]; then
        printf '%s' "$3" | jq -e '.remark == "" and .inbounds == [1,2,3]' >/dev/null || return 1
    fi
    printf '%s' '{"success":true}'
}
HY2_TAG=hysteria2-34567
VLESS_TAG=vless-reality-443
create_subscription_client >/dev/null
jq -e '.tag == "🇺🇸美国节点 v6 · Hy2" and .addrs[0].server == "2606:4700:4700::1111"' "$_TMP/inbound-1" >/dev/null
jq -e '.tag == "🇺🇸美国节点 v6 · VLESS"' "$_TMP/inbound-2" >/dev/null
jq -e '.tag == "🇺🇸美国节点 v6 · Hy2 2"' "$_TMP/inbound-3" >/dev/null
[ "$HY2_TAG" = '🇺🇸美国节点 v6 · Hy2 2' ]
[ "$VLESS_TAG" = '🇺🇸美国节点 v6 · VLESS' ]
# IPv4 uses the same short name without v6 or internal port identifiers.
PUBLIC_IPV4=8.8.8.8
create_subscription_client >/dev/null
jq -e '.tag == "🇺🇸美国节点 · Hy2" and .addrs[0].server == "8.8.8.8"' "$_TMP/inbound-1" >/dev/null
echo 'Compact country/protocol names, IPv6 markers, duplicates and summary tag/port pairing passed'
