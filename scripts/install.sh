#!/bin/sh
#
# install.sh — Install s-ui on Alpine Linux or Debian/Ubuntu
#
# Auto-detects the OS (Alpine → OpenRC, Debian/Ubuntu → systemd) and the
# architecture. Downloads binaries from GitHub Releases (no git needed).
#
# The binary is ~100 MiB but the target VPS may have a 64 MiB cgroup hard
# limit. Downloads default to a 1M/s cap below 96 MiB, and no cap otherwise.
# They are resumable, streamed to disk, shown with a progress bar on a terminal, and
# verified before it is ever executed. The operator can switch the cap off at
# the prompt or with --download-rate 0. On small-memory hosts the Go runtime
# also gets a soft heap limit, so the kernel does not OOM-kill the panel (or
# sshd) a few seconds after startup.
#
# After installing, the script optionally:
#   - sets a random strong password for the admin account (username unchanged)
#   - generates a self-signed certificate and serves the panel over HTTPS
#   - creates an unlimited client for all current inbounds and applies a Clash template
#   - deploys a Hysteria2 inbound with a self-signed certificate, a forged SNI
#     and "allow insecure" enabled, plus Salamander with a separate random password
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Options:
#   --repo <user/repo>       GitHub repo (default: portcloud-labs/s-ui-light)
#   --arch <arch>            Force architecture (amd64|arm64). Auto-detected by default.
#   --install-dir <dir>      Installation directory. Default: /usr/local/s-ui
#   --version <ver>          Specific version to install (default: latest)
#   --download-rate <rate>   Cap the download (default: 1M below 96 MiB, otherwise 0).
#                            Skips the interactive rate question.
#   --panel-port <port>     Panel TCP port (default: 2095; existing port on upgrades)
#   --sub-port <port>       Subscription TCP port (default: 2096; existing port on upgrades)
#   --hy2-port <port>       Hy2 UDP port (default: random 20000-59999)
#   --vless-port <port>     VLESS TCP port (default: 443)
#   --low-mem <auto|on|off>  Go memory guard (default: auto, enabled at <=256 MiB cgroup)
#   --uninstall              Remove s-ui and its service
#   --no-prompt              Skip every interactive question. Post-install steps
#                            stay off; the download cap follows detected memory
#   --yes                    Skip every interactive question (answer "yes" to each)
#   -h, --help               Show this help
#
# Environment (useful for curl | sh, where no flags can be passed):
#   SUI_DOWNLOAD_RATE   Same as --download-rate
#   SUI_PANEL_PORT      Same as --panel-port
#   SUI_SUB_PORT        Same as --sub-port
#   SUI_HY2_PORT        Same as --hy2-port
#   SUI_VLESS_PORT      Same as --vless-port
#   SUI_LOW_MEM         Same as --low-mem
#   SUI_SHA256          Expected sha256 of sui-<arch>, overrides the release digest
#
# Examples:
#   ./install.sh
#   ./install.sh --arch arm64
#   ./install.sh --download-rate 256K --low-mem on
#   ./install.sh --repo myuser/myrepo --version v1.4.2
#   ./install.sh --uninstall

set -e

# ── Interactivity ─────────────────────────────────────────────────────────────
# ASSUME carries the --yes/--no-prompt answer. Empty means "ask"; when there is
# no terminal to ask on (a pipe, cron, curl | sh), ask() falls back to no so an
# unattended run cannot silently turn on TLS or open a port.
ASSUME=""

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INF]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WRN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERR]${NC} %s\n" "$*"; }

# ask prints a prompt and returns 0 for yes. There is no `read` when stdin is
# not a terminal, so an unattended run gets the safe answer instead of hanging
# forever on a prompt nobody can see.
ask() {
    case "$ASSUME" in
        yes) return 0 ;;
        no)  return 1 ;;
    esac
    [ -t 0 ] || return 1
    _ask_default="${2:-no}"
    if [ "$_ask_default" = yes ]; then
        printf "%s [Y/n]: " "$1"
    else
        printf "%s [y/N]: " "$1"
    fi
    # A failed read (EOF, Ctrl-D) must not abort the script under set -e.
    _ans=""
    read -r _ans || true
    case "$_ans" in
        y|Y|yes|YES) return 0 ;;
        '')          [ "$_ask_default" = yes ] ;;
        *)           return 1 ;;
    esac
}

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO="portcloud-labs/s-ui-light"
INSTALL_DIR="/usr/local/s-ui"
DATA_DIR="/etc/s-ui"
LOG_FILE="/var/log/s-ui.log"
INIT_SCRIPT="/etc/init.d/s-ui"
SERVICE_FILE="/etc/systemd/system/s-ui.service"
# Filled in after the arguments are parsed, so --install-dir is honoured.
CERT_DIR=""
OS=""
ARCH=""
VERSION="latest"
UNINSTALL=false
ADMIN_USER="admin"
ADMIN_PASS=""
CERT_CRT=""
CERT_KEY=""
PANEL_TLS=false
PUBLIC_IPS_READY=false
PUBLIC_IPV4=""
PUBLIC_IPV6=""
SUB_CLIENT_NAME=""
REQUESTED_PANEL_PORT="${SUI_PANEL_PORT:-}"
REQUESTED_SUB_PORT="${SUI_SUB_PORT:-}"
REQUESTED_HY2_PORT="${SUI_HY2_PORT:-}"
REQUESTED_VLESS_PORT="${SUI_VLESS_PORT:-}"

# ── Low-memory / download defaults ───────────────────────────────────────────
# curl does every download (it is already required by the panel API). Busybox
# wget -- the default on Alpine -- has NO --limit-rate, so capping the ~100 MiB
# binary with wget is impossible without installing GNU wget, and `apk add` is
# itself one of the first things to OOM on a 64 MiB box.
#
# Offer a 1M/s cap below 96 MiB; larger hosts default to unlimited.
# Keep the cap if memory cannot be detected. Explicit settings always win.
DOWNLOAD_RATE="1M"
DOWNLOAD_RATE_EXPLICIT=false  # set by --download-rate / SUI_DOWNLOAD_RATE
DOWNLOAD_RETRIES=5
LOW_MEM="auto"              # auto | on | off
EXPECTED_SHA256=""          # from the release JSON (best effort) or SUI_SHA256
EXPECTED_SIZE=""            # from the release JSON (best effort)
RELEASE_JSON=""
LOW_MEM_ENABLED=false
MEM_LIMIT_BYTES=""
GO_MEM_LIMIT=""             # e.g. 40MiB
GO_GC="30"
GO_MAXPROCS="1"
GO_ENV_OPENRC=""            # snippet baked into the OpenRC unit
GO_ENV_SYSTEMD=""           # snippet baked into the systemd unit

# Environment variables are applied first, so an explicit flag still wins.
if [ -n "${SUI_DOWNLOAD_RATE:-}" ]; then
    DOWNLOAD_RATE="$SUI_DOWNLOAD_RATE"
    DOWNLOAD_RATE_EXPLICIT=true
fi
if [ -n "${SUI_LOW_MEM:-}" ]; then LOW_MEM="$SUI_LOW_MEM"; fi
if [ -n "${SUI_SHA256:-}" ]; then EXPECTED_SHA256="$SUI_SHA256"; fi

# Ports and names for the generated certificate. The SNI is a decoy: the
# certificate is self-signed, so its name is only there to look unremarkable
# to a passive observer, and clients skip verification anyway.
SNI_POOL="www.bing.com www.cloudflare.com www.apple.com www.microsoft.com www.amazon.com"
HY2_TAG_PREFIX="hysteria2"
VLESS_TAG_PREFIX="vless-reality"

# Accept TCP/UDP port numbers; normalize decimal input without shell octal parsing.
normalize_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ ${#1} -le 5 ] || return 1
    awk -v port="$1" 'BEGIN { if (port+0 < 1 || port+0 > 65535) exit 1; printf "%d\n", port+0 }'
}

# Prompts go to stderr because the selected value is captured from stdout.
prompt_port() {
    _port_label="$1"; _port_default="$2"; _port_excluded="${3:-}"
    while :; do
        printf '%s [%s]: ' "$_port_label" "$_port_default" >&2
        _port_answer=""
        _port_eof=false
        read -r _port_answer || _port_eof=true
        _port_answer="${_port_answer:-$_port_default}"
        if _port_value=$(normalize_port "$_port_answer"); then
            _port_valid=true
            for _excluded in $_port_excluded; do
                [ "$_port_value" != "$_excluded" ] || _port_valid=false
            done
            if $_port_valid; then printf '%s\n' "$_port_value"; return 0; fi
        fi
        log_error 'Invalid or conflicting port; use 1-65535' >&2
        # EOF cannot be corrected interactively; never loop forever on it.
        if $_port_eof; then return 1; fi
    done
}

# Called before starting the service, so occupied old/default listener ports
# do not prevent a fresh installation from choosing different ports.
configure_ports() {
    read_panel_address
    _selected_panel_port="${REQUESTED_PANEL_PORT:-$PANEL_PORT}"
    _selected_sub_port="${REQUESTED_SUB_PORT:-$SUB_PORT}"
    if [ -z "$ASSUME" ] && [ -t 0 ]; then
        if [ -z "$REQUESTED_PANEL_PORT" ]; then
            _selected_panel_port=$(prompt_port 'Panel port' "$_selected_panel_port" "$REQUESTED_SUB_PORT") || return 1
        fi
        if [ -z "$REQUESTED_SUB_PORT" ]; then
            _selected_sub_port=$(prompt_port 'Subscription port' "$_selected_sub_port" "$_selected_panel_port") || return 1
        fi
    fi
    if [ "$_selected_panel_port" = "$_selected_sub_port" ]; then
        log_error 'Panel port and subscription port must be different'
        return 1
    fi
    sui setting -port "$_selected_panel_port" -subPort "$_selected_sub_port" >/dev/null || return 1
    # The upstream CLI may return zero after a settings error. Read it back.
    read_panel_address
    if [ "$PANEL_PORT" != "$_selected_panel_port" ] || [ "$SUB_PORT" != "$_selected_sub_port" ]; then
        log_error 'Could not save the requested panel/subscription ports'
        return 1
    fi
    log_info "Panel port: $PANEL_PORT; subscription port: $SUB_PORT"
}

# Hy2 is UDP and may share a numeric port with the TCP panel/VLESS listeners.
# VLESS is TCP and must not share a port with the panel or subscription server.
choose_node_port() {
    _node_protocol="$1"; _node_requested="$2"; _node_default="$3"
    _node_excluded=""
    if [ "$_node_protocol" = VLESS ]; then
        _node_excluded="${PANEL_PORT:-2095} ${SUB_PORT:-2096}"
        log_warn 'Non-443 VLESS ports may increase the risk of your server IP being blocked by the GFW.' >&2
        _node_label='VLESS port'
    else
        _node_label='Hy2 port (random default)'
    fi
    if [ -n "$_node_requested" ]; then
        _node_selected="$_node_requested"
    elif [ -z "$ASSUME" ] && [ -t 0 ]; then
        _node_selected=$(prompt_port "$_node_label" "$_node_default" "$_node_excluded") || return 1
    else
        _node_selected="$_node_default"
    fi
    _node_selected=$(normalize_port "$_node_selected") || return 1
    for _node_conflict in $_node_excluded; do
        if [ "$_node_selected" = "$_node_conflict" ]; then
            log_error "VLESS port $_node_selected is already used by the panel or subscription listener" >&2
            return 1
        fi
    done
    printf '%s\n' "$_node_selected"
}

