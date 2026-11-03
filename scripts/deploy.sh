#!/usr/bin/env bash
#
# deploy.sh — one-command deployment from the laptop.
#
# Reads hosts.ini, ensures passwordless SSH works for every target (using
# ssh-copy-id with the inventory password, only when key auth is not already
# working), then runs the playbooks in the documented order.
#
# Usage:
#   ./scripts/deploy.sh                     # every host in hosts.ini
#   ./scripts/deploy.sh --host 10.0.0.5     # one target
#   ./scripts/deploy.sh --key-only          # set up SSH keys and stop
#   ./scripts/deploy.sh --skip-touch        # skip the DWAV driver
#   ./scripts/deploy.sh --systemd           # AppImage as a systemd --user service
#   ./scripts/deploy.sh --list              # show targets parsed from hosts.ini
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)

INVENTORY="$REPO_DIR/hosts.ini"
HOST_FILTER=""
KEY_ONLY=0
NO_KEY_SETUP=0
SKIP_TOUCH=0
USE_SYSTEMD=0
LIST_ONLY=0
VERBOSITY=()

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: deploy.sh [options]

Options:
  -i, --inventory FILE   inventory file (default: hosts.ini next to scripts/)
      --host IP          only deploy to this target (must exist in the inventory)
      --key-only         set up SSH key auth and exit
      --no-key-setup     do not run ssh-copy-id; fail if key auth is missing
      --skip-touch       skip touch_driver.yml
      --systemd          use application_script_systemd.yml instead of the
                         XDG autostart variant
      --list             print parsed targets and exit
  -v|-vv|-vvv            pass verbosity to ansible-playbook
  -h, --help             show this help

Playbook order:
  i2c_setup.yml
  lite_deploy_script.yml
  application_script.yml      (or application_script_systemd.yml with --systemd)
  fetch_uuid.yml
  boot_image.yml
  touch_driver.yml            (unless --skip-touch)
EOF
}

while (($# > 0)); do
    case "$1" in
        -i|--inventory)  INVENTORY=${2:?--inventory needs a path}; shift 2 ;;
        --host)          HOST_FILTER=${2:?--host needs an address}; shift 2 ;;
        --key-only)      KEY_ONLY=1; shift ;;
        --no-key-setup)  NO_KEY_SETUP=1; shift ;;
        --skip-touch)    SKIP_TOUCH=1; shift ;;
        --systemd)       USE_SYSTEMD=1; shift ;;
        --list)          LIST_ONLY=1; shift ;;
        -v|-vv|-vvv)     VERBOSITY+=("$1"); shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "unknown option: $1 (try --help)" ;;
    esac
done

command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not installed"
[[ -f $INVENTORY ]] || die "inventory not found: $INVENTORY"

