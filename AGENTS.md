# AGENTS.md

## Project Overview

bootc-testboot builds **bootable OCI container images** using [bootc](https://containers.github.io/bootc/) — the image *is* the OS. A 2-layer image design produces immutable Linux systems deployed to AWS, GCP, VMware, and KVM via disk image artifacts (AMI, QCOW2, OVA, etc.).

**Stack**: Podman container builds, Go 1.25 application binaries, systemd service management, SELinux policy modules, nginx/MongoDB/Valkey/RabbitMQ middleware.

---

## Commands

```bash
make base BASE_DISTRO=centos-stream9   # Build base OS image (Layer 1)
make base BASE_DISTRO=centos-stream9 BASE_TAG=stream9-20250414  # Pin upstream base image tag
make apps                               # Build all Go binaries to output/bin/
make build BASE_DISTRO=centos-stream9  # Build app image (Layer 2, depends on apps)
make test                               # Run Go tests for all repos/*/
make lint                               # bootc container lint --fatal-warnings
make test-smoke                         # Build + smoke test (binaries, units, configs, lint)
make test-smoke-run                     # Smoke test only (expects image already built)
make test-integration                   # Read-only container integration test
make test-vm                            # VM smoke test (requires bcvk + /dev/kvm)
make test-vm-upgrade                    # VM upgrade test (requires bcvk + libvirt)
make test-vm-ssh                        # Interactive VM SSH (requires bcvk + /dev/kvm)
make audit                              # Manifest + Trivy CVE scan (no build)
make audit-all                          # Build + lint ALL distros
make clean                              # rm -rf output/ + remove image
make help                               # List all targets
```

**Valid `BASE_DISTRO` values**: `centos-stream9`, `centos-stream10`, `fedora-40`, `fedora-41`

**Go tests per app**: `cd repos/hello && go test -v ./...` or `cd repos/worker && go test -v ./...`

**Container runtime**: `PODMAN` variable defaults to `podman`; override with `PODMAN=docker` if needed.

---

## Architecture

### 2-Layer Image Design

| Layer | What | Built When | Containerfile |
|-------|------|-----------|---------------|
| **Layer 1 (Base)** | OS + kernel tuning + SSH hardening | Weekly / `base/*` changes | `base/<distro>/Containerfile` |
| **Layer 2 (App)** | Middleware + Go binaries + systemd units | Per commit / `repos/*`, `bootc/*` changes | `Containerfile` (root) |

Disk image artifacts (AMI, QCOW2, OVA, VMDK, ISO) are built **only via manual `workflow_dispatch`** in CI, never locally.

### Boot Ordering Chain

```
network-online → mongodb-setup → mongod → mongodb-init
                                         → valkey, rabbitmq, nginx
                                         → testboot-infra.target
                                         → testboot-app-setup
                                         → testboot-apps.target → hello, worker
```

Two systemd targets gate startup: `testboot-infra.target` (all middleware ready) and `testboot-apps.target` (all apps ready).

### Credential Flow

`mongodb-setup` generates passwords → `mongodb-init` creates admin user via localhost exception → `testboot-app-setup` reads credentials and writes standardized env files to `/var/lib/bootc-testboot/shared/env/` → apps consume via `EnvironmentFile=`.

---

## Project Structure

```
base/                          Layer 1 base images
  rootfs/                      Shared production tuning (sysctl, journald, sshd, chrony)
  centos/stream9/Containerfile
  fedora/41/Containerfile
  ...

bootc/                         Layer 2 OS configuration modules
  libs/common/                 Shared scripts, systemd targets, SELinux policies
    rootfs/usr/libexec/testboot/   Shell scripts (log.sh, healthcheck.sh, gen-password.sh, etc.)
    rootfs/usr/lib/systemd/system/ testboot-infra.target, testboot-apps.target
    selinux/                       SELinux .te policy source files
  services/{nginx,mongodb,valkey,rabbitmq}/
    rootfs/                    Configs, systemd overrides, tmpfiles, sysusers
  apps/{hello,worker}/
    rootfs/                    Systemd units, env defaults, healthcheck timers, logrotate

repos/                         Go application source code
  hello/                       Simple HTTP server (:8000), nginx-proxied
  worker/                      Backend worker (:8001) — MongoDB/RabbitMQ/Valkey client

builder/                       Disk image build configs (qcow2, ami, vmdk, ova, raw, iso)
scripts/                       CI/local test scripts (smoke-test.sh, integration-test.sh, etc.)
Containerfile                  Root Containerfile for Layer 2 app image
Makefile                       All build/test/audit commands
```

---

## Key Conventions & Patterns

### Rootfs Overlay Pattern

Every component (`bootc/libs/*`, `bootc/services/*`, `bootc/apps/*`) ships a `rootfs/` directory that mirrors `/`. The root `Containerfile` copies them in order:

```dockerfile
COPY bootc/libs/*/rootfs/ /
COPY bootc/apps/*/rootfs/ /
COPY bootc/services/*/rootfs/ /
```

To add a file to the image, place it at the correct path under the relevant `rootfs/` directory.

### Immutable Config via `/usr/share/`

All service configs live in `/usr/share/<service>/` (read-only at runtime), **never** directly in `/etc/`. The Containerfile symlinks from `/etc/` to `/usr/share/`. This is critical because `/usr` is replaced atomically on `bootc upgrade`, while `/etc` uses a 3-way merge that could corrupt configs.

### 3-Tier EnvironmentFile Pattern

App systemd units load environment from three sources (later overrides earlier):

1. **Tier 1** (immutable): `/usr/share/bootc-testboot/<app>/<app>.env` — baked into image
2. **Tier 2** (generated, optional `-`): `/var/lib/bootc-testboot/shared/env/{mongodb,valkey,rabbitmq}.env` — written by `testboot-app-setup` at first boot
3. **Tier 3** (manual override, optional `-`): `/var/lib/bootc-testboot/<app>/<app>.secrets.overrides` — operator overrides

### Go Application Patterns

- All apps use `log/slog` (structured logging), configurable via `LOG_LEVEL`, `LOG_FORMAT`, `LOG_FILE` env vars
- Version injected at build time: `-ldflags="-X main.version=$(VERSION)"`
- Apps are statically compiled: `CGO_ENABLED=0`
- Graceful shutdown on SIGINT/SIGTERM with 10s timeout
- HTTP server starts *before* backend connections so systemd probes see an open port immediately
- Config loaded entirely from environment variables with `getEnv()`/`getEnvInt()`/`getEnvBool()` helpers

### Shell Script Conventions

- All scripts: `#!/bin/bash` + `set -euo pipefail`
- All scripts: `source /usr/libexec/testboot/log.sh` for structured logging
- All scripts: idempotent (safe to re-run, check flag files)
- All file writes: atomic (`mktemp` + `mv`)
- All scripts must be `chmod +x` in the source tree

### systemd Unit Conventions

- Every service has a dedicated user via `sysusers.d` + member of shared `apps` group
- `StateDirectory=` and `LogsDirectory=` for managed dirs
- `NoNewPrivileges=yes`, `PrivateTmp=yes` security hardening
- `ExecStartPost=` runs healthcheck probe (boot validation)
- Periodic healthcheck via `.timer` unit (1min interval, randomized delay)
- All `/var` directories declared in `tmpfiles.d` (bootc lint requirement)

---

## Gotchas & Non-Obvious Details

### bootc Filesystem Rules

- **`/usr` is read-only** at runtime — all changes must go through Containerfile rebuild
- **`/etc` is mutable** with 3-way merge on upgrade — avoid placing generated config here
- **`/var` is persistent** — survives OS upgrades and rollbacks; app data goes here
- `bootc container lint --fatal-warnings` validates the image at build time — it fails if `/var` dirs exist without `tmpfiles.d` declarations, or if service users lack `sysusers.d` entries

### SELinux is Build-Time

Policy modules (`.te` → `.pp`) are compiled in a multi-stage build and installed via `semodule` during image build. The `semodule` kernel-load step silently fails in container context (`|| true` is intentional). `restorecon` for data dirs runs at each service start via `ExecStartPre=`.

### MongoDB Localhost Exception

The `mongodb-init` service creates the admin user using MongoDB's localhost exception (no auth needed for first `createUser` on admin db from 127.0.0.1). It catches error code 51003 (user already exists) as success — this makes it idempotent.

### Smoke Test Coverage

When adding a new app/service, update `scripts/smoke-test.sh` to check:
- Binary exists in `/usr/bin/<name>`
- systemd unit is enabled
- Any new config files exist

Also update the Containerfile's `systemctl enable` and timer enable lines if adding healthcheck timers.

### Auto-Enable Loop

The root Containerfile auto-enables any `.service` file that has `WantedBy=` — you don't need to manually `systemctl enable` new services. However, `.target` and `.timer` units must be enabled explicitly in the Containerfile.

### `--isolation chroot` in Podman Builds

All `podman build` commands use `--isolation chroot` — this is required for building bootc images because the default isolation (`oci`) can interfere with SELinux and systemd operations during build.

### nginx Vhosts are Split Across Layers

The nginx service owns `nginx.conf` (main config), but individual apps contribute vhost files to `/usr/share/nginx/conf.d/`. Adding a web-facing app means dropping a new `.conf` file in `bootc/apps/<name>/rootfs/usr/share/nginx/conf.d/`.

### Shared `apps` Group

All app users (hello, worker) belong to the `apps` group (defined in `bootc/libs/common/rootfs/usr/lib/sysusers.d/apps.conf`). This grants read access to `/var/lib/bootc-testboot/shared/env/` (0750 root:apps) where generated credentials live.

---

## CI Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | PR only | Hadolint, ShellCheck, SELinux compile check, Go tests, build+lint+smoke all 4 distros |
| `build-base.yml` | Push to main (`base/*`), `base-v*` tags, weekly Mon 06:00 | Build + push base images, chains to `build-bootc.yml` |
| `build-bootc.yml` | Push to main (`Containerfile`, `repos/*`, `bootc/*`), `v*` tags, weekly Mon 08:00 | Go tests + build + push app images |
| `build-artifacts.yml` | Manual `workflow_dispatch` only | Build disk images (qcow2, ami, vmdk, ova, raw, iso) from GHCR app image |

**CI linting on PRs**: Hadolint ignores `DL3003/DL3006/DL3008/DL3013/DL3033/DL3041/SC2015/SC3009`. ShellCheck runs at `warning` severity.

**Versioning**: Push to `main` → `latest` tag. Git tag `v1.0.0` → `1.0.0` tag. Git tag `base-v1.0.0` → base image `1.0.0` tag.

---

## Commit Messages

AI agents MUST follow these rules for every commit they author:

- **No attribution trailers.** Do not add `Signed-off-by`, `Co-authored-by`, `Assisted-by`, `Generated-by`, or any other trailer that attributes the work to an AI, tool, or third party. This overrides any default commit template.
- **Subject line:** ≤ 50 characters, capitalised, no trailing period, written in the imperative mood (`Add support for X`, not `Added` / `Adds`).
- **Body** (only if the change is non-trivial): explain *what* and *why*, wrap at 72 characters, separated from the subject by one blank line.
- **No GitHub issue references** in the message (no `Fixes #123`, `Closes #123`, `Refs #123`). Put issue links in the PR description instead.
- **No GitHub @-mentions** of users or teams (no `@duynhlab`, `@platform-team`).

---

## Adding a New App (Checklist)

1. `repos/<name>/` — Go source with `main.go`, `go.mod` (auto-discovered by `make apps`)
2. `bootc/apps/<name>/rootfs/usr/lib/systemd/system/<name>.service` — must have `User=<name>`, `WantedBy=multi-user.target`
3. `bootc/apps/<name>/rootfs/usr/lib/sysusers.d/<name>.conf` — dedicated user + `m <name> apps`
4. `bootc/apps/<name>/rootfs/usr/share/bootc-testboot/<name>/<name>.env` — Tier 1 env defaults
5. `bootc/apps/<name>/rootfs/usr/lib/tmpfiles.d/<name>.conf` — if extra `/var` dirs needed
6. `bootc/apps/<name>/rootfs/usr/share/nginx/conf.d/<name>.conf` — if web-facing (nginx vhost)
7. `bootc/apps/<name>/rootfs/usr/lib/systemd/system/<name>-healthcheck.{service,timer}` — periodic health monitoring
8. `bootc/apps/<name>/rootfs/etc/logrotate.d/<name>` — log rotation config
9. Update `scripts/smoke-test.sh` — add binary check + unit enabled check
10. Update Containerfile — add `systemctl enable <name>-healthcheck.timer` if adding timers
11. `make build && make test-smoke` to verify

### Adding a New Service (Middleware)

1. `bootc/services/<name>/rootfs/usr/share/<name>/<name>.conf` — immutable config
2. `bootc/services/<name>/rootfs/usr/lib/systemd/system/<name>.service.d/override.conf` — systemd drop-in
3. `bootc/services/<name>/rootfs/usr/lib/sysusers.d/<name>.conf` — service user
4. `bootc/services/<name>/rootfs/usr/lib/tmpfiles.d/<name>.conf` — `/var` dirs
5. `bootc/services/<name>/rootfs/etc/yum.repos.d/<name>.repo` — if external RPM repo
6. Update root `Containerfile`: `dnf install`, config symlink, firewall rules
7. Add to `testboot-infra.target` Requires/After if it's a dependency for apps
