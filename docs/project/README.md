# Project documentation index

Use this map to pick the right doc and avoid duplicating content across files. **Canonical home** for each topic is listed—other docs should link here instead of copying long sections.

## By role

| I want to… | Read |
|------------|------|
| Understand the stack and build pipeline (two layers: base + app image) | [001-architecture-overview.md](001-architecture-overview.md) |
| Build images, lint, GHCR naming, bootc patterns in depth | [002-building-bootc-images.md](002-building-bootc-images.md) |
| Step-by-step from clone to EC2, upgrade, rollback | [003-walkthrough.md](003-walkthrough.md) |
| Day-2 ops: `bootc upgrade`, rollback, debug, gotchas | [004-runbook.md](004-runbook.md) |
| Build local disk images or pull/deploy artifacts (AWS, GCE, VMware, QCOW2) | [005-manual-build-and-deployment.md](005-manual-build-and-deployment.md) |
| Why immutable `/usr/share` configs, release scenarios, partitions | [006-production-upgrade-scenarios.md](006-production-upgrade-scenarios.md) |
| Local testing, test case registry (TC-xx), QEMU, post-deploy audit, troubleshooting | [007-testing-guide-and-registry.md](007-testing-guide-and-registry.md) |
| `rootfs/` layout, file mapping, add a component | [008-rootfs-overlay-guide.md](008-rootfs-overlay-guide.md) |
| Verify GHCR after CI (`verify-ghcr-packages.sh`) | [009-ghcr-audit.md](009-ghcr-audit.md) |

Doc **005** was renamed from `005-manual-deployments.md` to reflect local build plus deployment; update any external bookmarks. **007** now includes the former **008** (test case registry); **008/009** on disk are rootfs overlay and GHCR audit (formerly 009/010).

## Canonical topic → doc

| Topic | Canonical doc | Notes |
|-------|-----------------|-------|
| **Build:** `make base`, `make build`, two-layer pipeline | [001](001-architecture-overview.md) + [002](002-building-bootc-images.md) | [003](003-walkthrough.md) §4 and [005](005-manual-build-and-deployment.md) intro only summarize; link here. |
| **`bootc upgrade` / rollback commands** | [004-runbook.md](004-runbook.md) | [006](006-production-upgrade-scenarios.md) explains *what changes* on disk; commands stay in 004. |
| **Immutable config + `/etc` → `/usr/share` symlinks** | [008-rootfs-overlay-guide.md](008-rootfs-overlay-guide.md) (mapping) + [006](006-production-upgrade-scenarios.md) (why) | [002](002-building-bootc-images.md) stays generic; points to 008 for this repo. |
| **Filesystem theory** (OSTree, `/usr` ro) | [docs/bootc/003-filesystem-layout.md](../bootc/003-filesystem-layout.md) | Project-specific paths: [008](008-rootfs-overlay-guide.md) § Newbie. |
| **GHCR paths, `verify-ghcr`** | [009-ghcr-audit.md](009-ghcr-audit.md) | [005](005-manual-build-and-deployment.md) keeps the artifact path table for deployers. |
| **Post-deploy checks / troubleshooting** | [007-testing-guide-and-registry.md](007-testing-guide-and-registry.md) | Single place for long command lists and TC reference. |

## Numbering

Files use `00N-` prefixes for sort order (currently **001**–**009** in this folder). There is no required reading sequence; [001](001-architecture-overview.md) is the usual starting point.