# ── Parse arguments ───────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)        REPO="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --download-rate) DOWNLOAD_RATE="$2"; DOWNLOAD_RATE_EXPLICIT=true; shift 2 ;;
        --panel-port|--sub-port|--hy2-port|--vless-port)
            if [ $# -lt 2 ] || [ -z "$2" ]; then log_error "$1 requires a port"; exit 1; fi
            case "$1" in
                --panel-port) REQUESTED_PANEL_PORT="$2" ;;
                --sub-port) REQUESTED_SUB_PORT="$2" ;;
                --hy2-port) REQUESTED_HY2_PORT="$2" ;;
                --vless-port) REQUESTED_VLESS_PORT="$2" ;;
            esac
            shift 2
            ;;
        --low-mem)       LOW_MEM="$2"; shift 2 ;;
        --uninstall)   UNINSTALL=true; shift ;;
        --yes)         ASSUME="yes"; shift ;;
        --no-prompt)   ASSUME="no"; shift ;;
        -h|--help)
            # Every leading comment line, minus the shebang, up to the first
            # real statement. Stopping at a blank line instead ended the range
            # immediately: the header uses "#" on its own as a separator.
            # Written as two substitutions because the "\?" in "# \?" is a GNU
            # extension that BSD sed rejects, which printed nothing at all.
            sed -n -e '2,/^[^#]/s/^# //p' -e '2,/^[^#]/s/^#$//p' "$0" | sed '/^$/d'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Reject invalid explicit ports before package installation or downloads.
if [ -n "$REQUESTED_PANEL_PORT" ]; then
    REQUESTED_PANEL_PORT=$(normalize_port "$REQUESTED_PANEL_PORT") || { log_error 'Invalid panel port (use 1-65535)'; exit 1; }
fi
if [ -n "$REQUESTED_SUB_PORT" ]; then
    REQUESTED_SUB_PORT=$(normalize_port "$REQUESTED_SUB_PORT") || { log_error 'Invalid subscription port (use 1-65535)'; exit 1; }
fi
if [ -n "$REQUESTED_HY2_PORT" ]; then
    REQUESTED_HY2_PORT=$(normalize_port "$REQUESTED_HY2_PORT") || { log_error 'Invalid Hy2 port (use 1-65535)'; exit 1; }
fi
if [ -n "$REQUESTED_VLESS_PORT" ]; then
    REQUESTED_VLESS_PORT=$(normalize_port "$REQUESTED_VLESS_PORT") || { log_error 'Invalid VLESS port (use 1-65535)'; exit 1; }
fi
if [ -n "$REQUESTED_PANEL_PORT" ] && [ "$REQUESTED_PANEL_PORT" = "$REQUESTED_SUB_PORT" ]; then
    log_error 'Panel port and subscription port must be different'
    exit 1
fi

# Certificates sit next to the binary so --install-dir moves them together.
CERT_DIR="$INSTALL_DIR/cert"

# Validate the low-memory knobs before any download or package install starts.
case "$LOW_MEM" in
    auto|on|off) ;;
    *)
        log_error "--low-mem / SUI_LOW_MEM must be auto, on, or off"
        exit 1
        ;;
esac
case "$DOWNLOAD_RATE" in
    0)
        log_warn "Download rate cap disabled (0)"
        ;;
    # curl accepts <number>[K|M|G] (also lowercase). Require that exact shape:
    # 'K512' or an empty suffix would otherwise reach curl as a bad flag.
    *[0-9]|[0-9]*[KkMmGg])
        case "$DOWNLOAD_RATE" in
            ''|*[!0-9KkMmGg]*|*[KkMmGg]*[0-9KkMmGg]*)
                log_error "Invalid --download-rate: '$DOWNLOAD_RATE' (use e.g. 256K, 1M, or 0)"
                exit 1
                ;;
        esac
        ;;
    *)
        log_error "Invalid --download-rate: '$DOWNLOAD_RATE' (use e.g. 256K, 1M, or 0)"
        exit 1
        ;;
esac

