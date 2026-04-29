# Architecture Overview

A high-level visual guide to how bootc (bootable containers) fits into the stack and how a single Containerfile drives kernel, userspace, apps, and configs through to deployed EC2 instances.

## Table of Contents

- [System Architecture](#system-architecture)
- [Build Pipeline](#build-pipeline)
- [Filesystem Model](#filesystem-model)
- [Upgrade Lifecycle](#upgrade-lifecycle)
- [App Deployment Model](#app-deployment-model)
- [Production Vision](#production-vision)
- [References](#references)

---

## System Architecture

bootc delivers a **single-source-of-truth** model: one Containerfile produces the entire OS image—kernel, userspace, applications, and configuration—deployed natively to physical or virtual machines.

```mermaid
flowchart TB
    subgraph Containerfile["Single Containerfile"]
        direction TB
        K["Linux kernel (/usr/lib/modules)"]
        U["Userspace (systemd, nginx, packages)"]
        A["Apps (Go binaries, systemd units via rootfs)"]
        C["Configs (nginx.conf, sshd, etc. via rootfs)"]
    end

    subgraph Build["Build Time"]
        Containerfile --> OCI["OCI Image"]
    end

    subgraph Registry["Registry (GHCR)"]
        OCI --> GHCR[("GitHub Container Registry")]
    end

    subgraph ImageBuilder["bootc-image-builder"]
        GHCR --> AMI["AMI (AWS)"]
        GHCR --> VMDK["VMDK / OVA (VMware)"]
    end

    subgraph Runtime["Runtime"]
        AMI --> EC2["EC2 Instance"]
        VMDK --> VSPHERE["vSphere VM"]
        EC2 --> PID1["systemd as pid1"]
        VSPHERE --> PID1
        PID1 --> ROOT["OSTree deployment root"]
    end
```

*Equivalent diagram (SVG, tldraw-style layout):*

![System architecture](../images/project/architecture/001-system-architecture.svg)

### Layers from One Containerfile

| Layer | Contents | Source in Image |
|-------|----------|-----------------|
| **Kernel** | Linux kernel + modules | `/usr/lib/modules` (from base image) |
| **Userspace** | systemd, coreutils, packages | `RUN dnf install ...` |
| **Apps** | Binaries + systemd units | `COPY bootc/apps/*/rootfs/` → `/usr/bin`, `/usr/lib/systemd/system` |
| **Configs** | nginx, sshd, etc. | `COPY base/rootfs/` and `COPY bootc/services/*/rootfs/` |

### Makefile: `audit`, `audit-all` vs `verify-ghcr`

| Target | When to use | What it does |
|--------|-------------|--------------|
| `make audit` | Before push / quick local gate | Runs `manifest` + `scan-image`. **No** image build; run `make build && make test-smoke` separately. |
| `make audit-all` | Full local CI parity | Builds **all** base images + app image on disk, runs `bootc container lint --fatal-warnings` on each. **No** `podman pull` from GHCR. |
| `make verify-ghcr` | After CI published to GHCR | Runs [`scripts/verify-ghcr-packages.sh`](../../scripts/verify-ghcr-packages.sh): `skopeo inspect` and `podman pull` of **remote** tags, validates artifact paths. Run on a dev machine with free disk; see [005-ghcr-audit-and-post-deploy.md](005-ghcr-audit-and-post-deploy.md). Use `VERIFY_SKIP_PULL=1` for metadata-only. |

---

## Build Pipeline

```mermaid
flowchart LR
    subgraph Source["Source"]
        APPS[repos/hello/\nrepos/worker/]
        CF[Containerfile]
        CONFIGS[base/rootfs/]
    end

    subgraph AppBuild["App Build"]
        APPS --> MA[make apps]
        MA --> BIN[output/bin/]
    end

    subgraph OSBuild["OS Build"]
        BIN -->|COPY| PB[podman build]
        CF --> PB
        CONFIGS --> PB
        PB --> OCI[OCI Image]
    end

    subgraph Push["Push"]
        OCI --> GHCR[("GHCR")]
    end

    subgraph Bake["Bake"]
        GHCR --> BIB[bootc-image-builder]
        BIB --> AMI[AMI]
        BIB --> VMDK[VMDK]
        VMDK --> OVA[OVA]
    end

    subgraph Deploy["Deploy"]
        AMI --> EC2[("EC2 Instance")]
        OVA --> VS[("vSphere VM")]
    end
```

*Equivalent diagram (SVG, tldraw-style layout):*

![Build pipeline](../images/project/architecture/002-build-pipeline.svg)

### Decoupled Build

```
make apps                          make build
    │                                  │
    ├─ repos/hello/ → output/bin/      ├─ Containerfile (single FROM fedora-bootc:41)
    ├─ repos/worker/ → output/bin/      │    ├─ RUN dnf install nginx cloud-init ...
    └─ ...                             │    ├─ COPY output/bin/ /usr/bin/
                                       │    ├─ COPY base/rootfs /
                                       │    ├─ COPY bootc/apps/*/rootfs/ /
                                       │    ├─ COPY bootc/services/*/rootfs/ /
                                       │    └─ RUN bootc container lint
                                       │
                                       └─ podman push → ghcr.io/…
                                              │
                                              ├─ bootc-image-builder --type ami  → AMI → EC2
                                              └─ bootc-image-builder --type vmdk → VMDK → OVA → vSphere
```

### Rootfs Overlay Mapping

Every component under `bootc/` follows the same pattern: files inside `rootfs/` mirror the target filesystem. `COPY bootc/libs/*/rootfs/ /` strips the `bootc/libs/common/rootfs` prefix and copies everything into `/`.

```mermaid
flowchart LR
    subgraph repo ["Source (repo)"]
        libs["bootc/libs/common/rootfs/"]
        svcs["bootc/services/*/rootfs/"]
        apps["bootc/apps/*/rootfs/"]
    end

    subgraph image ["Image / VM (runtime)"]
        libexec["/usr/libexec/testboot/*.sh"]
        share["/usr/share/mongodb/ valkey/ nginx/"]
        systemd["/usr/lib/systemd/system/"]
        tmpfiles["/usr/lib/tmpfiles.d/"]
        sysusers["/usr/lib/sysusers.d/"]
        yumrepo["/etc/yum.repos.d/"]
        etclink["/etc/*.conf symlinks"]
    end

    libs -->|"COPY / "| libexec
    libs -->|"COPY / "| tmpfiles
    libs -->|"COPY / "| sysusers
    svcs -->|"COPY / "| share
    svcs -->|"COPY / "| systemd
    svcs -->|"COPY / "| tmpfiles
    svcs -->|"COPY / "| sysusers
    svcs -->|"COPY / "| yumrepo
    apps -->|"COPY / "| systemd
    apps -->|"COPY / "| tmpfiles
        share -.->|"ln -sf"| etclink
```

*Equivalent diagram (SVG, tldraw-style layout):*

![Rootfs overlay mapping](../images/project/architecture/003-rootfs-overlay.svg)

| Source Layer | What It Provides | Runtime Location |
|-------------|------------------|-----------------|
| `bootc/libs/common/` | Shared scripts (`log.sh`, `gen-password.sh`, ...) | `/usr/libexec/testboot/` |
| `bootc/services/<name>/` | Immutable configs, systemd overrides, tmpfiles, sysusers, yum repos | `/usr/share/<name>/`, `/usr/lib/systemd/`, `/usr/lib/tmpfiles.d/` |
| `bootc/apps/<name>/` | systemd units, nginx vhosts, tmpfiles | `/usr/lib/systemd/system/`, `/usr/share/nginx/conf.d/` |
| `output/bin/` (separate COPY) | Compiled app binaries | `/usr/bin/` |

Configs in `/usr/share/` are symlinked from `/etc/` at build time (`ln -sf`), making them read-only at runtime while services still find them at the expected `/etc/` path. For the full mapping of every file, see [002-building-images.md](002-building-images.md).

---

## Filesystem Model

```mermaid
flowchart TB
    subgraph ReadOnly["READ-ONLY (composefs)"]
        USR["/usr (OS, binaries, configs)"]
        OPT["/opt (if used)"]
    end

    subgraph Mutable["MUTABLE"]
        ETCDIR["/etc (3-way merge on upgrade)"]
        VARDIR["/var (persistent, NOT rolled back)"]
    end

    subgraph Build["Build-time"]
        B1["Everything mutable for derivation"]
    end

    subgraph Runtime["Runtime (deployed)"]
        USR
        OPT
        ETCDIR
        VARDIR
    end
```

*Equivalent diagram (SVG, tldraw-style layout):*

![Filesystem model](../images/project/architecture/004-filesystem-model.svg)

| Path | Build-time | Runtime | Behavior |
|------|------------|---------|----------|
| `/usr` | Mutable | **Read-only** | OS content, binaries, immutable configs in `/usr/share/` |
| `/etc` | Mutable | **Mutable** | Symlinks to `/usr/share/` for service configs; machine-local state only |
| `/var` | Mutable | **Mutable, persistent** | Data survives upgrade and rollback |

---

## Upgrade Lifecycle

```mermaid
stateDiagram-v2
    [*] --> Running: Boot
    Running --> DownloadOnly: bootc upgrade --download-only
    DownloadOnly --> Staged: Update downloaded
    Staged --> Running: No reboot yet
    Staged --> Apply: bootc upgrade --apply
    Apply --> Reboot: New bootloader entry created
    Reboot --> [*]: New deployment active
```

*Equivalent diagram (SVG, tldraw-style layout):*

![Upgrade lifecycle](../images/project/architecture/005-upgrade-lifecycle.svg)

### Phased Upgrade (Production-Safe)

| Phase | Command | When |
|-------|---------|------|
| **1. Download** | `bootc upgrade --download-only` | Business hours; no downtime |
| **2. Apply** | `bootc upgrade --apply` | Maintenance window; triggers reboot |

### A/B Deployment with OSTree

```
/sysroot/ostree/deploy/default/
├── deploy/abc123.../     ← Current (booted)
└── deploy/def456.../     ← Staged (new)
```

On reboot, the bootloader atomically switches to the staged deployment. Rollback = boot the previous deployment.

---

## App Deployment Model

```mermaid
flowchart LR
    subgraph Repo["Repository"]
        A[repos/hello/]
        B[repos/worker/]
    end

    subgraph Image["Container Image"]
        A --> BIN["/usr/bin/hello"]
        A --> SVC["hello.service"]
        A --> TMP["hello-tmpfiles.conf"]
        B --> BIN2["/usr/bin/worker"]
        B --> SVC2["worker.service"]
    end

    subgraph Runtime["Runtime"]
        SVC --> NGINX[nginx]
        SVC2 --> INFRA["mongodb / rabbitmq / valkey"]
    end
```

*Equivalent diagram (SVG, tldraw-style layout):*

![App deployment model](../images/project/architecture/006-app-deployment.svg)

### Adding a New App

1. Create `repos/<newapp>/` with `main.go`, `go.mod`
2. Create `bootc/apps/<newapp>/rootfs/` mimicking the OS structure (systemd unit, sysusers.d, tmpfiles.d, env defaults).
3. Auto-enable picks up any `.service` with `WantedBy=` in the Containerfile loop.
4. `make build` (auto-discovers all `repos/*/` dirs for compiling bins)

See [AGENTS.md "Adding a New App"](../../AGENTS.md) for the full checklist.

All apps share the same OS image; scaling = more `bootc/apps/` dirs + COPY lines.

---

## Production Vision

```mermaid
flowchart TB
    subgraph POC["Current POC"]
        H[hello service]
        N[nginx]
        CI[cloud-init]
    end

    subgraph Production["Full Stack (current)"]
        N2["nginx (reverse proxy)"]
        V[valkey]
        M[rabbitmq]
        DB[mongodb]
        A1[hello]
        A2[worker]
    end

    subgraph Targets["Deployment Targets"]
        AMI[AWS AMI]
        OVA[VMware OVA]
        QCOW[QCOW2]
        ISO[ISO]
    end

    POC --> Production
    Production --> Targets
```

*Equivalent diagram (SVG, tldraw-style layout):*

![Production vision](../images/project/architecture/007-production-vision.svg)

### Scaling the POC

| Component | How |
|-----------|-----|
| **nginx** | Already present; add more vhosts/config |
| **valkey** | `RUN dnf install valkey` + `valkey.service` |
| **rabbitmq** | `RUN dnf install rabbitmq-server` + systemd unit |
| **Many apps** | Drop `repos/<name>/` + `bootc/apps/<name>/`; same Containerfile pattern auto-enables |

### Deployment Targets

| Target | CI Trigger | Use Case |
|--------|-----------|----------|
| **AWS AMI** | `workflow_dispatch` with `formats=ami` | Cloud deployment on EC2 |
| **VMware OVA** | `workflow_dispatch` with `formats=vmdk` (auto-packages OVA) | On-premise customer delivery via vSphere |
| **QCOW2** | `workflow_dispatch` with `formats=qcow2` | KVM/libvirt testing |

Same pattern everywhere: **Containerfile + systemd units + tmpfiles.d** for `/var` dirs. One image, one source of truth, atomic upgrades. Same OCI image produces AMI, OVA, or any other format via bootc-image-builder. All disk artifacts are built in CI and published as OCI scratch images to GHCR.

---

## References

- [bootc: Introduction](https://bootc-dev.github.io/bootc/intro.html)
- [bootc: Relationship with other projects](https://bootc-dev.github.io/bootc/relationships.html)
- [bootc: Filesystem](https://bootc-dev.github.io/bootc/filesystem.html)
- [bootable containers mission](https://containers.github.io/bootable/)
