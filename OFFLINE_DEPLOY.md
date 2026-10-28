# Offline Kiosk Deployment — USB Runbook

This guide covers the full path for a machine with **no internet access**:

1. Prepare the Ubuntu installer pendrive on the internet-connected laptop.
2. Build a `.deb` bundle on the laptop.
3. Install Ubuntu 22.04.5 on the kiosk from the pendrive.
4. Install the bundle and make the kiosk reachable over SSH.
5. Patch the playbooks so they never call `apt update`.
6. Run the Ansible deployment from the laptop.

Placeholders used below:

| Placeholder | Meaning |
|---|---|
| `<USB_ISO>` | pendrive used for the Ubuntu ISO, e.g. `/dev/sdb` (**whole disk**, no number) |
| `<USB_DEBS>` | second pendrive for the `.deb` bundle, e.g. `/dev/sdc` |
| `<ISO>` | path to `ubuntu-22.04.5-desktop-amd64.iso` |
| `<TARGET_IP>` | LAN address of the kiosk, e.g. `192.168.1.11` |
| `<USER>` | kiosk user, use **`cezen`** to match the playbooks |

> Replace every angle-bracket placeholder (for example `<USB_ISO>`) with the real value **before** running a command — the `<` and `>` are not shell syntax.

> **Two USB sticks are strongly recommended**: one bootable installer, one data stick.
> Writing the ISO with `dd` destroys the whole stick, so you cannot simply copy files onto it afterwards.

---

## Quick path (streamlined)

Once the laptop is prepared (§0), the whole flow is three commands. Steps 1 and 2 run **once per
ISO/installer-option combination**, not once per device; step 3 runs per device.

```bash
# 1. ONE TIME on the laptop: build the delta bundle and put it on the data stick.
#    The builder also copies kiosk-firstboot.sh inside the bundle.
./scripts/build_offline_bundle.py --baseline ~/baseline.txt --output ~/offline-packages-delta
cp -a ~/offline-packages-delta /media/$USER/DEBS/

# 2. kiosk, after the fresh install and first desktop login: install + verify
#    (run this on every kiosk; it is idempotent)
bash /media/$USER/DEBS/offline-packages-delta/kiosk-firstboot.sh

# 3. laptop: SSH key setup + all playbooks, in order
./scripts/deploy.sh --host <TARGET_IP> -vv
```

`baseline.txt` is the package list of a *fresh* install. Every kiosk installed from the same ISO
with the same installer options has the same baseline, so capture it once (from the first kiosk
before installing anything, or from a throwaway VM), keep it next to the repo, and rebuild only
when the ISO, installer options or package set change. `kiosk-firstboot.sh --check` on each new
kiosk catches a device that drifted from that baseline.

Each bundle directory records what it contains:

- `packages.txt` — every `.deb` file name.
- `manifest.txt` — exact `package=version` pins.

`manifest.txt` is enough to rebuild the same bundle later without a fresh baseline (for example
after deleting the folder, or on a different laptop):

```bash
./scripts/build_offline_bundle.py \
    --manifest ~/offline-packages-delta/manifest.txt \
    --output ~/offline-packages-delta
```

Commit `manifest.txt` if you want the exact package set in version control.

- `kiosk-firstboot.sh` installs the bundle, enables SSH, and verifies the assumptions the
  playbooks make (Ubuntu 22.04, uid 1000, kernel headers, `gcc-12`, `libfuse2`, `dkms`, GNOME
  session). It exits non-zero if anything is missing.
- `deploy.sh` parses `hosts.ini` (inline vars or `[install_targets:vars]`), runs `ssh-copy-id`
  only when key auth is missing, then runs `i2c_setup.yml`, `lite_deploy_script.yml`,
  `application_script.yml`, `fetch_uuid.yml`, `boot_image.yml` and `touch_driver.yml` in order.
  Useful flags: `--list`, `--key-only`, `--skip-touch`, `--systemd`, `--no-key-setup`, `-v`.

The rest of this document is the manual path; it stays valid for troubleshooting and for the
legacy full-closure bundle.

---

## 0. Assumptions and one-time checks

Laptop (internet side):