# The service files interpolate these paths, so a value that could break out of
# a systemd "WorkingDirectory=" line or an OpenRC "directory=" assignment would
# produce a unit that cannot run -- or worse, one that runs something else.
case "$INSTALL_DIR" in
    *[\ \"\'\`\$\*]*)
        log_error "--install-dir must not contain spaces, quotes, or shell metacharacters"
        exit 1
        ;;
esac
case "$INSTALL_DIR" in
    /*) ;;
    *)
        log_error "--install-dir must be an absolute path"
        exit 1
        ;;
esac

# ── Detect OS ─────────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        ID=$( . /etc/os-release; echo "$ID" )
        case "$ID" in
            alpine)            OS="alpine" ;;
            debian|ubuntu)     OS="debian" ;;
            *)
                log_error "Unsupported OS: $ID"
                log_error "Supported: alpine, debian, ubuntu"
                exit 1
                ;;
        esac
    else
        log_error "Cannot detect OS (/etc/os-release not found)"
        exit 1
    fi
    log_info "Detected OS: $OS"
}

# ── Detect architecture ───────────────────────────────────────────────────────
detect_arch() {
    if [ -n "$ARCH" ]; then
        case "$ARCH" in
            amd64|arm64) ;;
            *) log_error "Unsupported architecture: $ARCH (use amd64 or arm64)"; exit 1 ;;
        esac
        return
    fi

    MACHINE=$(uname -m)
    case "$MACHINE" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $MACHINE"
            log_error "Use --arch amd64|arm64 to force"
            exit 1
            ;;
    esac
    log_info "Detected architecture: $ARCH ($MACHINE)"
}

# ── Small-memory detection ───────────────────────────────────────────────────
# `free` is misleading inside a container: on a 64 MiB cgroup it happily
# reports the host's 5.9 GiB. Only the cgroup files describe the ceiling the
# OOM killer actually enforces, so those are the only sources used here.
# The optional argument lets the smoke tests pass a fixture file.
read_memory_limit_bytes() {
    _f="${1:-}"
    if [ -z "$_f" ]; then
        if [ -r /sys/fs/cgroup/memory.max ]; then                      # cgroup v2
            _f=/sys/fs/cgroup/memory.max
        elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then   # cgroup v1
            _f=/sys/fs/cgroup/memory/memory.limit_in_bytes
        else
            return 1
        fi
    fi
    [ -r "$_f" ] || return 1
    _v=$(cat "$_f" 2>/dev/null || true)
    case "$_v" in
        ''|max|*[!0-9]*) return 1 ;;
    esac
    # cgroup v1 encodes "unlimited" as 9223372036854771712. Anything with 13+
    # digits is >= 1 TiB, i.e. not a meaningful small-memory cap -- and feeding
    # it to -le could overflow a 32-bit shell.
    if [ ${#_v} -ge 13 ]; then return 1; fi
    if [ "$_v" -le 0 ]; then return 1; fi
    echo "$_v"
}

# Decide whether to switch the Go runtime into low-memory mode, then build the
# environment snippets that get baked into the OpenRC / systemd units.
configure_memory_guard() {
    MEM_LIMIT_BYTES=$(read_memory_limit_bytes || true)
    if [ -n "$MEM_LIMIT_BYTES" ]; then
        log_info "Detected cgroup memory limit: $(( MEM_LIMIT_BYTES / 1048576 )) MiB"
    else
        log_info "No cgroup memory limit detected"
    fi

    case "$LOW_MEM" in
        on)  LOW_MEM_ENABLED=true ;;
        off) LOW_MEM_ENABLED=false ;;
        auto)
            # Below 256 MiB an unmanaged Go heap plus the 100+ MiB mmap'ed
            # binary starts hitting the ceiling in practice. Above it, do
            # nothing: a GOMEMLIMIT tuned for 64 MiB would cripple a big host.
            if [ -n "$MEM_LIMIT_BYTES" ] && [ "$MEM_LIMIT_BYTES" -le 268435456 ]; then
                LOW_MEM_ENABLED=true
            else
                LOW_MEM_ENABLED=false
            fi
            ;;
    esac

    if ! $LOW_MEM_ENABLED; then
        GO_ENV_OPENRC=""
        GO_ENV_SYSTEMD=""
        return 0
    fi

    # Leave ~40% of the cap for the binary's file-backed pages, the kernel,
    # sshd and page cache. 5/8 of 64 MiB = 40 MiB, the value verified to keep
    # s-ui alive on a 64 MiB / 1 CPU container without new OOM kills.
    if [ -n "$MEM_LIMIT_BYTES" ]; then
        GO_MEM_LIMIT_MIB=$(( MEM_LIMIT_BYTES / 1048576 * 5 / 8 ))
    else
        GO_MEM_LIMIT_MIB=40
        log_warn "No cgroup limit found; assuming 40 MiB heap (--low-mem override)"
    fi
    if [ "$GO_MEM_LIMIT_MIB" -lt 24 ]; then GO_MEM_LIMIT_MIB=24; fi
    GO_MEM_LIMIT="${GO_MEM_LIMIT_MIB}MiB"

    # Expanded once into the unit files. Values contain no spaces or shell
    # metacharacters, so neither unit needs quoting.
    GO_ENV_OPENRC=$(printf 'export GOMEMLIMIT=%s\nexport GOGC=%s\nexport GOMAXPROCS=%s\nexport GODEBUG=madvdontneed=1' \
        "$GO_MEM_LIMIT" "$GO_GC" "$GO_MAXPROCS")
    GO_ENV_SYSTEMD=$(printf 'Environment=GOMEMLIMIT=%s\nEnvironment=GOGC=%s\nEnvironment=GOMAXPROCS=%s\nEnvironment=GODEBUG=madvdontneed=1' \
        "$GO_MEM_LIMIT" "$GO_GC" "$GO_MAXPROCS")

    log_warn "Low-memory mode: GOMEMLIMIT=$GO_MEM_LIMIT GOGC=$GO_GC GOMAXPROCS=$GO_MAXPROCS"
    if [ -n "$MEM_LIMIT_BYTES" ] && [ "$MEM_LIMIT_BYTES" -le 67108864 ]; then
        log_warn "On a 64 MiB host prefer --no-prompt and avoid opening extra SSH sessions"
    fi
}

# ── Choose the download rate ─────────────────────────────────────────────────
# Use the cgroup limit when available; otherwise read physical RAM for hosts
# without a cgroup cap. This fallback only affects downloads, not the Go guard.
choose_download_rate() {
    if $DOWNLOAD_RATE_EXPLICIT; then
        if [ "$DOWNLOAD_RATE" = "0" ]; then
            log_info "Download rate cap disabled (--download-rate / SUI_DOWNLOAD_RATE)"
        else
            log_info "Download capped at $DOWNLOAD_RATE (--download-rate / SUI_DOWNLOAD_RATE)"
        fi
        return 0
    fi

    _download_mem_bytes="$MEM_LIMIT_BYTES"
    _download_mem_source="cgroup limit"
    if [ -z "$_download_mem_bytes" ]; then
        _download_mem_bytes=$(awk '/^MemTotal:/ { printf "%.0f\n", $2 * 1024; exit }' /proc/meminfo 2>/dev/null || true)
        _download_mem_source="physical RAM"
    fi
    case "$_download_mem_bytes" in
        ''|*[!0-9]*|0) _download_mem_bytes="" ;;
    esac

    _cap_default=y
    if [ -n "$_download_mem_bytes" ] && [ "$_download_mem_bytes" -ge 100663296 ]; then
        _cap_default=n
    fi

    # Unattended installs use the same memory-based default as the prompt.
    if [ -n "$ASSUME" ] || [ ! -t 0 ]; then
        if [ "$_cap_default" = n ]; then
            DOWNLOAD_RATE=0
            log_info "Download rate cap disabled (default; detected memory >=96 MiB)"
        else
            log_info "Download capped at $DOWNLOAD_RATE (default; memory <96 MiB or unknown)"
        fi
        return 0
    fi

    printf "\nDownload speed: the sui binary is ~106 MiB.\n"
    if [ -n "$_download_mem_bytes" ]; then
        printf "Detected memory: %s MiB (%s).\n" \
            "$(( _download_mem_bytes / 1048576 ))" "$_download_mem_source"
    else
        printf "Could not detect memory; keeping the cap enabled by default.\n"
    fi
    if [ "$_cap_default" = y ]; then
        if [ -n "$_download_mem_bytes" ]; then
            printf "Below 96 MiB, a download cap is recommended to reduce page-cache pressure and OOM risk.\n"
        fi
        _cap_choices="Y/n"
    else
        _cap_choices="y/N"
    fi
    printf "\nCap the download at %s/s? [%s]: " "$DOWNLOAD_RATE" "$_cap_choices"
    read -r _ans || true
    case "$_ans" in
        y|Y|yes|YES) ;;
        n|N|no|NO) DOWNLOAD_RATE=0 ;;
        *) [ "$_cap_default" = y ] || DOWNLOAD_RATE=0 ;;
    esac
    if [ "$DOWNLOAD_RATE" = 0 ]; then
        log_info "Download rate cap disabled"
    else
        log_info "Download capped at $DOWNLOAD_RATE/s"
    fi
}

# ── Check dependencies ────────────────────────────────────────────────────────
check_deps() {
    # curl downloads and calls the panel; openssl generates credentials/certs;
    # jq safely handles full panel objects, TLS IDs and subscription settings.
    case "$OS" in
        alpine)
            local need_openrc=false need_curl=false need_openssl=false need_jq=false

            command -v rc-service >/dev/null 2>&1 || command -v rc-update >/dev/null 2>&1 || need_openrc=true
            command -v curl >/dev/null 2>&1 || need_curl=true
            command -v openssl >/dev/null 2>&1 || need_openssl=true
            command -v jq >/dev/null 2>&1 || need_jq=true

            if $need_openrc || $need_curl || $need_openssl || $need_jq; then
                local packages=""
                $need_openrc && packages="$packages openrc"
                $need_curl && packages="$packages curl"
                $need_openssl && packages="$packages openssl"
                $need_jq && packages="$packages jq"

                log_info "Installing missing dependencies:$packages"
                if $LOW_MEM_ENABLED; then
                    log_warn "Package installation can be memory-heavy on small containers"
                fi
                apk add --no-cache $packages
                if [ $? -ne 0 ]; then
                    log_error "Failed to install dependencies. Run manually: apk add$packages"
                    exit 1
                fi
                log_info "Dependencies installed successfully"
            fi
            ;;
        debian)
            local need_curl=false need_openssl=false need_jq=false

            command -v curl >/dev/null 2>&1 || need_curl=true
            command -v openssl >/dev/null 2>&1 || need_openssl=true
            command -v jq >/dev/null 2>&1 || need_jq=true

            if $need_curl || $need_openssl || $need_jq; then
                local packages=""
                $need_curl && packages="$packages curl"
                $need_openssl && packages="$packages openssl"
                $need_jq && packages="$packages jq"

                log_info "Installing missing dependencies:$packages"
                apt-get update -qq
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Use-Pty=0 $packages
                if [ $? -ne 0 ]; then
                    log_error "Failed to install dependencies. Run manually: apt-get install -y$packages"
                    exit 1
                fi
                log_info "Dependencies installed successfully"
            fi
            ;;
    esac
}

# ── Get version ───────────────────────────────────────────────────────────────
get_version() {
    if [ "$VERSION" = "latest" ]; then
        # -fsSL follows the 301 a renamed/transferred repo returns, which the
        # old busybox-wget path had to emulate by hand. --max-time keeps a
        # stalled API call from holding the install open on a tiny host.
        RELEASE_JSON=$(curl -fsSL --connect-timeout 20 --max-time 60 \
            "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)

        VERSION=$(printf '%s' "$RELEASE_JSON" | grep '"tag_name"' | head -1 | sed 's/.*: "//;s/".*//')
        if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
            log_error "Failed to fetch the latest version from GitHub ($REPO)"
            log_error "Check the repo name with --repo <user/repo>, or pass --version <ver>"
            exit 1
        fi

        # Best-effort integrity metadata for sui-$ARCH. GitHub's release JSON
        # is pretty-printed ("name": "sui-amd64") and every asset carries the
        # same "size"/"digest" keys, so a global grep would pick the FIRST
        # asset's values. Walk the lines instead: remember the most recently
        # seen asset name, then keep the size/digest that belong to that name.
        # Whitespace after ':' is ignored. Neither field is fatal when absent
        # (forks, mirrors, --version): verify_binary still checks ELF magic and
        # a minimum size, so a corrupt binary can never be started.
        _meta=$(printf '%s\n' "$RELEASE_JSON" | awk -v want="sui-$ARCH" '
            /"name"[[:space:]]*:/ {
                nm=$0
                sub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", nm)
                sub(/".*/, "", nm)
                next
            }
            nm == want && /"size"[[:space:]]*:/ {
                v=$0; sub(/.*"size"[[:space:]]*:[[:space:]]*/, "", v)
                sub(/[^0-9].*/, "", v); size=v; next
            }
            nm == want && /"digest"[[:space:]]*:/ {
                v=$0; sub(/.*sha256:/, "", v); sub(/".*/, "", v)
                digest=v; next
            }
            END { if (size != "" || digest != "") print size " " digest }
        ' 2>/dev/null || true)
        EXPECTED_SIZE=$(printf '%s' "$_meta" | awk '{print $1}')
        if [ -z "${SUI_SHA256:-}" ]; then
            EXPECTED_SHA256=$(printf '%s' "$_meta" | awk '{print $2}')
        fi
        # Guard against a partially parsed block: a digest must be 64 hex chars.
        case "$EXPECTED_SHA256" in
            *[!0-9a-fA-F]*|'') EXPECTED_SHA256="" ;;
        esac
        if [ ${#EXPECTED_SHA256} -ne 64 ] 2>/dev/null; then EXPECTED_SHA256=""; fi
        if [ -n "$EXPECTED_SHA256" ]; then
            log_info "Release checksum: sha256:$EXPECTED_SHA256"
        fi
    fi
    log_info "Target version: $VERSION"
}

# ── Download files ────────────────────────────────────────────────────────────
# verify_binary FILE: refuse truncated files, HTML error pages and checksum
# mismatches. Executing a half-downloaded Go binary turns a transient network
# or OOM blip into a restart loop that hammers a 64 MiB box.
verify_binary() {
    _f="$1"
    [ -f "$_f" ] || return 1
    _sz=$(wc -c < "$_f" | tr -d ' ')
    # A real sui binary is 100+ MiB. This mainly catches a truncated ELF whose
    # first four bytes still look valid.
    if [ "$_sz" -le 10485760 ]; then
        log_warn "Downloaded file is only $_sz bytes; treating as incomplete"
        return 1
    fi
    _magic=$(od -An -tx1 -N4 "$_f" 2>/dev/null | tr -d ' \n' || true)
    if [ "$_magic" != "7f454c46" ]; then
        log_warn "Downloaded file is not an ELF binary (magic: '$_magic')"
        return 1
    fi
    if [ -n "$EXPECTED_SIZE" ] && [ "$_sz" != "$EXPECTED_SIZE" ]; then
        log_warn "Size mismatch: got $_sz, expected $EXPECTED_SIZE"
        return 1
    fi
    if [ -n "$EXPECTED_SHA256" ] && command -v sha256sum >/dev/null 2>&1; then
        _got=$(sha256sum "$_f" | awk '{print $1}')
        if [ "$_got" != "$EXPECTED_SHA256" ]; then
            log_warn "Checksum mismatch (got $_got)"
            return 1
        fi
        log_info "Checksum verified (sha256)"
    fi
    return 0
}

# download_binary URL DEST: rate-limited, resumable, streamed straight to disk.
# The body is NEVER captured in a shell variable -- on a 64 MiB cgroup that
# alone is fatal. -C - resumes after an OOM-killed curl; --limit-rate caps how
# fast page cache can grow; --speed-time/--speed-limit abort a dead connection.
# On a terminal curl draws its own progress bar; when stderr is redirected
# (cron, CI, 2>file) the meter is suppressed so logs stay readable.
download_binary() {
    _url="$1"; _dest="$2"
    _part="$_dest.part"
    _log="$_dest.part.log"
    _i=0
    # Built once: either empty or exactly two safe, literal words. The word
    # splitting at the curl call sites is intentional.
    if [ "$DOWNLOAD_RATE" = "0" ]; then
        _rate_args=""
    else
        _rate_args="--limit-rate $DOWNLOAD_RATE"
    fi
    while [ "$_i" -lt "$DOWNLOAD_RETRIES" ]; do
        _i=$(( _i + 1 ))
        if [ "$DOWNLOAD_RATE" = "0" ]; then
            log_info "Downloading (attempt $_i/$DOWNLOAD_RETRIES, no rate cap)"
        else
            log_info "Downloading (attempt $_i/$DOWNLOAD_RETRIES, capped at $DOWNLOAD_RATE)"
        fi
        _rc=0
        if [ -t 2 ]; then
            # --progress-bar writes to stderr, so stderr has to stay on the
            # terminal; curl's error text is then visible there too.
            curl -fL $_rate_args --progress-bar -C - \
                --connect-timeout 20 --speed-time 60 --speed-limit 1024 \
                --max-time 3600 -o "$_part" "$_url" || _rc=$?
        else
            # -sS: no progress meter in a log or pipe, but errors still print.
            curl -fsSL $_rate_args -C - \
                --connect-timeout 20 --speed-time 60 --speed-limit 1024 \
                --max-time 3600 -o "$_part" "$_url" 2>"$_log" || _rc=$?
        fi
        if [ "$_rc" -eq 0 ]; then
            if verify_binary "$_part"; then
                mv -f "$_part" "$_dest"
                rm -f "$_log"
                sync 2>/dev/null || true
                log_info "Download verified and installed ($(wc -c < "$_dest" | tr -d ' ') bytes)"
                return 0
            fi
            log_warn "Verification failed; discarding the partial file"
            rm -f "$_part"
        else
            log_warn "Download attempt $_i failed (curl exit $_rc)"
            # curl error 33 == server does not support byte ranges. A resumed
            # transfer can then never complete, so restart from zero once.
            if [ "$_rc" -eq 33 ]; then
                rm -f "$_part"
            fi
        fi
        sleep 3
    done
    rm -f "$_part" "$_log"
    log_error "Download failed after $DOWNLOAD_RETRIES attempts"
    return 1
}

download_files() {
    local base_url="https://github.com/$REPO/releases/download/$VERSION"

    log_info "Downloading s-ui $VERSION ($ARCH)..."
    log_info "URL base: $base_url"

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$DATA_DIR"

    # On an upgrade, stop the running panel before replacing its binary:
    # keeping the old mmap'ed 100+ MiB image AND writing the new one at the
    # same time is exactly the double allocation that trips a 64 MiB cap.
    SUI_STOPPED=""
    if [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1 \
            && rc-service s-ui status >/dev/null 2>&1; then
        rc-service s-ui stop >/dev/null 2>&1 || true
        SUI_STOPPED="openrc"
    elif [ "$OS" = "debian" ] && command -v systemctl >/dev/null 2>&1 \
            && systemctl is-active --quiet s-ui 2>/dev/null; then
        systemctl stop s-ui >/dev/null 2>&1 || true
        SUI_STOPPED="systemd"
    fi

    download_binary "$base_url/sui-$ARCH" "$INSTALL_DIR/sui" || {
        log_error "Failed to download sui-$ARCH. Check if version $VERSION exists"
        # A failed upgrade must not leave the previously working panel down.
        # The old binary was never replaced (downloads land in sui.part), so
        # starting the service again is safe.
        if [ -n "$SUI_STOPPED" ] && [ -x "$INSTALL_DIR/sui" ]; then
            log_warn "Restoring the s-ui service after the failed download"
            if [ "$SUI_STOPPED" = "openrc" ]; then
                rc-service s-ui start >/dev/null 2>&1 || true
            else
                systemctl start s-ui >/dev/null 2>&1 || true
            fi
        fi
        exit 1
    }
    chmod 755 "$INSTALL_DIR/sui"

    # The optional s-ui-<arch>.sh management helper is intentionally NOT
    # downloaded: the service does not need it, and it is one more network
    # round-trip on a host that can barely afford this one.

    echo "$VERSION" > "$INSTALL_DIR/version.txt"
    log_info "Installed s-ui $VERSION ($ARCH) to $INSTALL_DIR"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
do_uninstall() {
    log_info "Uninstalling s-ui..."

    case "$OS" in
        alpine)
            if rc-service s-ui status >/dev/null 2>&1; then
                rc-service s-ui stop 2>/dev/null || true
            fi
            rc-update del s-ui default 2>/dev/null || true
            rm -f "$INIT_SCRIPT"
            ;;
        debian)
            if systemctl is-active --quiet s-ui; then
                systemctl stop s-ui 2>/dev/null || true
            fi
            systemctl disable s-ui 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            systemctl daemon-reload 2>/dev/null || true
            ;;
    esac

    # The panel's database and settings live under $INSTALL_DIR/db -- the
    # binary resolves its data directory from argv[0], and $DATA_DIR (/etc/s-ui)
    # is a leftover from the community script that nothing reads. Asking about
    # "$DATA_DIR" *after* deleting $INSTALL_DIR therefore offered to preserve
    # something empty while the real database was already gone. Ask first, and
    # describe what is actually at stake.
    _keep_data=false
    if [ -d "$INSTALL_DIR/db" ]; then
        if [ -t 0 ] && [ -z "$ASSUME" ]; then
            printf "Keep the panel database (accounts, nodes, settings) in %s/db? [Y/n]: " "$INSTALL_DIR"
            read -r ans || true
            case "$ans" in
                n|N|no|NO) _keep_data=false ;;
                *)         _keep_data=true ;;
            esac
        else
            # No terminal (curl | sh, cron), or --yes/--no-prompt. Reading here
            # would consume the script's own source text out of the shell's
            # stdin buffer and corrupt the rest of the run, so take the default
            # that cannot lose data. --no-prompt does not mean "delete my
            # accounts": an unattended uninstall should still be recoverable.
            _keep_data=true
        fi
    fi

    if $_keep_data; then
        _backup_db="/root/s-ui-db-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$_backup_db"
        cp -a "$INSTALL_DIR/db/." "$_backup_db/" 2>/dev/null || true
        log_info "Database backed up to $_backup_db"
    fi

    # Takes $INSTALL_DIR/db and $CERT_DIR (the private key) with it.
    rm -rf "$INSTALL_DIR"

    if [ -d "$DATA_DIR" ]; then
        rm -rf "$DATA_DIR"
        log_info "Removed legacy directory $DATA_DIR"
    fi

    rm -f "$LOG_FILE"
    log_info "s-ui uninstalled successfully"
    exit 0
}

# ── Install service (OpenRC) ─────────────────────────────────────────────────
install_openrc_service() {
    log_info "Creating OpenRC service..."

    # Unquoted heredoc so $INSTALL_DIR and $LOG_FILE are substituted -- a
    # hardcoded /usr/local/s-ui broke --install-dir, leaving a service that
    # pointed at a directory the binaries were never written to.
    cat > "$INIT_SCRIPT" << INITEOF
#!/sbin/openrc-run

supervisor=supervise-daemon

name="s-ui"
description="s-ui Panel (Sing-Box based)"
command="$INSTALL_DIR/sui"
directory="$INSTALL_DIR"

output_log="$LOG_FILE"
error_log="$LOG_FILE"

# Go runtime guard (empty on hosts with plenty of RAM).
$GO_ENV_OPENRC

depend() {
    need net
    after firewall
}

start_pre() {
    if [ ! -d "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
    fi
}
INITEOF

    chmod +x "$INIT_SCRIPT"
    log_info "OpenRC service created at $INIT_SCRIPT"
}

# ── Install service (systemd) ────────────────────────────────────────────────
install_systemd_service() {
    log_info "Creating systemd service..."

    # Unquoted heredoc so $INSTALL_DIR and $LOG_FILE are substituted, so
    # --install-dir works. LimitNOFILE matches upstream's unit: a proxy holds
    # two descriptors per connection, and the default 1024 is reached by a few
    # hundred clients, after which sockets fail to open with no clear cause.
    cat > "$SERVICE_FILE" << SERVICEEOF
[Unit]
Description=s-ui Panel (Sing-Box based)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/sui
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
# Go runtime guard (empty on hosts with plenty of RAM).
$GO_ENV_SYSTEMD

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    log_info "systemd service created at $SERVICE_FILE"
}

# ── Install service ──────────────────────────────────────────────────────────
install_service() {
    case "$OS" in
        alpine) install_openrc_service ;;
        debian) install_systemd_service ;;
    esac
}

# ── Enable and start ─────────────────────────────────────────────────────────
enable_and_start() {
    case "$OS" in
        alpine)
            rc-update add s-ui default 2>/dev/null || {
                log_warn "s-ui already in default runlevel or rc-update failed"
            }
            log_info "Starting s-ui service..."
            rc-service s-ui start
            sleep 2
            if rc-service s-ui status; then
                SERVICE_OK=true
            else
                SERVICE_OK=false
            fi
            ;;
        debian)
            systemctl enable s-ui 2>/dev/null || {
                log_warn "s-ui already enabled or systemctl enable failed"
            }
            log_info "Starting s-ui service..."
            systemctl start s-ui
            sleep 2
            if systemctl is-active --quiet s-ui; then
                SERVICE_OK=true
            else
                SERVICE_OK=false
            fi
            ;;
    esac

    if $SERVICE_OK; then
        log_info "s-ui is running!"
        LOCAL_VER=$(cat "$INSTALL_DIR/version.txt" 2>/dev/null || echo "unknown")
        log_info "Version: $LOCAL_VER"
        log_info "Data directory: $DATA_DIR"
        log_info "Log file: $LOG_FILE"
    else
        log_error "s-ui failed to start. Check logs: $LOG_FILE"
        exit 1
    fi
}

