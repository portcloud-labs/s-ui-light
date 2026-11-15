#!/bin/sh
set -eu
_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -f "$_ROOT/install.sh" ]; then _SCRIPT="$_ROOT/install.sh"; else _SCRIPT="$_ROOT/scripts/install.sh"; fi
SUI_LIB_ONLY=1
export SUI_LIB_ONLY
. "$_SCRIPT"
_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT HUP INT TERM
PANEL_PORT=2095
PANEL_PATH=/app/
CERT_CRT='/test/self.crt'
CERT_KEY='/test/self.key'
panel_request() { printf '%s' '{"success":true,"obj":{"subPort":"2096","subURI":"http://sub.example/feed/","webURI":"http://panel.example/"}}'; }
panel_save() { printf '%s' "$3" > "$_TMP/settings"; printf '%s' '{"success":true}'; }
service_restart() { echo restart >> "$_TMP/restarts"; }
curl() {
    printf '%s\n' "$*" >> "$_TMP/requests"
    if [ "$_web_scheme" = http ]; then case "$*" in *https://*) return 35 ;; esac; fi
    return 0
}
configure_web_transport https >/dev/null
$PANEL_TLS
jq -e '.webCertFile == "/test/self.crt" and .webKeyFile == "/test/self.key" and .subCertFile == .webCertFile and .subKeyFile == .webKeyFile and .subURI == "https://sub.example/feed/" and .webURI == "https://panel.example/"' "$_TMP/settings" >/dev/null
grep -F 'https://127.0.0.1:2095/' "$_TMP/requests" >/dev/null
grep -F 'https://127.0.0.1:2096/' "$_TMP/requests" >/dev/null
configure_web_transport http >/dev/null
! $PANEL_TLS
jq -e '.webCertFile == "" and .webKeyFile == "" and .subCertFile == "" and .subKeyFile == "" and .subURI == "http://sub.example/feed/"' "$_TMP/settings" >/dev/null
[ "$(wc -l < "$_TMP/restarts" | tr -d ' ')" = 2 ]
# Existing HTTPS installs must be detected before trying to log in.
curl() { case "$*" in *https://*) printf '%s' '{"success":false}' ;; *) return 1 ;; esac; }
detect_panel_transport
$PANEL_TLS
[ "$API_BASE" = 'https://127.0.0.1:2095/app/api/' ]
curl() { case "$*" in *http://*) printf '%s' '{"success":false}' ;; *) return 1 ;; esac; }
detect_panel_transport
! $PANEL_TLS
# A failed listener must never be reported as successful HTTPS.
curl() { return 1; }
sleep() { :; }
if configure_web_transport https >"$_TMP/failed"; then exit 1; fi
! grep -F 'both use https' "$_TMP/failed" >/dev/null
echo 'Paired HTTP/HTTPS certificate settings, URL schemes, listener probes and failure handling passed'