- Ubuntu 22.04, `amd64` — confirmed on `denny-Precision-3591`.
- `ansible`, `sshpass`, `apt-rdepends` installed.
- `LC_ALL=C.UTF-8 LANG=C.UTF-8` needed when running Ansible on this shell (see §9).

```bash
ansible --version
command -v sshpass
command -v apt-rdepends
```

If `ansible --version` prints

```
ERROR: Ansible requires the locale encoding to be UTF-8; Detected ISO8859-1.
```

the shell is running under a non-UTF-8 locale. Confirm with:

```bash
locale
```

Immediate workaround for one command:

```bash
LC_ALL=C.UTF-8 LANG=C.UTF-8 ansible --version
```

Permanent fix for the current user:

```bash
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8

# apply to the current terminal without logging out
export LANG=en_US.UTF-8
unset LC_ALL LC_CTYPE
ansible --version
```

If a stale `LC_ALL`/`LC_CTYPE` is set somewhere and overrides it, find it:

```bash
grep -nE 'LANG|LC_' ~/.bashrc ~/.profile ~/.bash_profile /etc/default/locale 2>/dev/null
```

`C.UTF-8` also works and needs no locale generation, but `en_US.UTF-8` is the better desktop default.

If a tool is missing, the laptop is online:

```bash
sudo apt install -y ansible sshpass apt-rdepends
```

Kiosk (offline side):

- `amd64` hardware, blank disk, at least ~40 GB.
- Needs to reach the laptop over LAN (same switch/router, or a direct Ethernet cable with manual IPs) for the Ansible run. "Offline" means **no internet**, not "no network".

---

## 1. Plug the pendrive into the laptop and write the Ubuntu ISO

Download the ISO on the laptop if you do not have it, then verify it against the checksum published at `https://releases.ubuntu.com/22.04/`:

```bash
cd ~/Downloads
sha256sum ubuntu-22.04.5-desktop-amd64.iso
```

Plug in `<USB_ISO>` and identify it. **Do not guess the device name.**

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
```

Look for the removable device matching the stick's size and model. Then unmount anything auto-mounted:

```bash
sudo umount <USB_ISO>?* 2>/dev/null || true
```

Write the image (replace `<USB_ISO>` with the whole disk, e.g. `/dev/sdb`, **not** `/dev/sdb1`):

```bash
sudo dd if=~/Downloads/ubuntu-22.04.5-desktop-amd64.iso of=<USB_ISO> bs=4M status=progress oflag=sync
sync
```

Alternative GUI: *Startup Disk Creator* (`usb-creator-gtk`).

Safety: `dd` with the wrong target irreversibly overwrites that disk. Confirm the device in `lsblk` twice.

---

## 2. Build the offline `.deb` bundle on the laptop

> **Use the delta method for a fresh 22.04.5 install.** The original full-closure bundle upgrades
> base-system libraries without their matching daemons and can break polkit, accounts-daemon,
> NetworkManager and GDM (observed 2026-10-29: no GUI, eject/reboot denied). The delta bundle only
> adds packages missing from a fresh install and does not touch the base OS unless a version
> constraint forces it.

### Recommended: baseline-delta bundle

On the freshly installed target, **before installing anything**, save its package baseline:

```bash
uname -r
dpkg -l "linux-headers-$(uname -r)" | grep '^ii'      # expected ii on a desktop install
dpkg-query -W -f='${Package}\t${Version}\n' | sort > ~/baseline.txt
```

Copy `baseline.txt` to the laptop (Ventoy or scp), then build the delta:

```bash
cd /home/denny/Office/ansible-playbook-kiosk-gnome
./scripts/build_offline_bundle.py --baseline /path/to/baseline.txt \
    --output ~/offline-packages-delta