# ── Service control ──────────────────────────────────────────────────────────
service_restart() {
    case "$OS" in
        alpine) rc-service s-ui restart >/dev/null 2>&1 || rc-service s-ui start ;;
        debian) systemctl restart s-ui ;;
    esac
}

# sui runs a subcommand against the installed binary. The binary resolves its
# database from the directory of argv[0], so /etc/s-ui (which the community
# script creates and this one kept) is not where the data lives.
sui() {
    # Short-lived CLI invocations (admin, setting -show) are Go processes too
    # and run OUTSIDE the service unit. Without the same guard they are exactly
    # the processes that get OOM-killed while the panel survives.
    if $LOW_MEM_ENABLED; then
        GOMEMLIMIT="$GO_MEM_LIMIT" GOGC="$GO_GC" GOMAXPROCS="$GO_MAXPROCS" \
            GODEBUG=madvdontneed=1 "$INSTALL_DIR/sui" "$@"
    else
        "$INSTALL_DIR/sui" "$@"
    fi
}

# ── Generate a random password ───────────────────────────────────────────────
# 24 chars from a charset with no shell or URL metacharacters, so the value
# survives being written into a URL and pasted into a terminal. Read from
# /dev/urandom, not $RANDOM: this protects an internet-facing panel.
random_password() {
    # `|| true` because dd exits as soon as it has its 24 bytes, which closes
    # the pipe under tr and makes the pipeline exit non-zero -- fatal under
    # set -e, and silent, since the password itself was produced correctly.
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | dd bs=1 count=24 2>/dev/null || true
}

# ── Random port above 20000 ──────────────────────────────────────────────────
random_port() {
    _n=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' ' || true)
    case "$_n" in
        ''|*[!0-9]*) _n=0 ;;
    esac
    echo $(( 20000 + (_n % 40000) ))
}

# ── Set the admin password ───────────────────────────────────────────────────
# The password is only known here, and s-ui stores a one-way hash, so this is
# the single chance to show it. Kept in a variable rather than re-read from the
# database, which holds no recoverable value.
set_admin_password() {
    ADMIN_PASS=$(random_password)
    if [ ${#ADMIN_PASS} -lt 24 ]; then
        log_error "Failed to generate a random password (/dev/urandom unavailable)"
        exit 1
    fi

    log_info "Setting a random password for the '$ADMIN_USER' account..."
    if sui admin -username "$ADMIN_USER" -password "$ADMIN_PASS" >/dev/null 2>&1; then
        ADMIN_PASS_SET=true
        log_info "Admin password updated"
    else
        ADMIN_PASS_SET=false
        log_error "Failed to set the admin password. Set it manually with:"
        log_error "  $INSTALL_DIR/sui admin -username $ADMIN_USER -password <newpassword>"
    fi
}

# ── Generate a self-signed certificate ───────────────────────────────────────
# The key is generated as a NAMED curve on purpose. OpenSSL in Alpine is
# LibreSSL, and a plain "-newkey ec" there writes the curve as explicit
# parameters, which Go's crypto/x509 refuses: s-ui then cannot load the pair
# and every TLS-bound inbound fails with "x509: invalid ECDSA parameters".
# Named-curve output is byte-identical in intent on OpenSSL 3 (Debian/Ubuntu).
generate_cert() {
    mkdir -p "$CERT_DIR" || return 1
    chmod 700 "$CERT_DIR"

    log_info "Generating a self-signed certificate in $CERT_DIR ..."
    # Both files are removed up front. A pair left over from an earlier run
    # would otherwise satisfy the "does the crt exist" check below while its
    # key is missing or does not match, and the panel accepts that save and
    # then fails to load the certificate.
    rm -f "$CERT_DIR/self.key" "$CERT_DIR/self.crt"

    if ! openssl ecparam -name prime256v1 -genkey -noout -param_enc named_curve \
            -out "$CERT_DIR/self.key" 2>/dev/null; then
        log_error "Failed to generate the private key"
        return 1
    fi
    if ! openssl req -x509 -new -nodes -days 3650 \
            -key "$CERT_DIR/self.key" \
            -out "$CERT_DIR/self.crt" \
            -subj "/CN=myserver" 2>/dev/null; then
        log_error "Failed to generate the certificate"
        rm -f "$CERT_DIR/self.key" "$CERT_DIR/self.crt"
        return 1
    fi

    # Verified as a pair, not file-by-file: openssl will happily write a cert
    # from a key, and the panel needs both to be present and consistent.
    if ! openssl x509 -in "$CERT_DIR/self.crt" -noout -pubkey >/dev/null 2>&1; then
        log_error "The generated certificate is not readable"
        rm -f "$CERT_DIR/self.key" "$CERT_DIR/self.crt"
        return 1
    fi

    # The private key is as sensitive as the admin password.
    chmod 600 "$CERT_DIR/self.key" "$CERT_DIR/self.crt"

    CERT_CRT="$CERT_DIR/self.crt"
    CERT_KEY="$CERT_DIR/self.key"
    log_info "Certificate: $CERT_CRT"
    log_info "Private key: $CERT_KEY"
    return 0
}

# ── Panel HTTP client ────────────────────────────────────────────────────────
# Every request carries X-Requested-With, which the panel's SameOrigin CSRF
# middleware accepts in place of an Origin/Referer match, and the session
# cookie saved at login. curl is used because busybox wget (Alpine's default)
# has no cookie jar at all.
# API_BASE already carries the "api/" segment. Every endpoint hangs off it, so
# a bare "$PANEL_PATH$action" would land on the SPA's catch-all route and come
# back as HTML with a 200, which reads as success to anything but a JSON check.
API_BASE=""
COOKIE_JAR=""

panel_request() {
    _method="$1"; shift
    _path="$1"; shift
    curl -sk -m 20 -X "$_method" \
        -H "X-Requested-With: XMLHttpRequest" \
        -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
        "$API_BASE$_path" "$@" 2>/dev/null
}

# panel_login waits for the panel to answer at all -- TLS finishes coming up a
# moment after the service reports started. The session is written to
# COOKIE_JAR, so a later step can reuse it instead of logging in again.
#
# The retry only covers the panel not being ready yet. An *answered* rejection
# is returned immediately: the panel counts failed logins per source address
# and locks the address out for 10 minutes after 10 of them, so retrying a
# wrong password 20 times would lock out 127.0.0.1 and make every later call in
# this run fail too. A rejected login means the credentials need looking at,
# not that the panel is still starting.
panel_login() {
    _i=0
    while [ "$_i" -lt 20 ]; do
        # curl exits non-zero on a connection refused while TLS is still coming
        # up, which set -e would take as fatal.
        _out=$(panel_request POST "login" -d "user=$ADMIN_USER" --data-urlencode "pass=$ADMIN_PASS" || true)
        case "$_out" in
            *'"success":true'*) return 0 ;;
            # Any JSON at all means the panel answered, so retrying cannot help.
            *'"success":false'*)
                log_error "The panel rejected the login: $(echo "$_out" | head -c 160)"
                return 1
                ;;
        esac
        _i=$(( _i + 1 ))
        sleep 1
    done
    log_error "The panel did not answer on $API_BASE"
    return 1
}

