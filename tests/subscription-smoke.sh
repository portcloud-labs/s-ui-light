#!/bin/sh
# Run: sh tests/subscription-smoke.sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Staging uses ../install.sh; the repository uses ../scripts/install.sh.
if [ -f "$SCRIPT_DIR/install.sh" ]; then
    INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
else
    INSTALL_SCRIPT="$SCRIPT_DIR/scripts/install.sh"
fi
SUI_LIB_ONLY=1
export SUI_LIB_ONLY
. "$INSTALL_SCRIPT"
_TMP_TEST=$(mktemp -d)
trap 'rm -rf "$_TMP_TEST"' EXIT HUP INT TERM
# Only globally routable addresses may become node server/geo query inputs.
for _ip in 0.0.0.0 0.1.2.3 10.0.0.1 100.64.0.1 100.127.255.255 127.0.0.1 169.254.1.1 172.16.0.1 172.31.255.255 192.0.0.1 192.0.2.1 192.168.1.1 192.88.99.1 198.18.0.1 198.19.255.255 198.51.100.1 203.0.113.1 224.0.0.1 255.255.255.255 :: ::1 ::ffff:8.8.8.8 64:ff9b::808:808 100::1 fc00::1 fd00::1 fe80::1 ff02::1 2001::1 2001:db8::1 2002:808:808::1 3fff::1 malformed; do
    [ -z "$(printf '%s\n' "$_ip" | normalize_summary_addresses '' true)" ] || { echo "Incorrectly accepted reserved address: $_ip"; exit 1; }
done
for _ip in 1.1.1.1 8.8.8.8 100.63.255.255 100.128.0.1 172.15.255.255 172.32.0.1 2606:4700:4700::1111 2001:4860:4860::8888; do
    [ -n "$(printf '%s\n' "$_ip" | normalize_summary_addresses '' true)" ] || { echo "Rejected public address: $_ip"; exit 1; }