```

The script:

- starts from `libfuse2 openssh-server gettext i2c-tools build-essential gcc-12 dkms zip unzip
  python3-apt dconf-cli`
  (`gnome-shell-extension-manager`, `libglib2.0-dev-bin` and `dconf-editor` were removed from the
  playbooks — they are not used, and `gnome-shell-extension-manager` pulled the whole GNOME upgrade
  chain; `zip`/`unzip` are needed by `gnome-extensions pack` and Ansible's `unarchive`, and the
  delta filter drops them if the baseline already has them);
- drops every package already present in the baseline;
- if a downloaded package requires a newer version of a baseline package, adds that upgrade **and
  every baseline package that pins the old version with an exact `(= version)` dependency**
  (polkitd, accountsservice, gdm3, network-manager, …);
- writes `packages.txt` and prints the list of baseline upgrades for review.

A fresh 22.04.5 desktop already has `linux-headers-6.8.0-40-generic`, so no kernel debs are needed.
If the baseline check shows no headers, add `linux-headers-$(uname -r)` to `--pkgs`.

Install on the target — small bundle, GUI stays untouched:

```bash
sudo apt install -y ~/offline-packages-delta/*.deb
```

### Legacy: full-closure bundle (not recommended for fresh installs)

The remainder of this section documents the original self-contained bundle. It upgrades libraries
such as libpolkit, libaccountsservice0 and libnm0 and therefore must also ship the matching daemons.
Prefer the delta method above.

```bash
rm -rf ~/offline-packages
mkdir -p ~/offline-packages
cd ~/offline-packages

PKGS="libfuse2 openssh-server \
      gettext gnome-shell-extension-manager libglib2.0-dev-bin dconf-editor \
      i2c-tools build-essential dkms \
      unzip python3-apt dconf-cli \
      linux-generic-hwe-22.04"

apt-rdepends $PKGS 2>/dev/null \
  | awk '/^[^ ]/ && $0 !~ /^(PreDepends|Depends|Recommends|Suggests|Conflicts|Replaces|Provides|Breaks|Enhances|Obsoletes):$/ {print $1}' \
  | sed 's/:any$//' \
  | grep -v ':i386$' \
  | grep -vE '^(libsystemd0|libudev1|udev|systemd|systemd-[a-z0-9-]+|libpam-systemd|libnss-systemd)$' \
  | sort -u > package-list.txt

while read -r pkg; do
    apt download "$pkg" >/dev/null 2>&1 || echo "skip: $pkg"
done < package-list.txt

ls *.deb | wc -l
du -sh .
rm -f *_i386.deb
for p in $PKGS; do ls -1 ${p}_*.deb >/dev/null 2>&1 || echo "MISSING: $p"; done
```

Notes:

- The `skip:` lines are **virtual packages** and expected. The reference run produced 15:
  `aspell-dictionary`, `dbus-session-bus`, `debconf-2.0`, `default-dbus-session-bus`,
  `default-logind`, `gsettings-backend`, `hunspell-dictionary`, `ispell-dictionary`,
  `libc-dev`, `libgirepository-1.0-1-with-libffi8`, `libjack-0.125`, `libsoup3.0-0`,
  `logind`, `myspell-dictionary`, `perlapi-5.34.0`.
  Their real providers are in the bundle (e.g. `libsoup3.0-0` → `libsoup-3.0-0`).
- Reference result (2026-10-28): **562 debs, 755 MB**; 577 list entries = 562 debs + 15 virtual skips.
- The `MISSING:` loop must print nothing.
- **The systemd/udev stack is deliberately excluded.** A fresh Ubuntu already has it, and bundling
  an upgraded `libsystemd0`/`libudev1`/`udev` without the matching `systemd`, `libpam-systemd`,
  `systemd-sysv`, … triggers exact-version dependency failures offline:
  `libpam-systemd : Depends: systemd (= ...) but it is not installable`.
  Leaving the target's own stack untouched avoids that entirely. If you build a bundle without the
  new filter, delete `libsystemd0_*.deb`, `libudev1_*.deb` and `udev_*.deb` before installing.
- `linux-generic-hwe-22.04` pulls the 6.8.0-138 image, modules, modules-extra and headers, plus
  `linux-firmware` (302 MB), `intel-microcode` and `amd64-microcode` — those three are hard
  dependencies of the image meta, which is why the bundle is ~750 MB.
- The `sed`/`grep` filters drop `:any` and i386-qualified names. The laptop has the i386 foreign
  architecture enabled; those debs would be rejected by the kiosk.

Stronger completeness check (catches failed *dependencies*, not just the top-level packages):

```bash
while read -r pkg; do
    compgen -G "${pkg}_*.deb" >/dev/null && continue
    apt-cache policy "$pkg" | grep -q 'Candidate: [^(]' && echo "REAL MISSING: $pkg"
done < package-list.txt
```

No `REAL MISSING:` lines means every installable dependency is present. Also verify the archives:

```bash
for f in *.deb; do dpkg-deb --info "$f" >/dev/null 2>&1 || echo "BAD: $f"; done
```

### If the sequential download is too slow

`apt download` is single-threaded. Interrupt the `while read` loop (already-downloaded files are
kept) and finish the remainder in parallel:

```bash
cd ~/offline-packages

while read -r pkg; do
    compgen -G "${pkg}_*.deb" >/dev/null || echo "$pkg"
done < package-list.txt > remaining.txt
wc -l remaining.txt

xargs -P 4 -n 1 sh -c \
  'apt -o Acquire::ForceIPv4=true download "$0" >/dev/null 2>&1 || echo "skip: $0"' \
  < remaining.txt
```

`ForceIPv4=true` helps when the IPv6 mirror route is slow. Virtual packages will print `skip:` again.

Create a manifest and the archive:

```bash
ls *.deb | sort > packages.txt
cd ~
tar cf voip-offline-debs.tar offline-packages   # debs are already compressed; cf is faster than czf
du -h voip-offline-debs.tar
```

### Kernel-pinned variant (stay on 6.8.0-40)

> Not needed with the delta method: a fresh 22.04.5 desktop already has
> `linux-headers-6.8.0-40-generic` in its baseline. This section applies to the legacy full bundle
> only.

A fresh 22.04.5 install runs `6.8.0-40-generic`. The bundle above upgrades it to 6.8.0-138.
If you want to keep the ISO kernel instead, build a second folder by copying the main bundle and
swapping only the kernel pieces:

```bash
rm -rf ~/offline-packages-6.8.0-40
mkdir -p ~/offline-packages-6.8.0-40
cp -a ~/offline-packages/*.deb ~/offline-packages-6.8.0-40/
cd ~/offline-packages-6.8.0-40

# drop the 6.8.0-138 chain and the firmware only it needs
rm -f linux-generic-hwe-22.04_* \
      linux-image-generic-hwe-22.04_* \
      linux-headers-generic-hwe-22.04_* \
      linux-image-6.8.0-138-generic_* \
      linux-modules-6.8.0-138-generic_* \
      linux-modules-extra-6.8.0-138-generic_* \
      linux-headers-6.8.0-138-generic_* \
      linux-hwe-6.8-headers-6.8.0-138_* \
      linux-firmware_* intel-microcode_* amd64-microcode_*

# add the pinned kernel set
apt download linux-headers-6.8.0-40-generic linux-hwe-6.8-headers-6.8.0-40 \
             linux-image-6.8.0-40-generic linux-modules-6.8.0-40-generic \
             linux-modules-extra-6.8.0-40-generic
```

Reference result: **556 debs, 440 MB**. Only the headers are required for DKMS; the image and
modules are already installed by the ISO and are included for completeness. The copied base set
already excludes the systemd/udev stack (see the note in §2).

On the target:

```bash
sudo apt install -y ~/offline-packages-6.8.0-40/*.deb   # no reboot needed
uname -r                                              # stays 6.8.0-40-generic
dpkg -l linux-headers-6.8.0-40-generic | grep '^ii'
```

Do **not** install the 6.8.0-138 bundle on a machine you want to keep on 40. This kernel is still
offered by `jammy-updates` / `jammy-security` as of 2026-10-28; if it disappears later, the .debs
remain in the archive pool.

### Put the new AppImage in `assets/`

The Ansible playbook copies the client from `assets/`. If you rebuilt it:

```bash
cd /home/denny/Office/ansible-playbook-kiosk-gnome
install -m755 /home/denny/Office/cvoip_desktop_stable_deploy/voip-x86_64.AppImage \
  assets/voip-x86_64.AppImage
```

Point the playbooks at that filename (`application_script.yml`, `application_script_patch.yml` and `application_script_systemd.yml` if used):

```bash
sed -i 's/^\( *appimage_name:\).*/\1 voip-x86_64.AppImage/' \
  application_script.yml application_script_patch.yml application_script_systemd.yml
