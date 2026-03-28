# SELinux and MongoDB on bootc: Problems, Methods, and Current Solution

This document records every SELinux problem encountered while running MongoDB 8.0 on bootc-managed
CentOS Stream 9 / Fedora VMs, the methods that were explored, and why the current build-time
approach is the correct one for an image-based OS.

> **Pre-requisite reading:**
> - [docs/bootc/003-filesystem-layout.md](../bootc/003-filesystem-layout.md) — understand
>   `/usr`, `/etc`, `/var` before reading this doc.
> - [001-architecture-overview.md](001-architecture-overview.md) — the two-layer image design.

---

## Table of Contents

- [1. SELinux in a bootc Image](#1-selinux-in-a-bootc-image)
- [2. Problem 1 — Wrong Disk Image Format for Xen Orchestra](#2-problem-1--wrong-disk-image-format-for-xen-orchestra)
- [3. Problem 2 — MongoDB FTDC SELinux Denials](#3-problem-2--mongodb-ftdc-selinux-denials)
- [4. Methods Explored](#4-methods-explored)
  - [Method A — Runtime Service (mongodb-selinux.service)](#method-a--runtime-service-mongodb-selinuxservice)
  - [Method B — semanage permissive](#method-b--semanage-permissive)
  - [Method C — dontaudit-only module](#method-c--dontaudit-only-module)
  - [Method D — Disable FTDC in mongod.conf](#method-d--disable-ftdc-in-mongodconf)
  - [Method E — Build-time semodule (current)](#method-e--build-time-semodule-current)
- [5. Current Solution in Detail](#5-current-solution-in-detail)
  - [5.1 Supplemental local module: mongodb-ftdc-local.te](#51-supplemental-local-module-mongodb-ftdc-localte)
  - [5.2 Build-time compilation and installation](#52-build-time-compilation-and-installation)
  - [5.3 First-boot restorecon](#53-first-boot-restorecon)
  - [5.4 Service ordering after the refactor](#54-service-ordering-after-the-refactor)
- [6. Verification Checklist](#6-verification-checklist)
- [7. References](#7-references)

---

## 1. SELinux in a bootc Image

bootc systems run with **SELinux in enforcing mode by default**. This is a deliberate security
decision: the immutable `/usr` filesystem and mandatory access controls complement each other. Even
if an attacker compromises a process, the SELinux domain for that process limits what it can do on
the rest of the system. [^1]

The key bootc-specific constraint for SELinux policy is the filesystem lifecycle:

| Path | Build time | Runtime | On upgrade |
|------|-----------|---------|------------|
| `/usr` | Fully mutable | **Read-only** (composefs) | Replaced entirely by new image |
| `/etc` | Fully mutable | Mutable | **3-way merge** — local changes retained |
| `/var` | Fully mutable | Mutable, persistent | **Never overwritten** |

SELinux policy lives in `/etc/selinux/targeted/`. Because `/etc` is **preserved across upgrades via
3-way merge**, any policy compiled and installed at build time persists through `bootc upgrade`
cycles. The kernel reads the compiled policy from `/etc/selinux/targeted/policy/policy.XX` at every
boot. [^2]

**Implication:** there is no need for a runtime `semodule` service on a bootc system. Running
`semodule` in the Containerfile during the image build is the correct pattern and is explicitly
endorsed by the Fedora bootc community. [^3]

---

## 2. Problem 1 — Wrong Disk Image Format for Xen Orchestra

### Symptom

SELinux AVC denials appeared in the journal immediately after deploying to a Xen Orchestra
(XCP-ng) host. The denials were the first indicator but the root cause was the disk image format,
not the SELinux policy.

### Root cause

The OVA artifact was being imported into Xen Orchestra. OVA is a **VMware-specific format**. The
OVF descriptor bundled in this project's `builder/ova/bootc-testboot.ovf` contains:

- `vmw:firmware="efi"` — VMware-proprietary EFI descriptor
- `vmx-19` hardware version — VMware proprietary
- `VmxNet3` NIC adapter — VMware paravirtual NIC absent in Xen
- `lsilogic` SCSI controller — optimised for vSphere

When Xen Orchestra imports an OVA it strips the VMware hardware definitions and substitutes its own
defaults. The mismatch can cause unexpected device naming, wrong console assignment, and in some
configurations an early-boot environment where selinuxfs is not yet available when userspace
services start — making `semodule` calls fail if attempted at runtime.

### Fix

| Target | Correct format |
|--------|---------------|
| VMware vSphere / ESXi | OVA (VMDK + OVF) |
| Xen Orchestra / XCP-ng | **QCOW2** |
| AWS EC2 | AMI (raw) |
| GCP | raw → tar.gz |
| KVM / libvirt | QCOW2 |

For Xen Orchestra, pull and use the QCOW2 artifact:

```bash
# Extract QCOW2 from the OCI scratch image published by CI
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot/centos-stream9/qcow2:latest /bin/true)
podman export "$ctr" | tar -x --wildcards '*.qcow2' -C ./
podman rm "$ctr"
```

Import the `.qcow2` into Xen Orchestra as a new disk, create a VM with:
- **Firmware:** UEFI (EFI)
- **Disk bus:** virtio-blk or SCSI
- **NIC:** virtio

---

## 3. Problem 2 — MongoDB FTDC SELinux Denials

### Symptom

After deploying the image (with the correct QCOW2 format), the journal showed repeated AVC denials:

```
avc:  denied  { search } for  pid=<mongod-pid>
      comm="mongod" name="nfs" dev="..." ino=...
      scontext=system_u:system_r:mongod_t:s0
      tcontext=system_u:object_r:var_lib_nfs_t:s0
      tclass=dir  permissive=0

avc:  denied  { search } for  pid=<mongod-pid>
      comm="mongod" name="proc" dev="..."
      scontext=system_u:system_r:mongod_t:s0
      tcontext=system_u:object_r:proc_t:s0
      tclass=dir  permissive=0

avc:  denied  { search } for  pid=<mongod-pid>
      comm="mongod" name="fs"
      scontext=system_u:system_r:mongod_t:s0
      tcontext=system_u:object_r:sysctl_fs_t:s0
      tclass=dir  permissive=0
```

### What is FTDC?

FTDC (Full Time Diagnostic Data Capture) is MongoDB's always-on metrics collector. It runs as an
internal thread within the `mongod` process and periodically collects system-level metrics by
reading from the proc filesystem. [^4] The specific reads that trigger AVC denials are:

| Path accessed | SELinux type | Metric collected |
|--------------|-------------|-----------------|
| `/proc/stat` | `proc_t` | CPU utilisation |
| `/proc/meminfo` | `proc_t` | Memory pressure |
| `/proc/diskstats` | `proc_t` | Disk I/O counters |
| `/proc/vmstat` | `proc_t` | Virtual memory statistics |
| `/proc/net/netstat` | `proc_net_t` | TCP/UDP connection statistics |
| `/proc/net/sockstat` | `proc_net_t` | Socket counts |
| `/proc/sys/fs/file-nr` | `sysctl_fs_t` | Open file descriptor count |
| `/var/lib/nfs` | `var_lib_nfs_t` | Triggered by `statvfs()` on NFS mounts (Xen/XCP-ng) |

The last entry is **Xen-specific**. MongoDB FTDC calls `statvfs()` on every mount point listed in
`/proc/mounts` to collect per-filesystem disk space metrics. On XCP-ng hosts with NFS Storage
Repositories, `/var/lib/nfs` is present and is traversed by this `statvfs()` walk. The
`mongod_t` SELinux domain has no `search` permission on `var_lib_nfs_t` directories.

### Why does the upstream module not cover these?

The upstream [mongodb/mongodb-selinux](https://github.com/mongodb/mongodb-selinux) module defines
the `mongod_t` domain using the `selinux-policy-devel` macro infrastructure. The module grants
access to files that MongoDB's core storage engine and network stack need, but at the time the SHA
pinned in this project was written (`18181652`), the FTDC-specific proc and sysctl reads were not
fully enumerated in the upstream policy. The `/var/lib/nfs` traversal is a platform-specific
edge case (Xen NFS SR) that will never be in the upstream module.

---

## 4. Methods Explored

### Method A — Runtime Service (`mongodb-selinux.service`)

**How it worked:**

A systemd oneshot service (`mongodb-selinux.service`) ran at boot using a script
(`mongodb-selinux-load.sh`) that called `semodule --install` on the `.pp` file shipped in the
image, then ran `semanage fcontext` and `restorecon`. The service ran before `mongod.service`
via `After=`/`Before=` ordering in the unit files.

**Why it was wrong for bootc:**

bootc's own documentation is explicit: all system customisations, including SELinux policy, should
happen at container build time. [^3] Running `semodule` at boot contradicts the immutable
image model in three ways:

1. **Build-time is when the filesystem is fully mutable.** The deployed system's `/usr` is
   read-only. Doing policy work at runtime means the system is not fully configured when the
   kernel first enforces policy — there is a window between boot and when the service finishes
   where `mongod` might start with the wrong policy.

2. **`/etc/selinux/` persists through `bootc upgrade`** via 3-way merge. Policy compiled at
   build time is already present in the upgraded image — no runtime reload needed.

3. **Fragility.** If `semodule` fails at runtime (e.g. selinuxfs not yet mounted, or
   `policycoreutils` missing), mongod starts in a broken policy state. Errors are silent
   without explicit monitoring.

**Status:** Removed.

---

### Method B — `semanage permissive`

Adding `mongod_t` to the permissive domain list:

```bash
semanage permissive -a mongod_t
```

This tells SELinux to log but not enforce denials for `mongod_t`. It suppresses all AVC messages
and lets FTDC work, but removes the SELinux enforcement boundary for MongoDB entirely. Any
vulnerability in `mongod` would not be contained by SELinux. This trades security for
convenience and is not acceptable for a production appliance.

**Status:** Rejected.

---

### Method C — `dontaudit`-only module

A policy module containing only `dontaudit` rules for the denied access patterns would suppress the
AVC log spam without actually granting access:

```te
dontaudit mongod_t proc_t:dir search;
dontaudit mongod_t sysctl_fs_t:dir search;
dontaudit mongod_t var_lib_nfs_t:dir search;
```

`dontaudit` suppresses the log entry but the access is still **denied**. FTDC would still fail to
read `/proc` and the metrics would be missing. This is cosmetic only and does not fix the
underlying problem.

**Status:** Rejected (use `allow` rules instead).

---

### Method D — Disable FTDC in `mongod.conf`

MongoDB exposes a configuration option to disable FTDC:

```yaml
# mongod.conf
diagnosticDataCollection:
  enabled: false
```

This stops FTDC from starting, eliminating all the proc/sysctl/nfs access and the denials.
However, FTDC is a key operational tool:

- It provides 1-second granularity metrics without any external monitoring agent.
- `mongodump` and support tooling (`mdiag`, `mtools`) rely on FTDC data.
- MongoDB Atlas and support teams ask for FTDC archives when diagnosing issues.

Disabling FTDC makes the deployment harder to operate and support.

**Status:** Rejected.

---

### Method E — Build-time `semodule` (current)

**How it works:**

Both the upstream `mongodb.pp` and the supplemental `mongodb-ftdc-local.pp` are installed at
**image build time** using two `semodule --install` calls in the application `Containerfile`. The
`semanage fcontext` rule for `/var/lib/mongodb` is also set at build time. The only first-boot
step is `restorecon /var/lib/mongodb`, deferred to `ExecStartPre` in `mongod.service.d/override.conf`
because `/var` does not exist at build time.

**Why this is correct for bootc:** [^2] [^3]

- `semodule` writes the compiled policy to `/etc/selinux/targeted/policy/` — part of `/etc/`,
  which is persisted and 3-way merged across upgrades.
- The kernel reads the compiled policy from disk at boot. No userspace service is needed to
  load it.
- The supplemental module `mongodb-ftdc-local` is pinned at priority 100 (below the upstream
  module's priority 200) so the upstream module's rules take precedence.
- `|| true` on each `semodule` call is intentional: the kernel-load phase of `semodule` fails
  in a container build context (no `/sys/fs/selinux` mounted), but the policy is correctly
  compiled and written to disk. The Fedora bootc community explicitly confirms this pattern
  works. [^3]

**Status:** Current implementation.

---

## 5. Current Solution in Detail

### 5.1 Supplemental local module: `mongodb-ftdc-local.te`

**Location:** `bootc/services/mongodb/selinux/mongodb-ftdc-local.te`

This is a minimal Type Enforcement source file (`.te`) that adds only the access rules that the
upstream `mongodb-selinux` module does not provide. It uses the raw `module`/`require` syntax
(not selinux-policy-devel macro notation) so it can be compiled with `checkmodule` alone, without
needing the full `selinux-policy-devel` interface files at runtime.

```te
module mongodb_ftdc_local 1.0;

require {
    type mongod_t;
    type proc_t;
    type proc_net_t;
    type sysctl_fs_t;
    type var_lib_nfs_t;
    class dir  { getattr open read search };
    class file { getattr open read };
}

# FTDC: /proc entries for CPU, memory, disk, vmstat metrics
allow mongod_t proc_t:dir  search;
allow mongod_t proc_t:file { getattr open read };

# FTDC: /proc/net/* for network statistics (netstat, sockstat)
allow mongod_t proc_net_t:dir  search;
allow mongod_t proc_net_t:file { getattr open read };

# FTDC: /proc/sys/fs for filesystem kernel parameters (file-nr)
allow mongod_t sysctl_fs_t:dir  search;
allow mongod_t sysctl_fs_t:file { getattr open read };

# FTDC statvfs: /var/lib/nfs traversal on Xen/XCP-ng with NFS SR mounts
allow mongod_t var_lib_nfs_t:dir search;
```

The module is deliberately minimal — it grants the minimum permissions required for FTDC to
function, without opening any broader access.

### 5.2 Build-time compilation and installation

The `Containerfile` uses a **two-stage build** for all SELinux artefacts:

**Stage 1 — `mongodb-selinux-builder`** (throwaway stage):

```dockerfile
FROM ... AS mongodb-selinux-builder
RUN dnf install -y git make checkpolicy selinux-policy-devel

# Upstream module
RUN git clone https://github.com/mongodb/mongodb-selinux.git /tmp/mongodb-selinux && \
    cd /tmp/mongodb-selinux && git checkout "${MONGODB_SELINUX_SHA}" && \
    make -j"$(nproc)" && \
    install -D -m 0644 build/targeted/mongodb.pp /mongodb.pp

# Local supplemental module
COPY bootc/services/mongodb/selinux/mongodb-ftdc-local.te /tmp/mongodb-ftdc-local.te
RUN checkmodule -M -m -o /tmp/mongodb-ftdc-local.mod /tmp/mongodb-ftdc-local.te && \
    semodule_package -o /mongodb-ftdc-local.pp -m /tmp/mongodb-ftdc-local.mod
```

`checkpolicy` (which provides `checkmodule` and `semodule_package`) is installed only in the
builder stage. This keeps `selinux-policy-devel` and its build-time debris out of the final image,
which would otherwise cause `bootc container lint` failures. [^5]

**Stage 2 — final image**:

```dockerfile
COPY --from=mongodb-selinux-builder /mongodb.pp \
     /usr/share/selinux/targeted/mongodb.pp
COPY --from=mongodb-selinux-builder /mongodb-ftdc-local.pp \
     /usr/share/selinux/targeted/mongodb-ftdc-local.pp

RUN semodule --priority 200 --store targeted \
      --install /usr/share/selinux/targeted/mongodb.pp || true && \
    semodule --priority 100 --store targeted \
      --install /usr/share/selinux/targeted/mongodb-ftdc-local.pp || true && \
    semanage fcontext -a -t mongod_var_lib_t '/var/lib/mongodb(/.*)?' || true
```

The `.pp` files are kept in `/usr/share/selinux/targeted/` at runtime as reference copies (useful
for `semodule -lfull` inspection and manual reinstallation).

### 5.3 First-boot `restorecon`

`/var/lib/mongodb` does not exist at build time. bootc's `/var` is the **persistent state
layer** — it behaves like a Docker `VOLUME`: content from the image is unpacked only on first
install, and subsequent upgrades never overwrite it. Directories under `/var` are created by
`systemd-tmpfiles` on first boot using the `tmpfiles.d` fragments shipped in the image.

Because `restorecon` requires the directory to exist, it cannot run at build time. It is placed
as an `ExecStartPre` in `mongod.service.d/override.conf`:

```ini
[Service]
ExecStartPre=/usr/sbin/restorecon -RFv /var/lib/mongodb
```

`restorecon` reads the fcontext rule that was registered at build time
(`semanage fcontext -a -t mongod_var_lib_t '/var/lib/mongodb(/.*)?' `) and applies the
`mongod_var_lib_t` label to the directory and its children. It is idempotent and runs on every
`mongod` start — safe and correct.

### 5.4 Service ordering after the refactor

The `mongodb-selinux.service` unit and `mongodb-selinux-load.sh` script have been removed.
The boot sequence is now:

```
systemd-tmpfiles-setup
  └─ creates /var/lib/mongodb (correct owner + permissions)

mongodb-setup.service   [Before=mongod]
  └─ gen-password, gen-tls-cert, gen-keyFile, chown (first boot only)

mongod.service
  └─ ExecStartPre: restorecon -RFv /var/lib/mongodb  ← applies SELinux label
  └─ ExecStart:    mongod (starts with mongod_var_lib_t on dbPath)

mongodb-init.service    [After=mongod]
  └─ rs.initiate() + createUser admin (first boot only)
```

---

## 6. Verification Checklist

After deploying the image, SSH in and confirm the following:

```bash
# 1. Both SELinux modules are loaded
semodule -l | grep mongodb
# Expected output:
#   mongodb               <version>
#   mongodb_ftdc_local    1.0

# 2. /var/lib/mongodb has the correct SELinux type
ls -laZ /var/lib/mongodb
# Expected: ... mongod_t:s0 or mongod_var_lib_t label on the directory

# 3. No FTDC-related AVC denials in the journal
ausearch -m AVC -c mongod 2>/dev/null | grep -E 'proc|sysctl|nfs' || echo "clean"

# 4. MongoDB is running and FTDC is collecting
mongosh --quiet "mongodb://127.0.0.1:27017/" \
  --eval 'db.adminCommand({serverStatus: 1}).diagnosticData' 2>/dev/null | head -5
# Should return diagnosticData object, not null

# 5. Confirm SELinux is enforcing (not permissive)
getenforce
# Expected: Enforcing
```

---

## 7. References

[^1]: Red Hat — *How image mode for RHEL improves security* (2025).
  The article explains how immutability and SELinux enforcement layer together in image-mode
  deployments.
  <https://developers.redhat.com/articles/2025/02/25/how-image-mode-rhel-improves-security>

[^2]: bootc — *Filesystem layout*.
  Authoritative description of `/usr` (read-only), `/etc` (3-way merge), `/var` (persistent)
  in a deployed bootc system.
  <https://bootc-dev.github.io/bootc/filesystem.html>

[^3]: Fedora Discussion — *Custom SELinux policy module in bootc container* (2024).
  Community confirmation that `semodule -X 300 -i module.cil` (or equivalent) in a Containerfile
  `RUN` step bakes the policy into `/etc/selinux/` and remains active after deployment.
  <https://discussion.fedoraproject.org/t/custom-selinux-policy-module-in-bootc-container/158340>

[^4]: MongoDB documentation — *Full Time Diagnostic Data Capture (FTDC)*.
  Describes what FTDC collects and from which `/proc` paths.
  <https://www.mongodb.com/docs/manual/administration/analyzing-mongodb-performance/#full-time-diagnostic-data-capture>

[^5]: bootc — *Building guidance*.
  Recommends using multi-stage builds to avoid leaving build-time tools (compilers, policy-devel
  packages) in the final image. `bootc container lint` warns about policy store debris left by
  `selinux-policy-devel` if installed in the final stage.
  <https://bootc-dev.github.io/bootc/building/guidance.html>

[^6]: mongodb/mongodb-selinux — upstream SELinux policy module for MongoDB.
  This project uses the upstream module as the base and supplements it with a local module
  (`mongodb-ftdc-local`) for paths not covered by the upstream policy.
  <https://github.com/mongodb/mongodb-selinux>