# ---------------------------------------------------------------- inventory
# Emits one "ip user password" line per host in [install_targets] / [all].
# Supports inline vars, [install_targets:vars] and [all:vars]; ignores ; and #
# comments and strips CRLF.
parse_inventory() {
    awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN { sec = ""; nh = 0 }
    {
        line = $0
        sub(/\r$/, "", line)
        sub(/^[ \t]+/, "", line)
        if (line == "" || line ~ /^[#;]/) next
        if (line ~ /^\[/) {
            sec = line
            sub(/^\[/, "", sec)
            sub(/\][ \t]*$/, "", sec)
            next
        }
        if (sec ~ /:vars$/) {
            pos = index(line, "=")
            if (pos > 0) {
                k = trim(substr(line, 1, pos - 1))
                v = trim(substr(line, pos + 1))
                if (k == "ansible_user") v_user = v
                else if (k == "ansible_ssh_pass") v_pass = v
            }
            next
        }
        if (sec != "install_targets" && sec != "all") next
        n = split(line, parts, /[ \t]+/)
        ip = parts[1]; u = ""; p = ""
        for (i = 2; i <= n; i++) {
            pos = index(parts[i], "=")
            if (pos == 0) continue
            k = substr(parts[i], 1, pos - 1)
            v = substr(parts[i], pos + 1)
            if (k == "ansible_user") u = v
            else if (k == "ansible_ssh_pass") p = v
        }
        nh++
        hips[nh] = ip; husers[nh] = u; hpasses[nh] = p
    }
    END {
        for (i = 1; i <= nh; i++) {
            u = (husers[i] != "" ? husers[i] : v_user)
            p = (hpasses[i] != "" ? hpasses[i] : v_pass)
            print hips[i], u, p
        }
    }' "$1"
}

mapfile -t ENTRIES < <(parse_inventory "$INVENTORY")
((${#ENTRIES[@]} > 0)) || die "no active hosts found in $INVENTORY"

if [[ -n $HOST_FILTER ]]; then
    filtered=()
    for entry in "${ENTRIES[@]}"; do
        read -r ip _ <<<"$entry"
        [[ $ip == "$HOST_FILTER" ]] && filtered+=("$entry")
    done
    ((${#filtered[@]} > 0)) || die "host $HOST_FILTER is not an active entry in $INVENTORY"
    ENTRIES=("${filtered[@]}")
fi

printf 'Targets from %s:\n' "$INVENTORY"
for entry in "${ENTRIES[@]}"; do
    read -r ip user pass <<<"$entry"
    printf '  %-16s user=%-8s password=%s\n' \
        "$ip" "${user:-(unset)}" "$([[ -n $pass ]] && echo set || echo MISSING)"
done

((LIST_ONLY == 0)) || exit 0

# ---------------------------------------------------------------- SSH keys
setup_key() {
    local ip=$1 user=$2 pass=$3

    [[ -n $user ]] || { echo "  $ip: ansible_user missing in inventory" >&2; return 1; }

    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
           "$user@$ip" true 2>/dev/null; then
        echo "  $ip: key auth OK"
        return 0
    fi

    if ((NO_KEY_SETUP)); then
        echo "  $ip: key auth unavailable and --no-key-setup was given" >&2
        return 1
    fi
    [[ -n $pass ]] || { echo "  $ip: no ansible_ssh_pass in inventory; run ssh-copy-id manually" >&2; return 1; }
    command -v sshpass >/dev/null 2>&1 || { echo "  $ip: sshpass not installed" >&2; return 1; }

    # A reinstalled target has a new host key; drop the stale one.
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$ip" >/dev/null 2>&1 || true

    echo "  $ip: copying SSH key (first connection)..."
    if ! SSHPASS=$pass sshpass -e ssh-copy-id \
            -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
            "$user@$ip" >/dev/null 2>&1; then
        echo "  $ip: ssh-copy-id failed (wrong user/password?)" >&2
        return 1
    fi

    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$user@$ip" true 2>/dev/null; then
        echo "  $ip: key auth OK"
    else
        echo "  $ip: key auth still failing after ssh-copy-id" >&2
        return 1
    fi
}

echo
echo "== SSH access =="
key_fail=0
for entry in "${ENTRIES[@]}"; do
    read -r ip user pass <<<"$entry"
    setup_key "$ip" "$user" "$pass" || key_fail=1
done
((key_fail == 0)) || die "SSH key setup failed for at least one target"

((KEY_ONLY == 0)) || exit 0

# ---------------------------------------------------------------- playbooks
playbooks=(i2c_setup.yml lite_deploy_script.yml)
if ((USE_SYSTEMD)); then
    playbooks+=(application_script_systemd.yml)
else
    playbooks+=(application_script_systemd.yml)
fi
playbooks+=(fetch_uuid.yml boot_image.yml)
((SKIP_TOUCH)) || playbooks+=(touch_driver.yml)

args=(-i "$INVENTORY")
[[ -n $HOST_FILTER ]] && args+=(--limit "$HOST_FILTER")
((${#VERBOSITY[@]} > 0)) && args+=("${VERBOSITY[@]}")

export LC_ALL=C.UTF-8 LANG=C.UTF-8 ANSIBLE_HOST_KEY_CHECKING=False

cd "$REPO_DIR"
echo
echo "== Playbooks: ${playbooks[*]} =="
ansible-playbook "${args[@]}" "${playbooks[@]}"