# ensure_session logs in unless a live session is already in the jar. A panel
# restart drops every session, so this is checked rather than assumed.
ensure_session() {
    _out=$(panel_request GET "status" || true)
    case "$_out" in
        *'"success":true'*) return 0 ;;
    esac
    panel_login
}

# panel_save posts one object to the panel's save endpoint. s-ui builds the
# derived data (out_json, subscription links) and reloads sing-box inside this
# call, so writing the database directly would produce a node that exists but
# carries no usable link.
# Save responses can contain inbound passwords; never include them in logs.
panel_save() {
    _object="$1"; _action="$2"; _data="$3"
    panel_request POST "save" \
        --data-urlencode "object=$_object" \
        --data-urlencode "action=$_action" \
        --data-urlencode "data=$_data" \
        --data-urlencode "initUsers=" || true
}

# ── Panel HTTPS with client-compatible HTTP subscriptions ──────────────────────────
# Probe before login so rerunning the installer also works on HTTPS installs.
detect_panel_transport() {
    for _scheme_probe in https http; do
        _probe=$(curl -sk --connect-timeout 1 --max-time 3 \
            -H 'X-Requested-With: XMLHttpRequest' \
            "$_scheme_probe://127.0.0.1:$PANEL_PORT${PANEL_PATH}api/status" 2>/dev/null) || continue
        if printf '%s' "$_probe" | jq -e 'has("success")' >/dev/null 2>&1; then
            API_BASE="$_scheme_probe://127.0.0.1:$PANEL_PORT${PANEL_PATH}api/"
            PANEL_TLS=false
            [ "$_scheme_probe" != https ] || PANEL_TLS=true
            return 0
        fi
    done
    return 1
}

configure_web_transport() {
    _web_scheme="$1"
    case "$_web_scheme" in https|http) ;; *) return 1 ;; esac
    _transport_response=$(panel_request GET settings) || return 1
    _transport_settings=$(printf '%s' "$_transport_response" | jq -ce 'select(.success == true) | .obj') || return 1
    _transport_sub_port=$(printf '%s' "$_transport_settings" | jq -r '.subPort // "2096"')
    _transport_sub_listen=$(printf '%s' "$_transport_settings" | jq -r '.subListen // empty')
    _transport_web_listen=$(printf '%s' "$_transport_settings" | jq -r '.webListen // empty')
    _transport_sub_domain=$(printf '%s' "$_transport_settings" | jq -r '.subDomain // empty')
    _transport_web_domain=$(printf '%s' "$_transport_settings" | jq -r '.webDomain // empty')
    if [ "$_web_scheme" = https ]; then
        [ -n "$CERT_CRT" ] && [ -n "$CERT_KEY" ] || return 1
        _transport_cert="$CERT_CRT"; _transport_key="$CERT_KEY"
    else
        _transport_cert=""; _transport_key=""
    fi
    _transport_payload=$(printf '%s' "$_transport_settings" | jq -c \
        --arg cert "$_transport_cert" --arg key "$_transport_key" --arg scheme "$_web_scheme" '
        {webCertFile:$cert,webKeyFile:$key,subCertFile:"",subKeyFile:"",
         subURI:((.subURI // "") | sub("^https?://"; "http://")),
         webURI:((.webURI // "") | sub("^https?://"; $scheme + "://"))}') || return 1
    _out=$(panel_save settings "" "$_transport_payload")
    printf '%s' "$_out" | jq -e '.success == true' >/dev/null || return 1
    # The four certificate fields are saved in one transaction, then both
    # listeners are restarted together. Never advertise an unverified scheme.
    service_restart || return 1
    API_BASE="$_web_scheme://127.0.0.1:$PANEL_PORT${PANEL_PATH}api/"
    _transport_attempt=0
    while [ "$_transport_attempt" -lt 10 ]; do
        if verify_web_transport; then
            PANEL_TLS=false
            [ "$_web_scheme" != https ] || PANEL_TLS=true
            # Refresh the summary even when switching an existing client from
            # HTTPS back to HTTP in the same script session.
            _transport_effective=$(printf '%s' "$_transport_settings" | jq -c --argjson changes "$_transport_payload" '. + $changes') || return 1
            read_subscription_address "$_transport_effective"
            log_info "Panel uses $_web_scheme; subscriptions use http"
            return 0
        fi
        _transport_attempt=$(( _transport_attempt + 1 ))
        sleep 1
    done
    log_error "Could not verify panel $_web_scheme and subscription HTTP listeners"
    return 1
}

verify_web_transport() {
    _transport_panel_host="$_transport_web_listen"
    _transport_sub_host="$_transport_sub_listen"
    case "$_transport_panel_host" in ''|0.0.0.0|::) _transport_panel_host=127.0.0.1 ;; esac
    case "$_transport_sub_host" in ''|0.0.0.0|::) _transport_sub_host=127.0.0.1 ;; esac
    case "$_transport_panel_host" in *:*) _transport_panel_host="[$_transport_panel_host]" ;; esac
    case "$_transport_sub_host" in *:*) _transport_sub_host="[$_transport_sub_host]" ;; esac
    # Any HTTP response proves a listener exists; even a Host rejection/404 is
    # sufficient here. HTTPS must complete its TLS handshake, not just redirect.
    curl -q -sk --noproxy '*' --connect-timeout 1 --max-time 2 -o /dev/null \
        -H "Host: ${_transport_web_domain:-localhost}" \
        "$_web_scheme://$_transport_panel_host:$PANEL_PORT/" 2>/dev/null || return 1
    curl -q -sk --noproxy '*' --connect-timeout 1 --max-time 2 -o /dev/null \
        -H "Host: ${_transport_sub_domain:-localhost}" \
        "http://$_transport_sub_host:$_transport_sub_port/" 2>/dev/null || return 1
    if [ "$_web_scheme" = http ]; then
        # A TLS listener may redirect plaintext HTTP; wait until TLS really is
        # off, so a restart in progress cannot masquerade as an HTTP listener.
        if curl -q -sk --noproxy '*' --connect-timeout 1 --max-time 2 -o /dev/null \
            "https://$_transport_panel_host:$PANEL_PORT/" 2>/dev/null; then return 1; fi
    fi
    # Subscriptions must really be HTTP, even while the panel uses HTTPS.
    if curl -q -sk --noproxy '*' --connect-timeout 1 --max-time 2 -o /dev/null \
        "https://$_transport_sub_host:$_transport_sub_port/" 2>/dev/null; then return 1; fi
    return 0
}

# ── Pick a random decoy SNI ──────────────────────────────────────────────────
# Shared by the Hysteria2 and VLESS+Reality deployments. Returns the chosen
# hostname through the global SNI.
pick_sni() {
    # Counted rather than hardcoded so adding a name to SNI_POOL does not skew
    # the odds. The same awk draw that reads the seed at call time sees exactly
    # one SNI value per line.
    _n=$(for _s in $SNI_POOL; do printf '%s\n' "$_s"; done | wc -l | tr -d ' ')
    SNI=$(for _s in $SNI_POOL; do printf '%s\n' "$_s"; done | awk -v n="$_RAND" -v c="$_n" 'NR==(n%c)+1')
    # A draw that yields nothing (empty pool, or awk comparing against an empty
    # seed and matching no record) exits 0 and prints an empty string. That
    # would post a TLS record with "server_name":"" and still report success, so
    # fall back to the first name rather than deploy a node with no SNI.
    if [ -z "$SNI" ]; then
        SNI=$(for _s in $SNI_POOL; do printf '%s\n' "$_s"; done | head -1)
    fi
    if [ -z "$SNI" ]; then
        log_error "No SNI available to use (SNI_POOL is empty)"
        return 1
    fi
    return 0
}

# ── Deploy a Hysteria2 inbound ───────────────────────────────────────────────
deploy_hysteria2() {
    _port=$(choose_node_port Hy2 "$REQUESTED_HY2_PORT" "$(random_port)") || return 1
    if ! pick_sni; then
        return 1
    fi
    _sni="$SNI"

    # Never create an unobfuscated inbound if secure randomness is unavailable.
    # This password is independent of admin credentials and client authentication.
    _obfs_pass=$(random_password)
    if [ ${#_obfs_pass} -ne 24 ]; then
        log_error "Failed to generate a Salamander password; skipping Hysteria2"
        return 1
    fi

    log_info "Deploying a Hysteria2 node with Salamander..."
    log_info "  Port: $_port  SNI: $_sni"

    # 1. TLS config: the certificate, the forged SNI, and "allow insecure" on
    #    the client side. That last flag is client.insecure -- the inbound's own
    #    TLS block has no such field, and sing-box would reject an unknown key.
    _tls="{\"id\":0,\"name\":\"hy2-tls\",\"server\":{\"enabled\":true,\"server_name\":\"$_sni\",\"alpn\":[\"h3\"],\"certificate_path\":\"$CERT_CRT\",\"key_path\":\"$CERT_KEY\"},\"client\":{\"insecure\":true}}"
    _out=$(panel_save tls new "$_tls")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            log_error "Failed to create the TLS config"
            return 1
            ;;
    esac

    # The save returns every TLS object; select the newest record, not the
    # first array entry (which may belong to another protocol or earlier run).
    _tls_id=$(printf '%s' "$_out" | jq -er '.obj.tls | max_by(.id) | .id' 2>/dev/null) || return 1

    case "$_tls_id" in
        ''|*[!0-9]*)
            log_error "Could not determine the new TLS config id"
            return 1
            ;;
    esac
    log_info "  TLS config id: $_tls_id"

    # 2. The inbound itself. The tag is unique and carries the port, so a
    #    second run makes a new node instead of colliding with this one.
    _tag="$HY2_TAG_PREFIX-$_port"
    _inb="{\"id\":0,\"type\":\"hysteria2\",\"tag\":\"$_tag\",\"tls_id\":$_tls_id,\"listen\":\"::\",\"listen_port\":$_port,\"obfs\":{\"type\":\"salamander\",\"password\":\"$_obfs_pass\"},\"addrs\":[],\"out_json\":{}}"
    _out=$(panel_save inbounds new "$_inb")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            # The response may echo the inbound, including its obfuscation password.
            log_error "Failed to create the Hysteria2 inbound"
            return 1
            ;;
    esac

    HY2_PORT="$_port"
    HY2_SNI="$_sni"
    HY2_TAG="$_tag"
    HY2_OK=true
    log_info "Hysteria2 node created: $_tag"
    return 0
}

# ── Generate a Reality keypair ───────────────────────────────────────────────
# Asked of the panel, not computed locally: the panel's api/keypairs endpoint
# (k=reality) uses the same golang.org/x/crypto wg-style X25519 generator s-ui
# itself uses, and reproducing that curve in shell would mean either shipping a
# second binary or trusting a hand-rolled Base64url encoder.
# Reads PRIVATE_KEY and PUBLIC_KEY.
generate_reality_keypair() {
    # curl -k: on a panel running the self-signed HTTPS certificate (--yes).
    _out=$(panel_request GET "keypairs?k=reality")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            log_error "Failed to generate the Reality keypair: $(echo "$_out" | head -c 200)"
            return 1
            ;;
    esac

    # Response: {"success":true,"msg":"","obj":["PrivateKey: ...","PublicKey: ..."]}.
    # The keys are X25519 in Base64url without padding. sed is limited to the
    # two known line prefixes rather than "first string in obj", so a change in
    # the response's other fields cannot echo its way into a private key.
    PRIVATE_KEY=$(echo "$_out" | sed -n 's/.*"PrivateKey: \([^"]*\)".*/\1/p')
    PUBLIC_KEY=$(echo "$_out" | sed -n 's/.*"PublicKey: \([^"]*\)".*/\1/p')

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        log_error "Could not read the Reality keypair from the panel response"
        return 1
    fi
    return 0
}

# ── Generate a random Reality short_id ───────────────────────────────────────
# One hex byte is enough and matches what the panel's own randomShortId()
# produces most often (one random octet, zero-padded). Read from /dev/urandom,
# guarded like every other od call under set -e.
random_short_id() {
    _b=$(od -An -N1 -tu1 < /dev/urandom 2>/dev/null | tr -d ' ' || true)
    case "$_b" in
        ''|*[!0-9]*) _b=0 ;;
    esac
    printf '%02x' "$_b"
}

# ── Deploy a VLESS + Reality inbound ────────────────────────────────────────
# Reality needs no certificate at all: the server borrows the handshake of
# whatever site the SNI names, so there is nothing self-signed to pin or trust.
# What the client needs off-band is the server's public key (pbk) and a short
# id (sid); s-ui carries both in the TLS record it writes the subscription
# link from, so the link picks them up automatically.
deploy_vless_reality() {
    _port=$(choose_node_port VLESS "$REQUESTED_VLESS_PORT" 443) || return 1
    if ! pick_sni; then
        return 1
    fi
    _sni="$SNI"
    if ! generate_reality_keypair; then
        return 1
    fi
    _sid=$(random_short_id)

    log_info "Deploying a VLESS + Reality node..."
    log_info "  Port: $_port  SNI: $_sni"

    # 1. TLS config. Server side: reality enabled, with a handshake target --
    #    the site the forged handshakes are proxied to, which must accept
    #    TLS 1.3 with h2, i.e. anything the SNI pool names safely. Client side:
    #    the matching public key, one short id, and the uTLS fingerprint that
    #    makes the client's handshake indistinguishable from Chrome's.
    _tls="{\"id\":0,\"name\":\"vless-reality-tls\",\"server\":{\"enabled\":true,\"server_name\":\"$_sni\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"$_sni\",\"server_port\":443},\"private_key\":\"$PRIVATE_KEY\",\"short_id\":[\"$_sid\"]}},\"client\":{\"reality\":{\"enabled\":true,\"public_key\":\"$PUBLIC_KEY\",\"short_id\":\"$_sid\"},\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}}}"
    _out=$(panel_save tls new "$_tls")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            log_error "Failed to create the Reality TLS config"
            return 1
            ;;
    esac

    # The save returns every TLS object; select the newest record, not the
    # first array entry (which may belong to another protocol or earlier run).
    _tls_id=$(printf '%s' "$_out" | jq -er '.obj.tls | max_by(.id) | .id' 2>/dev/null) || return 1

    case "$_tls_id" in
        ''|*[!0-9]*)
            log_error "Could not determine the new Reality TLS config id"
            return 1
            ;;
    esac
    log_info "  Reality TLS config id: $_tls_id"

    # 2. The inbound itself. TCP, no transport -- which is also what lets the
    #    users carry the xtls-rprx-vision flow that Reality is normally paired
    #    with, and what genLink checks for when it writes the "flow" parameter.
    #    The panel fills out_json (the client-side config) from this record
    #    plus the TLS config above; no users are attached, same as the hy2
    #    path.
    _tag="$VLESS_TAG_PREFIX-$_port"
    _inb="{\"id\":0,\"type\":\"vless\",\"tag\":\"$_tag\",\"tls_id\":$_tls_id,\"listen\":\"::\",\"listen_port\":$_port,\"addrs\":[],\"out_json\":{}}"
    _out=$(panel_save inbounds new "$_inb")
    case "$_out" in
        *'"success":true'*) ;;
        *)
            log_error "Failed to create the VLESS inbound"
            return 1
            ;;
    esac

    VLESS_PORT="$_port"
    VLESS_SNI="$_sni"
    VLESS_TAG="$_tag"
    VLESS_PUBLIC_KEY="$PUBLIC_KEY"
    VLESS_SHORT_ID="$_sid"
    VLESS_OK=true
    log_info "VLESS + Reality node created: $_tag"
    return 0
}

