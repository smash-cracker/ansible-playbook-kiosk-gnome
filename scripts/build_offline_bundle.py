#!/usr/bin/env python3
#
# Copyright 2026 The Mumble Developers. All rights reserved.
# Use of this source code is governed by a BSD-style license
# that can be found in the LICENSE file at the root of the
# Mumble source tree or at <https://www.mumble.info/LICENSE>.
"""Build an offline .deb bundle as a delta against a fresh Ubuntu 22.04 install.

The baseline is the package list of the freshly installed target *before* any
changes are made:

    dpkg-query -W -f='${Package}\\t${Version}\\n' | sort > ~/baseline.txt

Only packages missing from that baseline are downloaded. If a downloaded
package requires a newer version of a baseline package, that upgrade is added
together with every baseline package that pins the old library with an exact
`(= version)` dependency (for example polkitd, accountsservice, gdm3,
network-manager). That is what prevents the offline install from half-upgrading
the base system.

Usage:
    scripts/build_offline_bundle.py --baseline baseline.txt --output ~/offline-delta
"""

import argparse
import os
import re
import subprocess
import sys

DEFAULT_PKGS = [
    "libfuse2",
    "openssh-server",
    "gettext",
    "i2c-tools",
    "build-essential",
    # The 6.8 HWE kernel headers pin CC=gcc-12, so the DKMS touch driver build fails
    # without it even though build-essential pulls gcc-11 on 22.04.
    "gcc-12",
    "dkms",
    "zip",
    "unzip",
    "python3-apt",
    "dconf-cli",
]

# apt-rdepends emits these; they are virtual and cannot be downloaded.
VIRTUAL_HINTS = {"debconf-2.0", "libc-dev", "default-logind", "logind",
                 "dbus-session-bus", "default-dbus-session-bus",
                 "gsettings-backend", "perlapi-5.34.0", "myspell-dictionary"}


def run(cmd, check=False):
    return subprocess.run(cmd, text=True, capture_output=True, check=check)


def apt_rdepends(pkgs):
    res = run(["apt-rdepends", *pkgs])
    names = set(pkgs)
    for line in res.stdout.splitlines():
        if not line or line[0].isspace() or line.startswith("<"):
            continue
        line = line.rstrip()
        if line.endswith(":"):
            continue
        names.add(line)
    return {n for n in names if not n.endswith(":i386") and not n.endswith(":any")}


def deb_fields(path):
    res = run(["dpkg-deb", "-f", path, "Package", "Version", "Source", "Depends", "PreDepends"])
    fields = {}
    key = None
    for line in res.stdout.splitlines():
        if line[:1].isspace() and key:
            fields[key] += " " + line.strip()
        elif ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    return fields


def version_ok(have, op, want):
    return run(["dpkg", "--compare-versions", have, op, want]).returncode == 0


def download(outdir, pkg, skipped):
    res = run(["apt", "download", pkg])
    if res.returncode != 0:
        skipped.add(pkg)
        return False
    return True


def debs(outdir):
    return sorted(f for f in os.listdir(outdir) if f.endswith(".deb"))


def new_version(outdir, pkg):
    for f in debs(outdir):
        fields = deb_fields(os.path.join(outdir, f))
        if fields.get("Package") == pkg:
            return fields.get("Version")
    return None


_installed_deps = None


def installed_deps():
    """Depends of every installed package on this laptop (cached).

    The laptop is fully updated, so these are the same package versions as the
    new debs and therefore show the exact-version pairings we must preserve.
    """
    global _installed_deps
    if _installed_deps is None:
        _installed_deps = {}
        out = run(["dpkg-query", "-W",
                   "-f=${Package}\t${Depends}\t${PreDepends}\n"]).stdout
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:
                _installed_deps[parts[0]] = parts[1] + "," + parts[2]
    return _installed_deps


def exact_dependents(pkg, version, baseline):
    """Installed baseline packages that pin `pkg (= version)`."""
    deps_map = installed_deps()
    pattern = re.compile(re.escape(pkg) + r"\s*\(=\s*" + re.escape(version) + r"\s*\)")
    return {q for q in baseline
            if q != pkg and pattern.search(deps_map.get(q, ""))}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", required=True,
                    help="output of dpkg-query -W from the fresh target")
    ap.add_argument("--output", required=True, help="folder to download into")
    ap.add_argument("--pkgs", default=" ".join(DEFAULT_PKGS),
                    help="space separated packages to install on the target")
    args = ap.parse_args()

    baseline = {}
    with open(args.baseline) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if not parts or not parts[0].strip():
                continue
            name = parts[0].strip()
            baseline[name] = parts[1].strip() if len(parts) > 1 else None

    pkgs = args.pkgs.split()
    os.makedirs(args.output, exist_ok=True)
    os.chdir(args.output)

    for f in debs("."):
        os.unlink(f)  # rebuild from scratch

    candidates = apt_rdepends(pkgs)
    needed = {p for p in candidates if p not in baseline}
    print(f"candidates: {len(candidates)}  missing from baseline: {len(needed)}")

    skipped = set()
    for pkg in sorted(needed):
        download(".", pkg, skipped)

    upgraded = set()
    missing = set()
    while True:
        changed = False

        # 1. Version constraints of downloaded debs against the baseline.
        for f in debs("."):
            fields = deb_fields(os.path.join(".", f))
            deps = fields.get("Depends", "") + "," + fields.get("PreDepends", "")
            for clause in re.split(r",", deps):
                m = re.search(r"([A-Za-z0-9+.-]+)\s*\(\s*(>=|<=|=|>>|<<)\s*([^)]+)\)", clause)
                if not m:
                    continue
                dep, op, ver = m.groups()
                if dep in needed or dep in upgraded or dep in skipped:
                    continue
                if dep in baseline:
                    have = baseline[dep]
                    if not have:
                        continue  # baseline without version: assume ok
                    if not version_ok(have, op, ver):
                        print(f"  upgrade needed: {dep} {have} -> {op} {ver}")
                        upgraded.add(dep)
                        download(".", dep, skipped)
                        changed = True
                else:
                    # Dependency neither installed nor already queued: try to
                    # fetch it (it may be a missing package of the bundle).
                    if dep not in needed and dep not in upgraded:
                        if download(".", dep, skipped):
                            needed.add(dep)
                            changed = True
                        else:
                            missing.add(dep)

        # 2. Exact-version daemons of every upgraded package.
        for pkg in list(upgraded):
            ver = new_version(".", pkg)
            if not ver:
                continue
            for dep in exact_dependents(pkg, ver, baseline):
                if dep in upgraded or dep in needed:
                    continue
                print(f"  exact-version dependent: {dep} (needs {pkg} (= {ver}))")
                upgraded.add(dep)
                download(".", dep, skipped)
                changed = True

        if not changed:
            break

    # Sanity: every package we intended to fetch is present.
    have = {deb_fields(os.path.join(".", f)).get("Package") for f in debs(".")}
    wanted = (needed | upgraded) - skipped
    absent = sorted(wanted - have)
    if absent:
        print("ERROR: no .deb for:", " ".join(absent))
        return 1
    if missing:
        print("WARNING: dependencies not in baseline and not downloaded:",
              " ".join(sorted(missing)))

    with open("packages.txt", "w") as fh:
        for f in debs("."):
            fh.write(f + "\n")

    print()
    print(f"debs in bundle : {len(debs('.'))}")
    print(f"skipped        : {' '.join(sorted(skipped)) or '(none)'}")
    print(f"baseline upgrades: {' '.join(sorted(upgraded)) or '(none)'}")
    print(f"output         : {os.path.abspath('.')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
