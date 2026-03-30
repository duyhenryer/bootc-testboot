# GHCR audit — registry & artifact verification

After CI publishes images to GitHub Container Registry (GHCR), verify manifests and (optionally) pull images to confirm disk artifacts contain the expected paths.

## Table of Contents

- [Public images (default)](#public-images-default)
- [Private packages (optional note)](#private-packages-optional-note)
- [Tools](#tools)
- [Prerequisites](#prerequisites)
- [What the script checks](#what-the-script-checks)
- [Environment variables](#environment-variables)
- [Commands](#commands)
- [Exit code and report](#exit-code-and-report)
- [Example output (abbreviated)](#example-output-abbreviated)
- [Related documentation](#related-documentation)

## Public images (default)

This project’s images are **public**. You do **not** need `podman login` or a token — `skopeo` and `podman pull` work anonymously.

**CI:** images and disk artifacts are **linux/amd64** only. Tags are **path-style** (no `-arch` suffix), e.g. `…/bootc-testboot/centos-stream9:latest`, `…/bootc-testboot/centos-stream9/qcow2:latest`. Use `podman pull --platform linux/amd64` when needed. Optional aarch64: see `.github/workflows/build-*.yml` comments.

## Private packages (optional note)

If a package is **private**, use `podman login ghcr.io` with a PAT before `podman pull`. Do not commit or share tokens.

## Tools

| Tool | Role |
|------|------|
| [scripts/verify-ghcr-packages.sh](../../scripts/verify-ghcr-packages.sh) | `skopeo inspect`, then `podman pull` + path checks |
| `skopeo` | Remote metadata (digest, arch) without full layer download |
| `podman` | Pull and export scratch layers as tar for path checks |
| `jq` | Parse `skopeo` JSON |

**Makefile:** `make verify-ghcr`

## Prerequisites

- `skopeo`, `podman`, `jq` installed.
- **Disk space:** full run downloads large layers (VMDK/OVA/ISO). Use `VERIFY_SKIP_PULL=1` for metadata-only.

## What the script checks

1. **`skopeo inspect`** — Each artifact path (`ami`, `qcow2`, `raw`, `vmdk`, `ova`, `anaconda-iso` under `…/bootc-testboot/<distro>/`) plus base (`…/base/<distro>`) and app (`…/<distro>`): manifest readable, digest, `architecture`, `os`, `created`.

2. **`podman pull` + deep checks** (unless `VERIFY_SKIP_PULL=1`):  
   - Scratch artifacts: `podman create` + `podman export \| tar -tf` — paths match [003-deploying-and-upgrading.md — Artifact path reference](003-deploying-and-upgrading.md).  
   - Base/app: label `containers.bootc=1` and `/etc/os-release` readable.

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `REGISTRY_PREFIX` | `ghcr.io/duyhenryer` | Registry / owner prefix |
| `DISTRO` | `centos-stream9` | Distro segment in image path |
| `IMAGE_TAG` | `latest` | Tag (e.g. `latest` or semver; no `-arch` in tag name) |
| `VERIFY_SKIP_SKOPEO` | unset | Set `1` to skip skopeo |
| `VERIFY_SKIP_PULL` | unset | Set `1` to skip pulls and tarball checks |

## Commands

```bash
# Full check (public — no login)
./scripts/verify-ghcr-packages.sh
# or
make verify-ghcr

# Fast: skopeo only (no large downloads)
VERIFY_SKIP_PULL=1 ./scripts/verify-ghcr-packages.sh

# Skopeo off, only podman (unusual)
VERIFY_SKIP_SKOPEO=1 ./scripts/verify-ghcr-packages.sh
```

## Exit code and report

```text
=== 3. Report ===
Checks marked [OK]: N
Checks marked [FAIL]: M
Overall: PASSED | FAILED
```

Exit code `0` only if `M == 0`.

## Example output (abbreviated)

### Section 1 — skopeo

```text
=== 1. skopeo inspect (remote metadata, no layer download) ===
  digest: sha256:...
  arch: amd64 os: linux
  [OK] skopeo inspect artifact-ova
  ...
  [OK] skopeo inspect app
```

### Section 2 — podman

```text
=== 2. podman pull + verify (needs free disk — large layers) ===
>>> QCOW2 artifact
  [OK] found path matching: (^|\./)qcow2/disk\.qcow2$
```

### Report

```text
=== 3. Report ===
Checks marked [OK]: 18
Checks marked [FAIL]: 0
Overall: PASSED
```

## Post-deploy VM audit checklist

After deploying a disk image (QCOW2, OVA, AMI) to a VM, SSH in and run this checklist to verify
the system is healthy. Copy-paste the block below as a single `sudo bash -c '...'` command.

### Quick one-liner

> **Note:** Credential files (`.admin-pw`, `.keyFile`) are owned by `mongod:mongod` with
> restricted permissions. All commands below use `sudo` — this is the correct security posture,
> not a bug. Do not weaken file permissions to avoid `sudo`.

```bash
sudo bash -c '
echo "=== Failed units ===" && systemctl --failed
echo "=== SELinux ===" && getenforce && semodule -l | grep -E "mongodb|bootc"
echo "=== MongoDB setup log ===" && journalctl -u mongodb-setup --no-pager -q
echo "=== MongoDB init log ===" && journalctl -u mongodb-init --no-pager -q
echo "=== Mongod status ===" && systemctl is-active mongod
echo "=== Credentials ===" && ls -la /var/lib/mongodb/.admin-pw /var/lib/mongodb/.keyFile /var/lib/mongodb/.rs-initialized /var/lib/mongodb/tls/ 2>&1
echo "=== Connectivity ===" && mongosh --quiet "mongodb://admin:$(cat /var/lib/mongodb/.admin-pw)@127.0.0.1:27017/admin?authSource=admin" --eval "print(JSON.stringify({rs: rs.status().ok, members: rs.status().members.length}))" 2>&1
echo "=== AVC denials ===" && ausearch -m AVC --start today 2>/dev/null | head -5 || echo "none"
echo "=== Services ===" && systemctl is-active nginx valkey rabbitmq-server hello 2>&1
echo "=== Symlinks ===" && readlink /etc/mongod.conf /etc/nginx/nginx.conf /etc/valkey/valkey.conf /etc/rabbitmq/rabbitmq.conf
'
```

### What each check verifies

| # | Check | Healthy | Problem |
|---|-------|---------|---------|
| 1 | `systemctl --failed` | No failed units | Any unit listed |
| 2 | `getenforce` | `Enforcing` | `Permissive` or `Disabled` |
| 3 | `semodule -l \| grep mongodb` | `mongodb`, `mongodb_ftdc_local`, `bootc_testboot_local` | Missing module = build-time `semodule` failed |
| 4 | `journalctl -u mongodb-setup` | Shows gen-password, gen-tls-cert, gen-keyFile, "setup complete" | Missing steps or errors |
| 5 | `journalctl -u mongodb-init` | Shows Step 1/2 (rs0), Step 2/2 (admin user), "complete" | "not authorized" or timeout |
| 6 | `systemctl is-active mongod` | `active` | `failed` — check `journalctl -u mongod` |
| 7 | Credential files exist | `.admin-pw`, `.keyFile`, `.rs-initialized`, `tls/` all present | Missing file = setup or init failed partway |
| 8 | `mongosh` connectivity | `{"rs":1,"members":1}` | Auth error = wrong password; connection refused = mongod down |
| 9 | `ausearch -m AVC` | Empty or `none` | `mongod_t` / `systemd_tmpfile_t` denials = SELinux module gap |
| 10 | Other services active | `nginx`, `valkey`, `rabbitmq-server`, `hello` all `active` | Check `journalctl -u <service>` for the failing one |
| 11 | Symlinks intact | All point to `/usr/share/<service>/` | Broken symlink = rootfs overlay or Containerfile issue |

### Individual deep-dive commands

```bash
# Full MongoDB setup journal (credentials + TLS generation)
sudo journalctl -u mongodb-setup --no-pager

# Full MongoDB init journal (rs0 + admin user creation)
sudo journalctl -u mongodb-init --no-pager

# Mongod runtime log (persistent across reboots)
sudo tail -30 /var/log/mongodb/mongod.log

# SELinux context on MongoDB data directory
ls -laZ /var/lib/mongodb/

# Read the admin password (requires sudo — file is owned by mongod:mongod)
sudo cat /var/lib/mongodb/.admin-pw

# FTDC is collecting (proves no SELinux denials blocking proc reads)
sudo mongosh --quiet "mongodb://admin:$(sudo cat /var/lib/mongodb/.admin-pw)@127.0.0.1:27017/admin?authSource=admin" \
  --eval 'print("FTDC total: " + db.serverStatus().metrics.commands.serverStatus.total)'

# All AVC denials from today
sudo ausearch -m AVC --start today 2>/dev/null

# bootc image version and labels
rpm-ostree status
bootc status
```

---

## Related documentation

- [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) — Artifact path reference  
- [README.md](../../README.md) — Auditing scratch artifact images