grep -n appimage_name application_script*.yml
```

If you use a versioned name (`voip-x86_64_v1.6.8.AppImage`), copy it under that name and set the variable accordingly.

---

## 3. Copy the bundle to the data pendrive

Plug in `<USB_DEBS>`. If it is not formatted yet, create a partition with GNOME Disks, or from the shell. `mkfs.exfat` is not installed on this laptop by default (it needs `sudo apt install exfatprogs`), whereas **ext4 works out of the box and is natively supported by the Ubuntu kiosk**:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
sudo parted <USB_DEBS> --script mklabel gpt
sudo parted <USB_DEBS> --script mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L DEBS <USB_DEBS>1
```

Use exFAT or FAT32 only if the stick must also be readable on Windows; both files here are far below the FAT32 4 GB limit.

Formatting destroys the stick's contents — re-check the device name first.

Then copy the archive:

```bash
mkdir -p /media/$USER/DEBS        # or mount however your desktop does
cp ~/voip-offline-debs.tar.gz /media/$USER/DEBS/
sync
```

A second partition on the installer stick also works (create it in the free space after the ISO with GParted), but a separate stick is less error-prone.

---

## 4. Install Ubuntu 22.04.5 on the kiosk

1. Insert `<USB_ISO>`, power on, open the firmware boot menu (F12/F11/Esc depending on vendor) and boot the stick.
2. Choose **Install Ubuntu**.
3. Installer options:
   - **Normal installation** (do *not* choose Minimal — the playbooks expect the normal GNOME desktop seed).
   - **Uncheck** "Download updates while installing Ubuntu" (there is no internet).
   - Do not enable third-party drivers.
