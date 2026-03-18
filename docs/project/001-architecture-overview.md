# Architecture Overview

A high-level visual guide to how bootc (bootable containers) fits into the stack and how a single Containerfile drives kernel, userspace, apps, and configs through to deployed EC2 instances.

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

### Layers from One Containerfile

| Layer | Contents | Source in Image |
|-------|----------|-----------------|
| **Kernel** | Linux kernel + modules | `/usr/lib/modules` (from base image) |
| **Userspace** | systemd, coreutils, packages | `RUN dnf install ...` |
| **Apps** | Binaries + systemd units | `COPY bootc/apps/*/rootfs/` → `/usr/bin`, `/usr/lib/systemd/system` |
| **Configs** | nginx, sshd, etc. | `COPY base/rootfs/` \u0026 `COPY bootc/services/*/rootfs/` |

---

## Build Pipeline

```mermaid
flowchart LR
    subgraph Source["Source"]
        APPS[repos/hello/\nrepos/api/]
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

### Decoupled Build

```
make apps                          make build
    │                                  │
    ├─ repos/hello/ → output/bin/      ├─ Containerfile (single FROM fedora-bootc:41)
    ├─ repos/api/   → output/bin/      │    ├─ RUN dnf install nginx cloud-init ...
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
        share["/usr/share/mongodb/ redis/ nginx/"]
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

| Source Layer | What It Provides | Runtime Location |
|-------------|------------------|-----------------|
| `bootc/libs/common/` | Shared scripts (`log.sh`, `gen-password.sh`, ...) | `/usr/libexec/testboot/` |
| `bootc/services/<name>/` | Immutable configs, systemd overrides, tmpfiles, sysusers, yum repos | `/usr/share/<name>/`, `/usr/lib/systemd/`, `/usr/lib/tmpfiles.d/` |
| `bootc/apps/<name>/` | systemd units, nginx vhosts, tmpfiles | `/usr/lib/systemd/system/`, `/usr/share/nginx/conf.d/` |
| `output/bin/` (separate COPY) | Compiled app binaries | `/usr/bin/` |

Configs in `/usr/share/` are symlinked from `/etc/` at build time (`ln -sf`), making them read-only at runtime while services still find them at the expected `/etc/` path. For the full mapping of every file, see [009-rootfs-overlay-guide.md](009-rootfs-overlay-guide.md).

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
    Staged --> Apply: bootc upgrade --from-downloaded --apply
    Apply --> Reboot: New bootloader entry created
    Reboot --> [*]: New deployment active
```

### Phased Upgrade (Production-Safe)

| Phase | Command | When |
|-------|---------|------|
| **1. Download** | `bootc upgrade --download-only` | Business hours; no downtime |
| **2. Apply** | `bootc upgrade --from-downloaded --apply` | Maintenance window; triggers reboot |

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
        B[repos/newapp/]
    end

    subgraph Image["Container Image"]
        A --> BIN["/usr/bin/hello"]
        A --> SVC["hello.service"]
        A --> TMP["hello-tmpfiles.conf"]
        B --> BIN2["/usr/bin/newapp"]
        B --> SVC2["newapp.service"]
    end

    subgraph Runtime["Runtime"]
        SVC --> NGINX[nginx]
        SVC2 --> NGINX
    end
```

### Adding a New App

1. Create `repos/newapp/` with `main.go`, `go.mod`
2. Create `bootc/apps/newapp/rootfs/` mimicking the OS structure.
3. Add `RUN systemctl enable newapp`
4. `make build` (auto-discovers all `repos/*/` dirs for compiling bins)

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

    subgraph Production["Full Stack"]
        N2["nginx (reverse proxy)"]
        R[redis]
        M[rabbitmq]
        A1[app-api]
        A2[app-worker]
        A3[app-web]
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

### Scaling the POC

| Component | How |
|-----------|-----|
| **nginx** | Already present; add more vhosts/config |
| **redis** | `RUN dnf install redis` + `redis.service` |
| **rabbitmq** | `RUN dnf install rabbitmq-server` + systemd unit |
| **Many apps** | `repos/api/`, `repos/worker/`, `repos/web/`; same Containerfile pattern |

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