# ── Read the panel's own address ─────────────────────────────────────────────
# Asked of the binary rather than assumed: webPort/webPath are panel settings a
# previous install may have changed. `sui setting -show` prints them without
# needing sqlite3, which is not on Alpine by default.
read_panel_address() {
    _show=$(sui setting -show 2>/dev/null || true)
    PANEL_PORT=$(echo "$_show" | awk -F'\t' '/Panel port:/{print $NF}' | tr -d ' ')
    SUB_PORT=$(echo "$_show" | awk -F'\t' '/Sub port:/{print $NF}' | tr -d ' ')
    PANEL_PATH=$(echo "$_show" | awk -F'\t' '/Panel path:/{print $NF}' | tr -d ' ')

    PANEL_PORT=$(normalize_port "${PANEL_PORT:-2095}") || PANEL_PORT=2095
    SUB_PORT=$(normalize_port "${SUB_PORT:-2096}") || SUB_PORT=2096
    case "$PANEL_PATH" in
        /*) ;;
        *) PANEL_PATH="/app/" ;;
    esac
    case "$PANEL_PATH" in
        */) ;;
        *) PANEL_PATH="$PANEL_PATH/" ;;
    esac
}

# Normalize addresses for deduplication, including equivalent IPv6 spellings.
# Reject error pages, malformed addresses, loopback and link-local addresses.
# An optional family (4 or 6) restricts a public-IP response to that family.
normalize_summary_addresses() {
    awk -v family="${1:-}" -v public_only="${2:-false}" '
    function ipv4(s, a, n, i, out) {
        n = split(s, a, ".")
        if (n != 4) return ""
        out = ""
        for (i = 1; i <= n; i++) {
            if (a[i] !~ /^[0-9]+$/ || length(a[i]) > 3 || a[i] + 0 > 255) return ""
            out = out (i > 1 ? "." : "") (a[i] + 0)
        }
        return out
    }
    function ipv6(s, a, halves, n, left, right, missing, i, part, out, v4, octets) {
        s = tolower(s)
        # Expand an IPv4 tail to two hextets before normalizing.
        if (s ~ /\./) {
            n = split(s, a, ":")
            v4 = ipv4(a[n])
            if (v4 == "") return ""
            split(v4, octets, ".")
            sub(/[^:]+$/, sprintf("%x:%x", octets[1]*256+octets[2], octets[3]*256+octets[4]), s)
        }
        if (s !~ /^[0-9a-f:]+$/) return ""
        n = split(s, halves, "::")
        if (n > 2) return ""
        if (n == 2) {
            left = halves[1] == "" ? 0 : split(halves[1], a, ":")
            right = halves[2] == "" ? 0 : split(halves[2], a, ":")
            missing = 8 - left - right
            if (missing < 1) return ""
            s = halves[1]
            for (i = 0; i < missing; i++) s = s (s == "" ? "" : ":") "0"
            if (right) s = s ":" halves[2]
        }
        n = split(s, a, ":")
        if (n != 8) return ""
        out = ""
        for (i = 1; i <= n; i++) {
            part = a[i]
            if (part == "" || length(part) > 4) return ""
            sub(/^0+/, "", part)
            if (part == "") part = "0"
            out = out (i > 1 ? ":" : "") part
        }
        return out
    }
    function public4(s, a) {
        split(s, a, ".")
        return !(a[1] == 0 || a[1] == 10 || a[1] == 127 || a[1] >= 224 ||
            (a[1] == 100 && a[2] >= 64 && a[2] <= 127) ||
            (a[1] == 169 && a[2] == 254) ||
            (a[1] == 172 && a[2] >= 16 && a[2] <= 31) ||
            (a[1] == 192 && (a[2] == 168 || (a[2] == 0 && (a[3] == 0 || a[3] == 2)) || (a[2] == 88 && a[3] == 99))) ||
            (a[1] == 198 && (a[2] == 18 || a[2] == 19 || (a[2] == 51 && a[3] == 100))) ||
            (a[1] == 203 && a[2] == 0 && a[3] == 113))
    }
    function public6(s, a) {
        split(s, a, ":")
        # Conservatively accept native global unicast only. Exclude special
        # 2001::/23, documentation, deprecated 6to4 and reserved ranges.
        return a[1] ~ /^[23][0-9a-f][0-9a-f][0-9a-f]$/ &&
            !(a[1] == "2001" && (length(a[2]) < 3 || a[2] ~ /^1[0-9a-f][0-9a-f]$/ || a[2] == "db8")) &&
            a[1] != "2002" && a[1] != "3fff"
    }
    {
        for (field = 1; field <= NF; field++) {
            addr = $field
            if (index(addr, ":")) {
                if (family == "4") continue
                key = ipv6(addr)
                if (key == "" || key == "0:0:0:0:0:0:0:0" || key == "0:0:0:0:0:0:0:1" || key ~ /^fe[89ab][0-9a-f]:/ || key ~ /^ff[0-9a-f][0-9a-f]:/) continue
                if (public_only == "true" && !public6(key)) continue
                host = "[" tolower(addr) "]"
            } else {
                if (family == "6") continue
                key = ipv4(addr)
                if (key == "" || key ~ /^(0|127)\./ || key ~ /^169\.254\./) continue
                if (public_only == "true" && !public4(key)) continue
                host = key
            }
            if (!seen[key]++) print host
        }
    }'
}

# Public addresses come first, followed by all interface addresses. Each probe
# has a short timeout and discards even partial output on failure. No failures
# are logged, and no extra dependencies are installed just to discover an IP.
collect_summary_addresses() {
    {
        discover_public_addresses
        printf '%s\n' "$PUBLIC_IPV4" "$PUBLIC_IPV6"
        _interface_ips=$(ip -o addr show scope global 2>/dev/null | \
            awk '$3 == "inet" || $3 == "inet6" { sub(/\/.*/, "", $4); print $4 }')
        if [ -n "$_interface_ips" ]; then
            printf '%s\n' "$_interface_ips"
        else
            hostname -I 2>/dev/null || true
        fi
    } | normalize_summary_addresses
}

# ── Optional ready-to-use Clash subscription ────────────────────────────────
# Ensure jq is present when this helper is sourced independently for repair
# or tests; the normal installer already installs it in check_deps().
ensure_subscription_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    log_info "Installing jq for subscription setup..."
    case "$OS" in
        alpine) apk add --no-cache jq || return 1 ;;
        debian) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Use-Pty=0 jq || return 1 ;;
        *) return 1 ;;
    esac
    command -v jq >/dev/null 2>&1
}

