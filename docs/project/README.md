# Project documentation index

Use this map to pick the right doc and avoid duplicating content across files. **Canonical home** for each topic is listed—other docs should link here instead of copying long sections.

## By role

| I want to… | Read |
|------------|------|
| Understand the stack and build pipeline (two layers: base + app image) | [001-architecture-overview.md](001-architecture-overview.md) |
| Build images, lint, GHCR naming, bootc patterns in depth | [002-building-bootc-images.md](002-building-bootc-images.md) |
| Step-by-step clone → EC2 **and** day-2 ops (upgrade, rollback, debug, gotchas) | [003-walkthrough-and-runbook.md](003-walkthrough-and-runbook.md) |
| Build local disk images or pull/deploy artifacts (AWS, GCE, VMware, QCOW2) | [004-manual-build-and-deployment.md](004-manual-build-and-deployment.md) |
| Why immutable `/usr/share` configs, release scenarios, partitions | [005-production-upgrade-scenarios.md](005-production-upgrade-scenarios.md) |
| Local testing, test case registry (TC-xx), QEMU, post-deploy audit, troubleshooting | [006-testing-guide-and-registry.md](006-testing-guide-and-registry.md) |
| `rootfs/` layout, file mapping, add a component | [007-rootfs-overlay-guide.md](007-rootfs-overlay-guide.md) |
| Verify GHCR after CI (`verify-ghcr-packages.sh`) | [008-ghcr-audit.md](008-ghcr-audit.md) |
| SELinux: MongoDB FTDC denials, methods explored, build-time policy approach | [009-selinux-mongodb.md](009-selinux-mongodb.md) |

Doc **005** was renamed from `005-manual-deployments.md` to reflect local build plus deployment. **007** (testing guide) absorbed the former **008** (test case registry). **004** runbook is merged into **003**; **005–009** on disk were renumbered to **004–008** (manual → rootfs → GHCR).

## Canonical topic → doc

| Topic | Canonical doc | Notes |
|-------|-----------------|-------|
| **Build:** `make base`, `make build`, two-layer pipeline | [001](001-architecture-overview.md) + [002](002-building-bootc-images.md) | [003](003-walkthrough-and-runbook.md) §4 and [004](004-manual-build-and-deployment.md) intro only summarize; link here. |
| **`bootc upgrade` / rollback commands** | [003-walkthrough-and-runbook.md](003-walkthrough-and-runbook.md) (Part B — Operations runbook) | [005](005-production-upgrade-scenarios.md) explains *what changes* on disk; operator commands stay in 003 Part B. |
| **Immutable config + `/etc` → `/usr/share` symlinks** | [007-rootfs-overlay-guide.md](007-rootfs-overlay-guide.md) (mapping) + [005](005-production-upgrade-scenarios.md) (why) | [002](002-building-bootc-images.md) stays generic; points to 007 for this repo. |
| **Filesystem theory** (OSTree, `/usr` ro) | [docs/bootc/003-filesystem-layout.md](../bootc/003-filesystem-layout.md) | Project-specific paths: [007](007-rootfs-overlay-guide.md) § Newbie. |
| **GHCR paths, `verify-ghcr`** | [008-ghcr-audit.md](008-ghcr-audit.md) | [004](004-manual-build-and-deployment.md) keeps the artifact path table for deployers. |
| **Post-deploy checks / troubleshooting** | [006-testing-guide-and-registry.md](006-testing-guide-and-registry.md) | Single place for long command lists and TC reference. |
| **SELinux policy — MongoDB FTDC** | [009-selinux-mongodb.md](009-selinux-mongodb.md) | Problem history, methods, and current build-time approach. |

## Numbering

Files use `00N-` prefixes for sort order (currently **001**–**008** in this folder). There is no required reading sequence; [001](001-architecture-overview.md) is the usual starting point.
