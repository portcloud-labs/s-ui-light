#!/bin/sh
set -eu
_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -f "$_ROOT/install.sh" ]; then _SCRIPT="$_ROOT/install.sh"; else _SCRIPT="$_ROOT/scripts/install.sh"; fi
SUI_LIB_ONLY=1
export SUI_LIB_ONLY
. "$_SCRIPT"
_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT HUP INT TERM
cat > "$_TMP/original" <<'JSON'
[{"id":1,"type":"hysteria2","tag":"hy2-old","listen":"::","listen_port":46454,"tls_id":1,"obfs":{"type":"salamander","password":"unchanged"},"addrs":[]},{"id":2,"type":"vless","tag":"vless-old","listen":"::","listen_port":443,"tls_id":2,"addrs":[]}]
JSON
cp "$_TMP/original" "$_TMP/inbounds"
printf '%s' '[{"id":10,"inbounds":[1,2]}]' > "$_TMP/clients"
FAIL_CLONE=false
PUBLIC_IPV4=8.8.8.8
PUBLIC_IPV6=2606:4700:4700::1111
PUBLIC_IPV6_LISTEN="$PUBLIC_IPV6"
panel_save() {
    _mock_edit="$3"
    jq --argjson edit "$_mock_edit" 'map(if .id==$edit.id then $edit else . end)' "$_TMP/inbounds" > "$_TMP/new"
    mv "$_TMP/new" "$_TMP/inbounds"
    printf '%s' '{"success":true}'
}
panel_request() {
    if [ "$1" = GET ]; then
        case "$2" in
            clients) jq -c '{success:true,obj:{clients:.}}' "$_TMP/clients" ;;
            *) jq -c '{success:true,obj:{inbounds:.}}' "$_TMP/inbounds" ;;
        esac
        return 0
    fi
    if $FAIL_CLONE; then printf '%s' '{"success":false}'; return 0; fi
    _mock_data=''; _mock_users=''
    for _mock_arg in "$@"; do
        case "$_mock_arg" in data=*) _mock_data="${_mock_arg#data=}" ;; initUsers=*) _mock_users="${_mock_arg#initUsers=}" ;; esac
    done
    _mock_id=$(jq 'map(.id)|max+1' "$_TMP/inbounds")
    jq --argjson data "$_mock_data" --argjson id "$_mock_id" '.+[$data|.id=$id]' "$_TMP/inbounds" > "$_TMP/new"
    mv "$_TMP/new" "$_TMP/inbounds"
    jq --arg users "$_mock_users" --argjson id "$_mock_id" 'map(if ((.id|tostring) as $name | $users|split(",")|index($name))!=null then .inbounds += [$id] else . end)' "$_TMP/clients" > "$_TMP/new"
    mv "$_TMP/new" "$_TMP/clients"
    printf '%s' '{"success":true}'
}
ensure_ipv6_inbounds "$(cat "$_TMP/inbounds")"
$IPV6_INBOUNDS_CHANGED
jq -e 'length==4 and ([.[]|select(.listen=="0.0.0.0")]|length)==2 and ([.[]|select(.listen=="2606:4700:4700::1111")]|length)==2' "$_TMP/inbounds" >/dev/null
jq -e '.[0].inbounds==[1,2,3,4]' "$_TMP/clients" >/dev/null
jq -e '[.[]|select(.type=="hysteria2")]|all(.[]; .listen_port==46454 and .obfs.password=="unchanged")' "$_TMP/inbounds" >/dev/null
ensure_ipv6_inbounds "$(cat "$_TMP/inbounds")"
! $IPV6_INBOUNDS_CHANGED
[ "$(jq length "$_TMP/inbounds")" = 4 ]
NODE_LABEL='🚀加速节点'
SUB_PUBLIC_HOST="$PUBLIC_IPV4"
prepare_named_inbounds "$(cat "$_TMP/inbounds")" > "$_TMP/named"
jq -e 'map(.tag)|sort == (["🚀加速节点 · Hy2","🚀加速节点 v6 · Hy2","🚀加速节点 · VLESS","🚀加速节点 v6 · VLESS"]|sort)' "$_TMP/named" >/dev/null
# Failed IPv6 creation restores the original wildcard listener and metadata.
cp "$_TMP/original" "$_TMP/inbounds"
FAIL_CLONE=true
if ensure_ipv6_inbounds "$(cat "$_TMP/inbounds")"; then exit 1; fi
jq -S . "$_TMP/inbounds" > "$_TMP/sorted"
jq -S . "$_TMP/original" > "$_TMP/original-sorted"
cmp "$_TMP/sorted" "$_TMP/original-sorted"
# No split on IPv6-only hosts: their original :: listener already serves IPv6.
PUBLIC_IPV4=''
ensure_ipv6_inbounds "$(cat "$_TMP/inbounds")"
! $IPV6_INBOUNDS_CHANGED
# External lookup failure may fall back only to a valid global NIC address.
PUBLIC_IPS_READY=false
curl() { return 28; }
ip() { printf '%s\n' '2: eth0 inet6 fd00::1/64 scope global' '2: eth0 inet6 2001:db8::1/64 scope global' '2: eth0 inet6 2606:4700:4700::1111/64 scope global'; }
discover_public_addresses
[ "$PUBLIC_IPV6" = 2606:4700:4700::1111 ] && [ "$PUBLIC_IPV6_LISTEN" = "$PUBLIC_IPV6" ]
echo 'Dual-stack split, same ports, existing client assignment, idempotency, IPv6 names, rollback and global-NIC fallback passed'