discover_public_addresses() {
    [ "${PUBLIC_IPS_READY:-false}" = true ] && return 0
    PUBLIC_IPV4=$(curl -q -4 -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
        --max-filesize 128 --retry 0 https://api.ipify.org 2>/dev/null) || PUBLIC_IPV4=""
    PUBLIC_IPV4=$(printf '%s\n' "$PUBLIC_IPV4" | normalize_summary_addresses 4 true | head -1)
    PUBLIC_IPV6=$(curl -q -6 -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
        --max-filesize 128 --retry 0 https://api6.ipify.org 2>/dev/null) || PUBLIC_IPV6=""
    PUBLIC_IPV6=$(printf '%s\n' "$PUBLIC_IPV6" | normalize_summary_addresses 6 true | head -1 | tr -d '[]')
    PUBLIC_IPS_READY=true
}

# Lookup the chosen address, not the API connection's possibly different exit.
# All failures (including HTTP 200 + success:false) keep the generic name.
lookup_node_label() {
    NODE_LABEL="🚀 加速节点"
    [ -n "$SUB_PUBLIC_HOST" ] || return 0
    _geo=$(curl -q -fsS --noproxy '*' --connect-timeout 2 --max-time 4 \
        --max-filesize 4096 --retry 0 \
        "https://ipwho.is/$SUB_PUBLIC_HOST?lang=zh-CN&fields=success,ip,country,country_code,flag.emoji" \
        2>/dev/null) || return 0
    _geo_ip=$(printf '%s' "$_geo" | jq -er '.ip | select(type == "string")' 2>/dev/null) || return 0
    [ -n "$(printf '%s' "$_geo_ip" | normalize_summary_addresses '' true)" ] || return 0
    _same_ip_count=$(printf '%s\n%s\n' "$SUB_PUBLIC_HOST" "$_geo_ip" | normalize_summary_addresses '' true | wc -l | tr -d ' ')
    [ "$_same_ip_count" = 1 ] || return 0
    _label=$(printf '%s' "$_geo" | jq -er '
        select(.success == true) |
        select(.country_code | type == "string" and test("^[A-Z]{2}$")) |
        select(.country | type == "string" and length > 0 and length < 80 and (test("[\\u0000-\\u001f]") | not)) |
        select(.flag.emoji | type == "string" and length == 2) |
        "\(.flag.emoji)\(.country)节点"' 2>/dev/null) || return 0
    NODE_LABEL="$_label"
}

clash_subscription_template() {
    cat <<'CLASH_TEMPLATE'
tun:
  enable: true
  auto-route: true
  dns-hijack:
  - any:53
  - tcp://any:53
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  respect-rules: false
  prefer-h3: false
  proxy-server-nameserver:
  - https://120.53.53.53/dns-query
  - https://223.6.6.6/dns-query
  - 119.29.29.29
  - 223.5.5.5
  direct-nameserver:
  - https://120.53.53.53/dns-query
  - https://223.6.6.6/dns-query
  - 119.29.29.29
  - 223.5.5.5
  direct-nameserver-follow-policy: true
  nameserver-policy:
    rule-set:private:
    - system
    +.cn:
    - https://120.53.53.53/dns-query
    - https://223.6.6.6/dns-query
    - 119.29.29.29
    - 223.5.5.5
    rule-set:direct:
    - https://120.53.53.53/dns-query
    - https://223.6.6.6/dns-query
    - 119.29.29.29
    - 223.5.5.5
  nameserver:
  - https://1.1.1.1/dns-query#RULES
  - https://8.8.8.8/dns-query#RULES
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: 127.0.0.1:9090
proxy-groups:
- name: 🚀 节点选择
  type: select
  proxies:
  - all
  - DIRECT
- name: ☁️ iCloud
  type: select
  proxies:
  - DIRECT
  - 🚀 节点选择
- name: 🍎 Apple
  type: select
  proxies:
  - DIRECT
  - 🚀 节点选择
- name: 💻 Microsoft
  type: select
  proxies:
  - DIRECT
  - 🚀 节点选择
- name: 🎮 Steam 大陆访问
  type: select
  proxies:
  - DIRECT
  - 🚀 节点选择
- name: 📚 科研资源
  type: select
  proxies:
  - DIRECT
  - 🚀 节点选择
- name: 💬 AI 平台
  type: select
  proxies:
  - 🚀 节点选择
  - DIRECT
- name: 🚀 境外网站
  type: select
  proxies:
  - 🚀 节点选择
  - DIRECT
- name: 🛑 广告拦截
  type: select
  proxies:
  - REJECT
  - DIRECT
- name: 🇨🇳 国内应用
  type: select
  proxies:
  - DIRECT
  - 🚀 节点选择
- name: 🇨🇳 国内网段
  type: select
  proxies:
  - DIRECT
  - 🚀 节点选择
- name: 🐟 漏网之鱼
  type: select
  proxies:
  - 🚀 节点选择
  - DIRECT
rule-providers:
  reject:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/reject.txt
    path: ./ruleset/reject.yaml
    interval: 86400
  icloud:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/icloud.txt
    path: ./ruleset/icloud.yaml
    interval: 86400
  apple:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/apple.txt
    path: ./ruleset/apple.yaml
    interval: 86400
  microsoft:
    type: http
    behavior: classical
    url: https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Microsoft/Microsoft.yaml
    path: ./ruleset/microsoft.yaml
    interval: 86400
  steamcn:
    type: http
    behavior: classical
    url: https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/SteamCN/SteamCN.yaml
    path: ./ruleset/steamcn.yaml
  proxy:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/proxy.txt
    path: ./ruleset/proxy.yaml
    interval: 86400
  direct:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/direct.txt
    path: ./ruleset/direct.yaml
    interval: 86400
  private:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/private.txt
    path: ./ruleset/private.yaml
    interval: 86400
  cncidr:
    type: http
    behavior: ipcidr
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/cncidr.txt
    path: ./ruleset/cncidr.yaml
    interval: 86400
  lancidr:
    type: http
    behavior: ipcidr
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/lancidr.txt
    path: ./ruleset/lancidr.yaml
    interval: 86400
  applications:
    type: http
    behavior: classical
    url: https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/applications.txt
    path: ./ruleset/applications.yaml
    interval: 86400
  scholar-intl:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-scholar-!cn.yaml
    path: ./ruleset/scholar-intl.yaml
    interval: 86400
  ai-intl:
    type: http
    behavior: domain
    url: https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/category-ai-!cn.yaml
    path: ./ruleset/ai-intl.yaml
    interval: 86400
rules:
- RULE-SET,reject,🛑 广告拦截
- RULE-SET,icloud,☁️ iCloud
- RULE-SET,apple,🍎 Apple
- RULE-SET,microsoft,💻 Microsoft
- RULE-SET,steamcn,🎮 Steam 大陆访问
- RULE-SET,scholar-intl,📚 科研资源
- RULE-SET,ai-intl,💬 AI 平台
- DOMAIN-SUFFIX,auth0.com,💬 AI 平台
- DOMAIN-SUFFIX,challenges.cloudflare.com,💬 AI 平台
- DOMAIN-SUFFIX,client-api.arkoselabs.com,💬 AI 平台
- DOMAIN-SUFFIX,events.statsigapi.net,💬 AI 平台
- DOMAIN-SUFFIX,featuregates.org,💬 AI 平台
- DOMAIN-SUFFIX,identrust.com,💬 AI 平台
- DOMAIN-SUFFIX,intercom.io,💬 AI 平台
- DOMAIN-SUFFIX,intercomcdn.com,💬 AI 平台
- DOMAIN-SUFFIX,stripe.com,💬 AI 平台
- RULE-SET,proxy,🚀 境外网站
- RULE-SET,cncidr,🇨🇳 国内网段
- RULE-SET,applications,🇨🇳 国内应用
- RULE-SET,direct,DIRECT
- RULE-SET,lancidr,DIRECT
- RULE-SET,private,DIRECT
- GEOIP,LAN,DIRECT
- GEOIP,CN,DIRECT
- MATCH,🐟 漏网之鱼
CLASH_TEMPLATE
}

create_subscription_client() {
    ensure_subscription_jq || { log_warn "Could not install jq; skipping subscription setup"; return 1; }
    ensure_session || return 1
    _inbound_response=$(panel_request GET inbounds) || return 1
    _inbounds=$(printf '%s' "$_inbound_response" | jq -ce '
        select(.success == true) | .obj.inbounds | select(type == "array" and length > 0)') || {
        log_warn "No inbounds available; create an inbound before creating a subscription client"
        return 1
    }
    _ids=$(printf '%s' "$_inbounds" | jq -r 'map(.id|tostring)|join(",")') || return 1
    _full_response=$(panel_request GET "inbounds?id=$_ids") || return 1
    _inbounds=$(printf '%s' "$_full_response" | jq -ce 'select(.success == true) | .obj.inbounds | select(type == "array" and length > 0)') || return 1
    _settings_response=$(panel_request GET settings) || return 1
    _settings=$(printf '%s' "$_settings_response" | jq -ce 'select(.success == true) | .obj | select(type == "object")') || return 1

    discover_public_addresses
    SUB_PUBLIC_HOST="${PUBLIC_IPV4:-$PUBLIC_IPV6}"
    lookup_node_label

    # A random name also makes the subscription URL difficult to guess.
    _client_name=$(random_password)
    _client_pass=$(random_password)
    _uuid_hex=$(openssl rand -hex 16 2>/dev/null) || return 1
    _ss16=$(openssl rand -base64 16 2>/dev/null) || return 1
    _ss32=$(openssl rand -base64 32 2>/dev/null) || return 1
    case "$_client_name$_client_pass" in *[!A-Za-z0-9]*) return 1 ;; esac
    [ ${#_client_name} -eq 24 ] && [ ${#_client_pass} -eq 24 ] && [ ${#_uuid_hex} -eq 32 ] || return 1
    _client_uuid=$(printf '%s' "$_uuid_hex" | sed 's/^\(........\)\(....\).\(...\).\(...\)\(............\)$/\1-\2-4\3-8\4-\5/')

    # Use the inbound tag itself for the display name: s-ui inserts a hyphen
    # between client remark and tag, so a client prefix cannot produce the
    # requested compact name exactly. Full objects preserve credentials/TLS.
    _named_inbounds=$(printf '%s' "$_inbounds" | jq -c --arg node_label "$NODE_LABEL" --arg host "$SUB_PUBLIC_HOST" '
        sort_by(.id) | reduce .[] as $inb ({counts:{},items:[]};
            ($inb.type) as $type |
            (.counts[$type] // 0) as $count |
            .counts[$type] = ($count + 1) |
            ({hysteria2:"Hy2",vless:"VLESS",vmess:"VMess",trojan:"Trojan",tuic:"TUIC",
              shadowsocks:"SS",anytls:"AnyTLS",hysteria:"Hy",socks:"SOCKS",http:"HTTP",mixed:"Mixed"}[$type] // $type) as $protocol |
            .items += [($inb |
                if $host != "" and ((.addrs // [])|length) == 0
                then .addrs = [{server:$host, server_port:.listen_port, remark:""}] else . end |
                .tag = ($node_label + (if ((.addrs[0].server // $host)|contains(":")) then " v6" else "" end) + " · " + $protocol +
                    (if $count == 0 then "" else " " + (($count + 1)|tostring) end)))]
        ) | .items') || return 1
    for _inbound_id in $(printf '%s' "$_named_inbounds" | jq -r '.[].id'); do
        _updated_inbound=$(printf '%s' "$_named_inbounds" | jq -c --argjson id "$_inbound_id" '.[] | select(.id == $id)') || return 1
        _saved=$(panel_save inbounds edit "$_updated_inbound")
        printf '%s' "$_saved" | jq -e '.success == true' >/dev/null || return 1
    done
    # Keep this run's node summary paired with its own port after renaming.
    _hy2_id=$(printf '%s' "$_inbounds" | jq -r --arg tag "${HY2_TAG:-}" '.[] | select(.tag == $tag) | .id' | head -1)
    _vless_id=$(printf '%s' "$_inbounds" | jq -r --arg tag "${VLESS_TAG:-}" '.[] | select(.tag == $tag) | .id' | head -1)
    if [ -n "$_hy2_id" ]; then
        HY2_TAG=$(printf '%s' "$_named_inbounds" | jq -r --argjson id "$_hy2_id" '.[] | select(.id == $id) | .tag')
    fi
    if [ -n "$_vless_id" ]; then
        VLESS_TAG=$(printf '%s' "$_named_inbounds" | jq -r --argjson id "$_vless_id" '.[] | select(.id == $id) | .tag')
    fi

    _client_json=$(printf '%s' "$_inbounds" | jq -c \
        --arg name "$_client_name" --arg pass "$_client_pass" --arg uuid "$_client_uuid" \
        --arg ss16 "$_ss16" --arg ss32 "$_ss32" '
        {enable:true, name:$name, remark:"", volume:0, expiry:0,
         inbounds:map(.id), links:[], config:{
            vless:{name:$name,uuid:$uuid,flow:"xtls-rprx-vision"},
            vmess:{name:$name,uuid:$uuid,alterId:0},
            trojan:{name:$name,password:$pass}, hysteria:{name:$name,auth_str:$pass},
            hysteria2:{name:$name,password:$pass}, tuic:{name:$name,uuid:$uuid,password:$pass},
            anytls:{name:$name,password:$pass}, shadowtls:{name:$name,password:$pass},
            socks:{username:$name,password:$pass}, http:{username:$name,password:$pass},
            mixed:{username:$name,password:$pass}, naive:{username:$name,password:$pass},
            shadowsocks:{name:$name,password:$ss32}, shadowsocks16:{name:$name,password:$ss16},
            snell:{name:$name,userkey:$ss32}
         }}') || return 1
    _saved=$(panel_save clients new "$_client_json")
    printf '%s' "$_saved" | jq -e '.success == true' >/dev/null || return 1
    read_subscription_address "$_settings"
    SUB_CLIENT_NAME="$_client_name"

    # Keep a root-only backup before replacing the panel-wide Clash template.
    (umask 077; printf '%s\n' "$_settings" | jq '{subClashExt,subClashNoDefGrp,subClashSprtAll}' > "$INSTALL_DIR/clash-template-backup-$_client_name.json") || return 1
    _template_settings=$(clash_subscription_template | jq -Rs '{subClashExt:.,subClashNoDefGrp:"true",subClashSprtAll:"true"}') || return 1
    _saved=$(panel_save settings "" "$_template_settings")
    if ! printf '%s' "$_saved" | jq -e '.success == true' >/dev/null; then
        log_warn "Client created, but the Clash template could not be saved"
        return 1
    fi
    log_info "Unlimited client created with all current inbounds and the Clash template"
}

read_subscription_address() {
    # subURI may contain the provider's public NAT mapping or reverse proxy.
    SUB_BASE_URI=$(printf '%s' "$1" | jq -r '.subURI // empty')
    SUB_PORT=$(printf '%s' "$1" | jq -r '.subPort // "2096"')
    SUB_PATH=$(printf '%s' "$1" | jq -r '.subPath // "/sub/"')
    case "$SUB_PATH" in /*) ;; *) SUB_PATH="/$SUB_PATH" ;; esac
    case "$SUB_PATH" in */) ;; *) SUB_PATH="$SUB_PATH/" ;; esac
    SUB_DOMAIN=$(printf '%s' "$1" | jq -r '.subDomain // empty')
    SUB_SCHEME=$(printf '%s' "$1" | jq -r 'if (.subCertFile // "") != "" and (.subKeyFile // "") != "" then "https" else "http" end')
    case "$SUB_BASE_URI" in '') ;; */) ;; *) SUB_BASE_URI="$SUB_BASE_URI/" ;; esac
}

print_subscription_urls() {
    [ -n "${SUB_CLIENT_NAME:-}" ] || return 0
    _sub_hosts=$(printf '%s\n' "$_hosts" | tr -d '[]' | normalize_summary_addresses '' true)
    if [ -z "$SUB_BASE_URI$SUB_DOMAIN$_sub_hosts" ]; then return 0; fi
    printf '\n  Clash YAML subscription (unlimited traffic, no expiry):\n'
    if [ -n "$SUB_BASE_URI" ]; then
        printf '    %s%s?format=clash\n' "$SUB_BASE_URI" "$SUB_CLIENT_NAME"
    elif [ -n "$SUB_DOMAIN" ]; then
        _sub_host="$SUB_DOMAIN"
        case "$_sub_host" in \[*\]) ;; *:*) _sub_host="[$_sub_host]" ;; esac
        printf '    %s://%s:%s%s%s?format=clash\n' "$SUB_SCHEME" "$_sub_host" "$SUB_PORT" "$SUB_PATH" "$SUB_CLIENT_NAME"
    else
        while IFS= read -r _sub_host; do
            [ -n "$_sub_host" ] || continue
            printf '    %s://%s:%s%s%s?format=clash\n' "$SUB_SCHEME" "$_sub_host" "$SUB_PORT" "$SUB_PATH" "$SUB_CLIENT_NAME"
        done <<SUB_HOSTS
$_sub_hosts
SUB_HOSTS
    fi
    printf '    Keep this URL private. For NAT, map the subscription port %s/TCP to its public port.\n' "$SUB_PORT"
}

# ── Report ───────────────────────────────────────────────────────────────────
# Printed at the very end so credentials and the node details are the last
# thing on screen rather than scrolled past.
show_summary() {
    _hosts=$(collect_summary_addresses)

    _scheme="http"; $PANEL_TLS && _scheme="https"

    printf "\n"
    printf "${GREEN}=================== Deployment summary ===================${NC}\n"
    printf "\n"
    while IFS= read -r _host; do
        [ -n "$_host" ] || continue
        printf "  Panel:    %s://%s:%s%s\n" "$_scheme" "$_host" "$PANEL_PORT" "$PANEL_PATH"
    done <<ADDRESSES
$_hosts
ADDRESSES
    if $PANEL_TLS; then
        printf "            (self-signed certificate -- the browser will warn)\n"
    fi
    printf "\n"
    if $ADMIN_PASS_SET; then
        printf "  Login:    %s\n" "$ADMIN_USER"
        printf "  Password: %s\n" "$ADMIN_PASS"
        printf "            ${YELLOW}Save this now. It cannot be recovered.${NC}\n"
    else
        printf "  Login:    %s\n" "$ADMIN_USER"
        printf "  Password: ${RED}not set -- run: $INSTALL_DIR/sui admin -reset${NC}\n"
    fi

    print_subscription_urls

    if $HY2_OK; then
        printf "\n"
        printf "  Hysteria2 node: %s\n" "$HY2_TAG"
        printf "    Port: %s/UDP\n" "$HY2_PORT"
        printf "    SNI:  %s\n" "$HY2_SNI"
        printf "    Obfuscation: Salamander (included in panel subscriptions)\n"
        if [ -z "$SUB_CLIENT_NAME" ]; then
            printf "    Add a client in the panel to get a subscription link.\n"
        fi
        if [ -n "$_hosts" ]; then
            printf "    ${YELLOW}Open %s/UDP in your firewall/security group.${NC}\n" "$HY2_PORT"
        fi
    fi
    if $VLESS_OK; then
        printf "\n"
        printf "  VLESS + Reality node: %s\n" "$VLESS_TAG"
        printf "    Port: %s/TCP\n" "$VLESS_PORT"
        printf "    SNI:  %s\n" "$VLESS_SNI"
        printf "    Fingerprint: chrome (uTLS)\n"
        if [ -z "$SUB_CLIENT_NAME" ]; then
            printf "    Add a client in the panel to get a subscription link.\n"
        fi
        if [ -n "$_hosts" ]; then
            printf "    ${YELLOW}Open %s/TCP in your firewall/security group.${NC}\n" "$VLESS_PORT"
        fi
    fi
    printf "\n"
    printf "${GREEN}==========================================================${NC}\n"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Kept here rather than at the top level so --help works for non-root and
    # so SUI_LIB_ONLY can source the helpers in the smoke tests.
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi

    detect_os

    if $UNINSTALL; then
        do_uninstall
    fi

    log_info "=== s-ui Installer ($OS) ==="

    detect_arch
    configure_memory_guard
    choose_download_rate
    check_deps
    get_version
    download_files
    configure_ports || return 1
    install_service
    enable_and_start

    log_info "=== Installation complete ==="

    # ── Optional post-install steps ──────────────────────────────────────────
    read_panel_address
    API_BASE="http://127.0.0.1:$PANEL_PORT${PANEL_PATH}api/"
    # Holds a live panel session cookie, so it must not land on a predictable
    # path in world-writable /tmp. mktemp is in busybox and coreutils; the
    # fallback goes under the install directory, which is root-only.
    COOKIE_JAR=$(mktemp 2>/dev/null || echo "$INSTALL_DIR/.cookie.$$")
    ADMIN_PASS_SET=true
    HY2_OK=false
    VLESS_OK=false
    # Seeds the SNI choice. Guarded like random_port's: a failing od under
    # set -e would abort the install at the last step.
    _RAND=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' ' || true)
    case "$_RAND" in
        ''|*[!0-9]*) _RAND=0 ;;
    esac

    # 1. Replace the default admin/admin credentials. The panel is already
    #    reachable, so leaving the shipped password on it is the first thing to
    #    fix and is not made optional.
    set_admin_password

    # 2. Panel TLS is optional; subscription TLS is cleared on repeat installs too.
    detect_panel_transport || { log_error "Could not reach the panel"; return 1; }
    if ask "Serve the s-ui panel over HTTPS with a self-signed certificate (strongly recommended)?" yes; then
        generate_cert || { log_error "Could not generate the HTTPS certificate"; return 1; }
        panel_login || return 1
        configure_web_transport https || return 1
    else
        panel_login || return 1
        configure_web_transport http || return 1
    fi

    # 3. Offer a Hysteria2 node. The certificate from step 2 is reused when it
    #    exists; otherwise one is generated now, since the protocol requires TLS.
    if ask "Deploy a Hysteria2 node with Salamander obfuscation?" yes; then
        # Hysteria2 requires TLS. Reuse the certificate from step 2, or make
        # one now if that step was declined.
        [ -n "$CERT_CRT" ] || generate_cert || log_warn "Certificate generation failed"

        if [ -z "$CERT_CRT" ]; then
            log_error "No certificate available; skipping Hysteria2"
        elif ensure_session; then
            # The panel restarted when HTTPS was enabled, which drops the
            # session from step 2 -- ensure_session logs in again if needed.
            deploy_hysteria2 || log_warn "Hysteria2 deployment failed"
        else
            log_error "Could not log in to the panel; skipping Hysteria2"
        fi
    else
        log_info "Skipping Hysteria2"
    fi

    # 4. Offer a VLESS + Reality node. No certificate is involved -- reality
    #    borrows the handshake of the site it spoofs, and the keypair comes
    #    from the panel itself. The random seed for the SNI draw is refreshed
    #    here, so the two nodes do not always land on the same decoy hostname.
    printf "\n${RED}\\033[1m"
    printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    printf '%s\n' 'WARNING: sing-box has BUGS in its VLESS implementation,'
    printf '%s\n' 'making it more prone to blocking by the GFW.'
    printf '%s\n' 'If you need VLESS, use Xray-based 3x-ui instead.'
    printf '%s\n' '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    printf "${NC}\n"
    if ask "Deploy a VLESS + Reality node?"; then
        _RAND=$(od -An -N2 -tu2 < /dev/urandom 2>/dev/null | tr -d ' ' || true)
        case "$_RAND" in
            ''|*[!0-9]*) _RAND=0 ;;
        esac
        if ensure_session; then
            deploy_vless_reality || log_warn "VLESS + Reality deployment failed"
        else
            log_error "Could not log in to the panel; skipping VLESS + Reality"
        fi
    else
        log_info "Skipping VLESS + Reality"
    fi

    # 5. The template is panel-wide, so include that effect in the question.
    if ask "Create an unlimited client for ALL current inbounds and apply the bundled Clash template to subscriptions?" yes; then
        create_subscription_client || log_warn "Subscription setup incomplete; review the client and subscription settings in the panel"
    fi

    rm -f "$COOKIE_JAR" 2>/dev/null || true
    show_summary

    log_info "=== Installation complete ==="
    if [ "$OS" = "alpine" ]; then
        log_info "Service: rc-service s-ui {start|stop|restart|status}"
        log_info "Manage:  rc-update {add|del} s-ui default"
    else
        log_info "Service: systemctl {start|stop|restart|status} s-ui"
        log_info "Manage:  systemctl {enable|disable} s-ui"
    fi
    log_info "Logs:    tail -f $LOG_FILE"

}

# SUI_LIB_ONLY lets the smoke tests source this file to exercise the pure
# helpers without running an install. It has no effect on normal usage.
[ "${SUI_LIB_ONLY:-0}" = "1" ] || main
