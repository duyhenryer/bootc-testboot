# Project documentation index

Use this map to pick the right doc and avoid duplicating content across files. **Canonical home** for each topic is listed — other docs should link here instead of copying long sections.

## By role

| I want to... | Read |
|------------|------|
| Understand the stack and build pipeline (two layers: base + app image) | [001-architecture-overview.md](001-architecture-overview.md) |
| Build images, rootfs overlay convention, immutable config strategy | [002-building-images.md](002-building-images.md) |
| Deploy to AWS / GCE / VMware / Xen / bare metal, upgrade, rollback, ops runbook | [003-deploying-and-upgrading.md](003-deploying-and-upgrading.md) |
| Local testing, test case registry (TC-xx), QEMU, troubleshooting | [004-testing-guide.md](004-testing-guide.md) |
| Verify GHCR after CI, post-deploy VM audit checklist | [005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md) |
| SELinux: MongoDB FTDC denials, build-time policy, case studies | [006-selinux-reference.md](006-selinux-reference.md) |

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

## Numbering

Files use `00N-` prefixes for sort order (currently **001**-**006** in this folder). There is no required reading sequence; [001](001-architecture-overview.md) is the usual starting point.
