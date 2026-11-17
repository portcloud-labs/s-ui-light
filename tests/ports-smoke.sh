#!/bin/sh
set -eu
_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -f "$_ROOT/install.sh" ]; then _SCRIPT="$_ROOT/install.sh"; else _SCRIPT="$_ROOT/scripts/install.sh"; fi
SUI_LIB_ONLY=1
export SUI_LIB_ONLY
. "$_SCRIPT"
_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT HUP INT TERM
for value in 0 65536 -1 abc 1.5 9999999999999999999; do
    if normalize_port "$value" >/dev/null; then echo "Accepted invalid port $value"; exit 1; fi
    if sh "$_SCRIPT" --panel-port "$value" >"$_TMP/error" 2>&1; then exit 1; fi
done
[ "$(normalize_port 00080)" = 80 ]
[ "$(normalize_port 65535)" = 65535 ]
if sh "$_SCRIPT" --panel-port 3000 --sub-port 3000 >/dev/null 2>&1; then exit 1; fi
if sh "$_SCRIPT" --sub-port >/dev/null 2>&1; then exit 1; fi
# Flags win over environment variables; source with arguments but do not run main.
parsed=$(SUI_PANEL_PORT=3000 SUI_SUB_PORT=3001 sh -c '_file="$1"; shift; . "$_file"; printf "%s/%s" "$REQUESTED_PANEL_PORT" "$REQUESTED_SUB_PORT"' unused "$_SCRIPT" --panel-port 4000 --sub-port 4001)
[ "$parsed" = 4000/4001 ]
printf '2095 2096\n' > "$_TMP/ports"
sui() {
    if [ "$2" = -show ]; then
        read -r _mock_panel _mock_sub < "$_TMP/ports"
        printf '\tPanel port:\t%s\n\tPanel path:\t/app/\n\tSub port:\t%s\n' "$_mock_panel" "$_mock_sub"
    else
        [ "$2" = -port ] && [ "$4" = -subPort ]
        printf '%s %s\n' "$3" "$5" > "$_TMP/ports"
    fi
}
ASSUME=no
REQUESTED_PANEL_PORT=''
REQUESTED_SUB_PORT=''
configure_ports >/dev/null
[ "$PANEL_PORT" = 2095 ] && [ "$SUB_PORT" = 2096 ]
REQUESTED_PANEL_PORT=3000
REQUESTED_SUB_PORT=3001
configure_ports >/dev/null
[ "$PANEL_PORT" = 3000 ] && [ "$SUB_PORT" = 3001 ]
REQUESTED_PANEL_PORT=''
REQUESTED_SUB_PORT=''
configure_ports >/dev/null
[ "$PANEL_PORT" = 3000 ] && [ "$SUB_PORT" = 3001 ]
REQUESTED_SUB_PORT=3000
if configure_ports >/dev/null 2>&1; then exit 1; fi
# Prompt advertises its default and accepts blank input; invalid input retries.
[ "$(printf '\n' | prompt_port 'Panel port' 2095 2096 2>"$_TMP/prompt")" = 2095 ]
grep -F 'Panel port [2095]: ' "$_TMP/prompt" >/dev/null
[ "$(printf '0\n2095\n3001\n' | prompt_port 'Subscription port' 2096 2095 2>"$_TMP/prompt")" = 3001 ]
# If the CLI reports success without writing, readback must catch it.
sui() { printf '\tPanel port:\t2095\n\tSub port:\t2096\n'; }
REQUESTED_PANEL_PORT=5000
REQUESTED_SUB_PORT=5001
if configure_ports >/dev/null 2>&1; then exit 1; fi
echo 'Port ranges, defaults, CLI overrides, upgrade preservation, prompts, conflicts and readback passed'
