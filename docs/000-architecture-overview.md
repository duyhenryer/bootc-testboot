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
        A["Apps (Go binaries, systemd units)"]
        C["Configs (nginx.conf, sshd, etc.)"]
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
| **Apps** | Binaries + systemd units | `COPY apps/*/` → `/usr/bin`, `/usr/lib/systemd/system` |
| **Configs** | nginx, sshd, etc. | `/usr/share/` or `/etc/` (with drop-ins) |

---

## Build Pipeline

```mermaid
flowchart LR
    subgraph Source["Source"]
        APPS[apps/hello/\napps/api/]
        CF[Containerfile]
        CONFIGS[configs/]
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
    ├─ apps/hello/ → output/bin/hello  ├─ Containerfile (single FROM fedora-bootc:41)
    ├─ apps/api/   → output/bin/api    │    ├─ RUN dnf install nginx cloud-init ...
    └─ ...                             │    ├─ COPY output/bin/ /usr/bin/
                                       │    ├─ COPY apps/hello/hello.service ...
                                       │    ├─ COPY configs/nginx.conf ...
                                       │    └─ RUN bootc container lint
                                       │
                                       └─ podman push → ghcr.io/…
                                              │
                                              ├─ bootc-image-builder --type ami  → AMI → EC2
                                              └─ bootc-image-builder --type vmdk → VMDK → OVA → vSphere
```

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
| `/usr` | Mutable | **Read-only** | OS content, binaries, drop-in configs |
| `/etc` | Mutable | **Mutable** | 3-way merge on upgrade; use drop-ins |
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
        A[apps/hello/]
        B[apps/newapp/]
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

1. Create `apps/newapp/` with `main.go`, `go.mod`, `newapp.service`, `newapp-tmpfiles.conf`
2. Add COPY + enable lines in Containerfile (binary auto-built by `make apps`)
3. Add `RUN systemctl enable newapp`
4. `make build` (auto-discovers all `apps/*/` dirs)

All apps share the same OS image; scaling = more `apps/` dirs + COPY lines.

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
| **Many apps** | `apps/api/`, `apps/worker/`, `apps/web/`; same Containerfile pattern |

### Deployment Targets

| Target | Command | Use Case |
|--------|---------|----------|
| **AWS AMI** | `make ami` | Cloud deployment on EC2 |
| **VMware OVA** | `make ova` | On-premise customer delivery via vSphere |
| **VMDK** | `make vmdk` | Direct VMware disk image |

Same pattern everywhere: **Containerfile + systemd units + tmpfiles.d** for `/var` dirs. One image, one source of truth, atomic upgrades. Same OCI image produces AMI, OVA, or any other format via bootc-image-builder.

---

## References

- [bootc: Introduction](https://bootc-dev.github.io/bootc/intro.html)
- [bootc: Relationship with other projects](https://bootc-dev.github.io/bootc/relationships.html)
- [bootc: Filesystem](https://bootc-dev.github.io/bootc/filesystem.html)
- [bootable containers mission](https://containers.github.io/bootable/)