done
# Partial network failures and malformed/non-public responses are discarded.
curl() { printf '%s\n' '8.8.8.8'; return 28; }
PUBLIC_IPS_READY=false
discover_public_addresses
[ -z "$PUBLIC_IPV4$PUBLIC_IPV6" ]
curl() { case " $* " in *' -4 '*) echo 100.64.1.1 ;; *) echo fd00::1 ;; esac; }
PUBLIC_IPS_READY=false
discover_public_addresses
[ -z "$PUBLIC_IPV4$PUBLIC_IPV6" ]
# Geo lookup is best-effort, including success:false in an HTTP 200 response.
SUB_PUBLIC_HOST=8.8.8.8
curl() { echo '{"success":true,"ip":"8.8.8.8","country":"美国","country_code":"US","flag":{"emoji":"🇺🇸"}}'; }
lookup_node_label
[ "$NODE_LABEL" = '🇺🇸美国节点' ]
curl() { echo '{"success":false,"country":"美国"}'; }
lookup_node_label
[ "$NODE_LABEL" = '🚀 加速节点' ]
curl() { echo 'not JSON'; return 0; }
lookup_node_label
[ "$NODE_LABEL" = '🚀 加速节点' ]
curl() { echo 'failure' >&2; return 28; }
lookup_node_label 2>"$_TMP_TEST/stderr"
[ "$NODE_LABEL" = '🚀 加速节点' ] && [ ! -s "$_TMP_TEST/stderr" ]
SUB_PUBLIC_HOST=''
lookup_node_label
[ "$NODE_LABEL" = '🚀 加速节点' ]
# URL output respects independent subscription TLS, domain and NAT overrides.
SUB_CLIENT_NAME=test-client
_hosts='8.8.8.8
[2606:4700:4700::1111]
10.0.0.1
100.64.1.1
203.0.113.1
[2001:db8::1]'
read_subscription_address '{}'
print_subscription_urls > "$_TMP_TEST/urls"
assert_contains() { grep -F "$1" "$2" >/dev/null; }
[ "$(grep -c '?format=clash' "$_TMP_TEST/urls")" -eq 2 ]
assert_contains 'http://8.8.8.8:2096/sub/test-client?format=clash' "$_TMP_TEST/urls"
assert_contains 'http://[2606:4700:4700::1111]:2096/sub/test-client?format=clash' "$_TMP_TEST/urls"
read_subscription_address '{"subURI":"https://sub.example/nat/"}'
print_subscription_urls > "$_TMP_TEST/urls"
assert_contains 'https://sub.example/nat/test-client?format=clash' "$_TMP_TEST/urls"
read_subscription_address '{"subDomain":"2606:4700:4700::1111","subPort":"9443","subPath":"feed","subCertFile":"cert","subKeyFile":"key"}'
print_subscription_urls > "$_TMP_TEST/urls"
assert_contains 'https://[2606:4700:4700::1111]:9443/feed/test-client?format=clash' "$_TMP_TEST/urls"
# Exercise creation against deliberately different list/full-object responses.
INSTALL_DIR="$_TMP_TEST"
PUBLIC_IPS_READY=true
PUBLIC_IPV4=8.8.8.8
PUBLIC_IPV6=''
ensure_session() { return 0; }
panel_request() {
    case "$2" in
        inbounds) printf '%s' '{"success":true,"obj":{"inbounds":[{"id":1,"type":"hysteria2"},{"id":2,"type":"vless"}]}}' ;;
        'inbounds?id=1,2') printf '%s' '{"success":true,"obj":{"inbounds":[{"id":1,"type":"hysteria2","listen_port":20001,"obfs":{"type":"salamander","password":"keep-me"},"addrs":[{"server":"nat.example","server_port":30001}]},{"id":2,"type":"vless","listen_port":443,"tls_id":7,"transport":{"type":"ws","path":"/keep"},"addrs":[]}]}}' ;;
        settings) printf '%s' '{"success":true,"obj":{"subPort":"2096","subPath":"/sub/","subClashExt":"old-template","subClashNoDefGrp":"false","subClashSprtAll":"false"}}' ;;
        *) return 1 ;;
    esac
}
panel_save() {
    case "$1" in
        inbounds)
            printf '%s' "$3" | jq -e '
                if .id == 1 then
                    .obfs.password == "keep-me" and .addrs[0].server == "nat.example" and .addrs[0].server_port == 30001 and (.tag|endswith("Hy2"))
                else
                    .id == 2 and .tls_id == 7 and .transport.path == "/keep" and .addrs[0].server == "8.8.8.8" and .addrs[0].server_port == 443 and (.tag|endswith("VLESS"))
                end' >/dev/null || return 1
            printf '%s' "$3" > "$_TMP_TEST/inbound-edit"
            ;;
        clients)
            printf '%s' "$3" | jq -e '.remark == "" and .inbounds == [1,2] and .enable == true and .volume == 0 and .expiry == 0 and (.name|length == 24) and (.config.hysteria2.password|length == 24) and (.config.vless.uuid|test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$"))' >/dev/null || return 1
            ;;
        settings)
            printf '%s' "$3" | jq -e '.subClashNoDefGrp == "true" and .subClashSprtAll == "true" and (.subClashExt|contains("proxy-groups:"))' >/dev/null || return 1
            ;;
        *) return 1 ;;
    esac
    printf '%s' '{"success":true}'
}
create_subscription_client >/dev/null
[ -f "$_TMP_TEST/inbound-edit" ] && [ -n "$SUB_CLIENT_NAME" ]
jq -e '.subClashExt == "old-template"' "$INSTALL_DIR/clash-template-backup-$SUB_CLIENT_NAME.json" >/dev/null
# No inbounds must not create a misleading empty subscription.
panel_request() { printf '%s' '{"success":true,"obj":{"inbounds":[]}}'; }
SUB_CLIENT_NAME=''
if create_subscription_client >/dev/null 2>&1; then exit 1; fi
[ -z "$SUB_CLIENT_NAME" ]
echo 'Public IPs, country fallback, full-object preservation, client creation, template settings and URLs passed' 