4. Disk: erase disk and install (single-OS kiosk).
5. User: create **`cezen`** as the first user so it gets UID 1000. Several playbook tasks hardcode `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`; a different UID breaks the GNOME/gsettings/extension tasks.
   Set the password to match `hosts.ini` (`1234`) or edit `hosts.ini` afterwards.
6. Finish, remove the stick, reboot.

After first boot, log in to the GNOME desktop once (keep the session running). The Ansible tasks that call `gnome-extensions`, `gsettings` and `dconf` need an active graphical session; they target `DISPLAY=:0` and `/run/user/1000/bus`.

Optional console checks:

```bash
uname -r
dpkg --print-architecture
lsb_release -ds
```

The kernel here will be the ISO's 6.8.0-4x — that is fine, the bundle installs a newer one.

---

## 5. Install the offline debs on the kiosk

### Delta bundle (recommended)

Plug `<USB_DEBS>`, copy the folder off it and install:

```bash
cp -a /media/$USER/DEBS/offline-packages-delta ~/
cd ~/offline-packages-delta
sudo apt install -y ./*.deb
```

No reboot is needed: the delta does not change the kernel or the desktop stack.

```bash
uname -r                                              # 6.8.0-40-generic (unchanged)
dpkg -l "linux-headers-$(uname -r)" | grep '^ii'      # ii
systemctl status gdm3 --no-pager | head -5            # GUI untouched, active
systemctl status ssh --no-pager | head -5             # active
```

If SSH is not running: `sudo systemctl enable --now ssh`.

Use `apt install ./*.deb`, not `dpkg -i` — apt resolves the ordering among the local files. If it
still reports dependency problems:

```bash
sudo dpkg -i ./*.deb
sudo dpkg -i ./*.deb
sudo dpkg --configure -a
```

### Legacy full-closure bundle

Copy the archive off the stick, install, then reboot into the bundled kernel:

```bash
mkdir -p ~/offline && cp /media/$USER/DEBS/voip-offline-debs.tar.gz ~/offline/
cd ~/offline && tar xzf voip-offline-debs.tar.gz
cd offline-packages

sudo apt install -y ./*.deb
sudo reboot
```

After reboot:

```bash
uname -r                                              # 6.8.0-138-generic
dpkg -l "linux-headers-$(uname -r)" | grep '^ii'
systemctl status ssh --no-pager | head -5
```

Do not run the touch-driver playbook before the headers check passes.

---

## 6. Get the kiosk onto the LAN and reachable by SSH

Ansible cannot work over a memory stick: the laptop must reach the kiosk over the network.

- Connect both machines to the same switch/router (internet on the router is not required), or connect them with a direct Ethernet cable and configure static addresses on the same subnet.
- On the kiosk, find the address:

