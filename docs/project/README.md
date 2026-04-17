# Project documentation index

Use this map to pick the right doc and avoid duplicating content across files. **Canonical home** for each topic is listed — other docs should link here instead of copying long sections.

## By role

| I want to... | Read |
|------------|------|
| Understand the stack and build pipeline (two layers: base + app image) | [001-architecture-overview.md](001-architecture-overview.md) |
| Build images, rootfs overlay convention, immutable config strategy | [002-building-images.md](002-building-images.md) |
| Deploy to AWS / GCE / VMware / Xen / bare metal, upgrade, rollback, ops runbook | [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) |
| Local testing, test case registry (TC-xx), QEMU, bcvk VM testing, troubleshooting | [004-testing-guide.md](004-testing-guide.md) |
| Verify GHCR after CI, post-deploy VM audit checklist | [005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md) |
| SELinux: MongoDB FTDC denials, build-time policy, case studies | [006-selinux-reference.md](006-selinux-reference.md) |
| SELinux: MongoDB-specific policy notes (redirects to 006) | [007-selinux-mongodb.md](007-selinux-mongodb.md) |
| Hello/Worker `ExecStartPost` healthcheck, logs, `systemd.timer` options | [008-healthcheck.md](008-healthcheck.md) |
| systemd targets (`testboot-infra` / `testboot-apps`), log paths, logrotate | [009-observability-logs.md](009-observability-logs.md) |
| Worker app: data seeding, infrastructure health checks, MongoDB/RabbitMQ/Valkey status | [010-worker-app.md](010-worker-app.md) |

## Canonical topic -> doc

| Topic | Canonical doc | Notes |
|-------|---------------|-------|
| **Build:** `make base`, `make build`, two-layer pipeline | [001](001-architecture-overview.md) + [002](002-building-images.md) | 003 Part A only summarizes; link here. |
| **Rootfs overlay, file mapping, immutable config** | [002-building-images.md](002-building-images.md) | Single source for rootfs convention, mapping tables, config strategy. |
| **Deploy:** disk images, AWS, GCE, VMware, bare metal | [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) Part B + C | All deployment targets in one doc. |
| **`bootc upgrade` / rollback commands** | [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) Part D | Operator commands, phased upgrade, per-platform notes. |
| **Release scenarios** (add app, remove app, config change) | [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) Part E | What changes on disk during each release type. |
| **Ops runbook** (debug, /opt, gotchas, emergency) | [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) Part F | Day-2 operations on immutable OS. |
| **Filesystem theory** (OSTree, `/usr` ro) | [docs/bootc/003-filesystem-layout.md](../bootc/003-filesystem-layout.md) | Project-specific paths in [002](002-building-images.md). |
| **GHCR paths, `verify-ghcr`** | [005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md) | 003 keeps the artifact path table for deployers. |
| **Post-deploy checks / troubleshooting** | [005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md) + [004-testing-guide.md](004-testing-guide.md) | 005 has the VM checklist; 004 has test-level troubleshooting. |
| **SELinux policy** | [006-selinux-reference.md](006-selinux-reference.md) | Problem history, methods, case studies, AVC reading guide. |
| **SELinux / MongoDB** (image-specific) | [007-selinux-mongodb.md](007-selinux-mongodb.md) | Redirects to 006 (consolidated). |
| **Hello/Worker healthcheck** (`ExecStartPost`, periodic options) | [008-healthcheck.md](008-healthcheck.md) | Smoke vs timer; empty logs after rotate; matrix; identity. |
| **Targets, log contract, logrotate** | [009-observability-logs.md](009-observability-logs.md) | Infra/apps ordering; `/var/log/bootc-testboot/`; not metrics. |
| **Worker app** (data seeding, health checks) | [010-worker-app.md](010-worker-app.md) | Infrastructure verification, MongoDB/RabbitMQ/Valkey status endpoints. |

## Numbering

Files use `00N-` prefixes for sort order (this folder includes **[001](001-architecture-overview.md)** through **[010](010-worker-app.md)**). There is no required reading sequence; [001](001-architecture-overview.md) is the usual starting point.

## bootc Learning Docs

The `docs/bootc/` directory contains reference material about bootc itself (not project-specific):

| Doc | Topic |
|-----|-------|
| [001-what-is-bootc.md](../bootc/001-what-is-bootc.md) | What is bootc and why image-based Linux |
| [002-architecture-and-ostree.md](../bootc/002-architecture-and-ostree.md) | OSTree internals, A/B deployments |
| [003-filesystem-layout.md](../bootc/003-filesystem-layout.md) | `/usr`, `/etc`, `/var` lifecycle |
| [003.1-bootc-storage-backends.md](../bootc/003.1-bootc-storage-backends.md) | Storage backend comparison |
| [004-users-groups-ssh.md](../bootc/004-users-groups-ssh.md) | User management on immutable OS |
| [005-secrets-management.md](../bootc/005-secrets-management.md) | Secrets handling patterns |
| [006-upgrade-and-rollback.md](../bootc/006-upgrade-and-rollback.md) | Upgrade/rollback commands and lifecycle |
| [007-registries-and-offline.md](../bootc/007-registries-and-offline.md) | Registry configuration, offline use |
| [008-relationships.md](../bootc/008-relationships.md) | bootc vs Flatcar vs CoreOS vs others |
| [009-base-distro-comparison.md](../bootc/009-base-distro-comparison.md) | CentOS vs Fedora comparison |
| [010-ubuntu-bootc-status.md](../bootc/010-ubuntu-bootc-status.md) | Ubuntu bootc readiness |
| [011-bootc-vision.md](../bootc/011-bootc-vision.md) | Long-term vision for bootc |
| [012-bootc-limitations.md](../bootc/012-bootc-limitations.md) | Known limitations |
| [013-bootc-image-builder-guide.md](../bootc/013-bootc-image-builder-guide.md) | bootc-image-builder usage guide |
| [014-production-tuning-guide.md](../bootc/014-production-tuning-guide.md) | Production hardening reference |
| [015-bcvk-virtualization-kit.md](../bootc/015-bcvk-virtualization-kit.md) | bcvk VM testing tool (ephemeral + libvirt modes) |
