# GHCR audit — registry & artifact verification

After CI publishes images to GitHub Container Registry (GHCR), verify manifests and (optionally) pull images to confirm disk artifacts contain the expected paths.

## Public images (default)

This project’s images are **public**. You do **not** need `podman login` or a token — `skopeo` and `podman pull` work anonymously.

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

1. **`skopeo inspect`** — Each artifact (`-ami`, `-qcow2`, `-raw`, `-vmdk`, `-ova`, `-anaconda-iso`) plus base and app images: manifest readable, digest, `architecture`, `os`, `created`.

2. **`podman pull` + deep checks** (unless `VERIFY_SKIP_PULL=1`):  
   - Scratch artifacts: `podman create` + `podman export \| tar -tf` — paths match [005-manual-deployments.md — Artifact path reference](005-manual-deployments.md).  
   - Base/app: label `containers.bootc=1` and `/etc/os-release` readable.

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `REGISTRY_PREFIX` | `ghcr.io/duyhenryer` | Registry / namespace |
| `DISTRO` | `centos-stream9` | Image name segment |
| `ARCH_SUFFIX` | `latest-amd64` | Tag (e.g. `latest-arm64`) |
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

## Related documentation

- [005-manual-deployments.md](005-manual-deployments.md) — Artifact path reference  
- [README.md](../../README.md) — Auditing scratch artifact images