```bash
ip -4 addr show scope global
```

- Set it in `hosts.ini`. The active entry is currently:

```ini
192.168.1.11 ansible_user=voip ansible_ssh_pass=1234 ansible_become_pass=1234
```

If you created `cezen` (recommended), change `ansible_user` to `cezen`, and make sure the password matches what you set in the installer:

```ini
192.168.1.11 ansible_user=cezen ansible_ssh_pass=1234 ansible_become_pass=1234
```

- Remove any stale host key from earlier deployments, then test:

```bash
ssh-keygen -R <TARGET_IP>
sshpass -p 1234 ssh -o StrictHostKeyChecking=no cezen@<TARGET_IP> 'uname -r'
```

---

## 7. Patch the playbooks for offline operation

The playbooks call `apt update` in two places. Offline those calls fail and abort the run even though every package is already installed.

### 7.1 `update_cache: yes` → `no`

Files and lines affected: `deploy_script.yml:45`, `lite_deploy_script.yml:45`, `part_desktop_script.yml:45`, `i2c_setup.yml:13`, `dwav_driver_install.yml:21`.

```bash
cd /home/denny/Office/ansible-playbook-kiosk-gnome
sed -i 's/update_cache: yes/update_cache: no/' \
  deploy_script.yml lite_deploy_script.yml part_desktop_script.yml \
  i2c_setup.yml dwav_driver_install.yml

grep -rn 'update_cache' *.yml
```

With `update_cache: no` and the packages already installed, `apt: state=present` performs a local dpkg check and never touches the network.

### 7.2 Touch-driver script

`assets/touch-driver/install-touch-driver.sh` runs `apt-get update` and `apt-get install` at lines 11–12 under `set -euo pipefail`, so it aborts offline before DKMS runs.

```bash
sed -n '9,13p' assets/touch-driver/install-touch-driver.sh
sed -i '11,12s/^/# /' assets/touch-driver/install-touch-driver.sh
sed -n '9,13p' assets/touch-driver/install-touch-driver.sh
```

Both patched lines must now start with `# `.

A safer alternative that works online and offline:

```bash
if ! dpkg -s build-essential dkms "linux-headers-$(uname -r)" >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y build-essential dkms "linux-headers-$(uname -r)"
fi
```

### 7.3 Revert later

All affected files are tracked by git:

```bash
git checkout -- deploy_script.yml lite_deploy_script.yml part_desktop_script.yml \
                i2c_setup.yml dwav_driver_install.yml \
                assets/touch-driver/install-touch-driver.sh
```

---

## 8. What the playbooks do

| Playbook | Purpose |
|---|---|
| `i2c_setup.yml` | installs `i2c-tools`, checks `/dev/i2c-*` permissions |
| `deploy_script.yml` | main kiosk setup: package installs, GNOME settings, extensions, autologin, dconf locks |
| `lite_deploy_script.yml` | same as `deploy_script.yml`, plus disabling APT periodic updates (the variant used in `steps.txt`) |
| `part_desktop_script.yml` | desktop/panel customisation only |
| `application_script.yml` | copies the AppImage + `voip.ini`, creates XDG autostart entry |
| `application_script_patch.yml` | byte-identical copy of `application_script.yml` |
| `application_script_systemd.yml` | AppImage as a `systemd --user` service with `Restart=always`; removes the autostart entry |
| `boot_image.yml` | Plymouth boot splash |
| `fetch_uuid.yml` | appends the machine's DMI product UUID to `product_uuids.txt` on the laptop |
| `touch_driver.yml` / `dwav_driver_install.yml` | DWAV touch driver via DKMS |
| `firefox.yml` | reinstalls Firefox from the Snap Store — **cannot run offline**, skip it |

`deploy_script.yml` / `lite_deploy_script.yml`, the `application_script*.yml` variants, `boot_image.yml` and the touch-driver playbooks reboot the machine at the end; SSH drops and Ansible reconnects after the reboot timeout. `fetch_uuid.yml` does not reboot.

---

## 9. Run the deployment

From the laptop, in the repo directory:

