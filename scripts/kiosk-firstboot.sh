#!/usr/bin/env bash
#
# kiosk-firstboot.sh — run this on a freshly installed Ubuntu 22.04 kiosk,
# directly from the data pendrive.
#
# It installs the offline .deb bundle (no internet needed), enables SSH, and
# verifies everything the Ansible deployment assumes. It does not modify the
# repository or run any playbook.
#
# Usage:
#   bash /media/$USER/DEBS/kiosk-firstboot.sh
#   bash ./kiosk-firstboot.sh --bundle ./offline-packages-delta
#   bash ./kiosk-firstboot.sh --check          # checks only, install nothing
#
# Exit status: 0 when every check passes, 1 otherwise.

set -uo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BUNDLE=""
CHECK_ONLY=0

usage() {
    cat <<'EOF'
Usage: kiosk-firstboot.sh [options]

Options:
  --bundle DIR   bundle directory (default: offline-packages-delta next to this script)
  --check        run the checks only; do not install anything
  -h, --help     show this help
EOF
}

die() { echo "error: $*" >&2; exit 1; }

while (($# > 0)); do
    case "$1" in
        --bundle)  BUNDLE=${2:?--bundle needs a directory}; shift 2 ;;
        --check)   CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         die "unknown option: $1 (try --help)" ;;
    esac
done

if [[ -z $BUNDLE ]]; then
    # The builder copies this script into the bundle, but it also works when
    # placed beside an offline-packages* folder on the stick.
    if compgen -G "$SELF_DIR/*.deb" >/dev/null; then
        BUNDLE=$SELF_DIR
    else
        for candidate in \
            "$SELF_DIR/offline-packages-delta" \
            "$SELF_DIR/offline-packages" \
            "$SELF_DIR"/offline-packages-*; do
            if [[ -d $candidate ]]; then
                BUNDLE=$candidate
                break
            fi
        done
    fi
fi

[[ -z $BUNDLE && $CHECK_ONLY -eq 0 ]] && die "no bundle found next to this script; pass --bundle DIR"
[[ -n $BUNDLE && ! -d $BUNDLE ]] && die "bundle directory not found: $BUNDLE"

ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; CHECKS_OK=$((CHECKS_OK + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; CHECKS_FAIL=$((CHECKS_FAIL + 1)); }
CHECKS_OK=0
CHECKS_FAIL=0

check_pkg() {
    if dpkg -s "$1" >/dev/null 2>&1; then ok "package $1"; else bad "package $1 (missing)"; fi
}
check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then ok "$1"; else bad "$1 (missing)"; fi
}

# ---------------------------------------------------------------- preflight
echo "== Host =="
OS_VER=$(lsb_release -rs 2>/dev/null || echo unknown)
ARCH=$(dpkg --print-architecture 2>/dev/null || echo unknown)
KERNEL=$(uname -r)
CURRENT_USER=$(id -un)
CURRENT_UID=$(id -u)

if [[ $OS_VER == 22.04 ]]; then ok "Ubuntu $OS_VER"; else bad "Ubuntu $OS_VER (expected 22.04)"; fi
if [[ $ARCH == amd64 ]]; then ok "architecture $ARCH"; else bad "architecture $ARCH (expected amd64)"; fi
if [[ $CURRENT_UID == 1000 ]]; then ok "user $CURRENT_USER (uid 1000)"; else bad "user $CURRENT_USER (uid $CURRENT_UID, playbooks expect 1000)"; fi
if [[ $CURRENT_USER == cezen ]]; then
    ok "username cezen (matches playbook defaults)"
else
    printf '  \033[33m!\033[0m username %s is not cezen; deploy_script/application_script hardcode cezen\n' "$CURRENT_USER"
fi

# ---------------------------------------------------------------- install
if ((CHECK_ONLY == 0)); then
    command -v sudo >/dev/null 2>&1 || die "sudo not available"

    DEB_COUNT=$(find "$BUNDLE" -maxdepth 1 -name '*.deb' | wc -l)
    ((DEB_COUNT > 0)) || die "no .deb files in $BUNDLE"

    echo
    echo "== Installing $DEB_COUNT packages from $BUNDLE =="
    # --no-download keeps apt from waiting on an unreachable mirror; anything it
    # cannot satisfy locally is handled by the dpkg fallback below.
    if ! sudo apt-get install -y --no-download "$BUNDLE"/*.deb; then
        echo "apt could not resolve the set locally; falling back to dpkg ..." >&2
        sudo dpkg -i "$BUNDLE"/*.deb || true
        sudo dpkg -i "$BUNDLE"/*.deb || die "dpkg install failed"
        sudo dpkg --configure -a || die "dpkg --configure -a failed"
    fi

    echo
    echo "== Enabling SSH =="
    sudo systemctl enable --now ssh 2>/dev/null \
        || sudo systemctl enable --now ssh.socket 2>/dev/null \
        || echo "warning: could not enable ssh; check 'systemctl status ssh'" >&2
fi

# ---------------------------------------------------------------- checks
echo
echo "== Required packages =="
check_pkg openssh-server
check_pkg libfuse2
check_pkg i2c-tools
check_pkg gettext
check_pkg unzip
check_pkg python3-apt
check_pkg dconf-cli
check_pkg dkms
check_pkg "linux-headers-$KERNEL"
check_pkg gcc-12

echo
echo "== Required commands =="
check_cmd dkms
check_cmd gcc-12
check_cmd msgfmt
check_cmd i2cdetect
check_cmd dconf

echo
echo "== Services =="
if systemctl is-active --quiet ssh; then
    ok "ssh is active"
else
    bad "ssh is not active (sudo systemctl enable --now ssh)"
fi
if systemctl is-active --quiet gdm3; then
    ok "gdm3 is active"
else
    bad "gdm3 is not active; the playbooks need a GNOME session"
fi

echo
echo "== Network =="
ip -4 -o addr show scope global 2>/dev/null | awk '{print "  " $2 ": " $4}'

echo
if ((CHECKS_FAIL == 0)); then
    printf '\033[32mAll %d checks passed.\033[0m\n' "$CHECKS_OK"
    cat <<EOF

Next steps:
  1. On the kiosk: log in to the GNOME desktop once and leave the session running.
  2. On the laptop, add this address to hosts.ini:
       <ip> ansible_user=$CURRENT_USER ansible_ssh_pass=<password> ansible_become_pass=<password>
  3. On the laptop:
       ./scripts/deploy.sh --host <ip>
EOF
    exit 0
fi

printf '\033[31m%d check(s) failed.\033[0m Fix them before running the deployment.\n' "$CHECKS_FAIL"
exit 1