```bash
cd /home/denny/Office/ansible-playbook-kiosk-gnome
export LC_ALL=C.UTF-8 LANG=C.UTF-8 ANSIBLE_HOST_KEY_CHECKING=False

ansible-playbook -i hosts.ini \
  i2c_setup.yml \
  lite_deploy_script.yml \
  application_script.yml \
  fetch_uuid.yml \
  boot_image.yml -vv
```

Notes:

- `LC_ALL=C.UTF-8` is required on this shell; otherwise Ansible aborts with `Ansible requires the locale encoding to be UTF-8; Detected ISO8859-1`.
- Use `application_script_systemd.yml` **instead of** `application_script.yml` if you want the app restarted after a crash or exit.
- Never include `firefox.yml` offline.
- Run the touch-driver playbook only after the kernel/header check in §5:

```bash
ansible-playbook -i hosts.ini touch_driver.yml -vv
# or
ansible-playbook -i hosts.ini dwav_driver_install.yml -vv
```

---

## 10. Verify the kiosk

On the kiosk (log in as `cezen`):

```bash
# App present and executable
ls -l ~/Applications/

# autostart variant
cat ~/.config/autostart/voip.desktop

# systemd variant
systemctl --user status voip.service
systemctl --user is-enabled voip.service

# config
cat ~/.config/voip/voip.ini

# the file is a valid AppImage
file ~/Applications/<appimage_name>
```

Then reboot and confirm the app starts on login.

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Failed to update apt cache` during a playbook | §7.1 not applied, or the kiosk is trying to reach the internet |
| touch playbook fails at `apt-get update` | §7.2 not applied to the script that `touch_driver.yml` runs |
| `dpkg: dependency problems prevent configuration` | run `sudo dpkg -i ./*.deb` again, then `sudo dpkg --configure -a` |
| `Error! Your kernel headers for kernel ... cannot be found` | the machine booted an older kernel — reboot into 6.8.0-138 and run `dpkg -l "linux-headers-$(uname -r)"` |
| `gnome-extensions` / `gsettings` fails with "Cannot autolaunch D-Bus" | no GNOME session for UID 1000; log in on the console as `cezen` before running |
| `Ansible requires the locale encoding to be UTF-8` | prefix commands with `LC_ALL=C.UTF-8 LANG=C.UTF-8` |
| SSH permission denied | `hosts.ini` password/user does not match the user created in the installer |
| `AppImage: error while loading shared libraries: libfuse.so.2` | `libfuse2` did not install; `dpkg -l libfuse2` |
| AppImage will not start but FUSE is missing | `APPIMAGE_EXTRACT_AND_RUN=1 ~/Applications/<appimage_name>` |
| `application_script.yml` cannot find the asset | `appimage_name` does not match the file in `assets/` |
| `snap install firefox` fails | expected offline — do not run `firefox.yml` |
| No GUI after reboot, tty only; `polkit authority not available`; eject/reboot denied | full-closure bundle upgraded libpolkit/libaccountsservice0/libnm0 without polkitd/accountsservice/network-manager/GDM. Use the delta bundle (§2); if already broken, add those daemons at matching versions and reboot |

---

## 12. Bundle contents reference

| Package | Needed by |
|---|---|
| `openssh-server` (+ sftp-server, `ssh-import-id`) | Ansible connectivity |
| `libfuse2` | running the AppImage on 22.04 |
| `gettext` (`msgfmt`) | packing the just-perfection extension |
| `i2c-tools` | `i2c_setup.yml` |
| `build-essential`, `dkms`, `linux-headers-*` | DWAV touch driver (`linux-headers` already in a desktop baseline) |
| `unzip`, `python3-apt`, `dconf-cli` | Ansible modules / `dconf update` / `dconf reset` — already in a desktop baseline |
| `glib-compile-schemas` | provided by baseline `libglib2.0-bin` (no `libglib2.0-dev-bin` needed) |
| `linux-generic-hwe-22.04` | **legacy bundle only**; not needed for a fresh install |

`gnome-shell-extension-manager` and `dconf-editor` were removed from the playbooks: they are GUI-only,
not used by any task, and `gnome-shell-extension-manager` dragged in the whole GNOME upgrade chain.

Everything else the deployment uses — AppImage, `voip.ini`, GNOME extension zips, touch-driver sources, Plymouth background — is already inside the repository's `assets/` directory and is copied over by Ansible; it is not fetched from the internet.
