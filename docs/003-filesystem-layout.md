# Filesystem Layout (MUST UNDERSTAND)

> *Source: [bootc Filesystem](https://bootc-dev.github.io/bootc/filesystem.html)*

This is the most critical document for bootc operations. Misunderstanding the filesystem model leads to failed builds, broken upgrades, and data loss.

---

## Build-Time vs Runtime

```mermaid
flowchart LR
    subgraph Build["During podman build"]
        B1["Everything MUTABLE"]
        B2["RUN dnf install, COPY, etc."]
        B3["Derivation works normally"]
        B1 --> B2 --> B3
    end

    subgraph Runtime["When deployed"]
        R1["/usr READ-ONLY"]
        R2["/etc MUTABLE (3-way merge)"]
        R3["/var MUTABLE, PERSISTENT"]
        R1 --> R2 --> R3
    end

    Build --> Runtime
```

| Phase | State | Notes |
|-------|-------|-------|
| **Build (container)** | Fully mutable | Same as any Docker/podman build |
| **Deployed (booted)** | `/usr` read-only, `/etc` and `/var` mutable | composefs makes root immutable |

---

## ASCII: Filesystem Layout at Runtime

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    DEPLOYMENT ROOT (/)                  │
                    └─────────────────────────────────────────────────────────┘
                                             │
        ┌────────────────────────────────────┼────────────────────────────────────┐
        │                                    │                                    │
        ▼                                    ▼                                    ▼
┌───────────────┐                  ┌───────────────┐                  ┌───────────────┐
│  /usr         │                  │  /etc         │                  │  /var         │
│  READ-ONLY    │                  │  MUTABLE      │                  │  MUTABLE     │
│  (composefs)  │                  │  3-way merge  │                  │  PERSISTENT  │
│               │                  │  on upgrade   │                  │  NOT rolled  │
│ /bin→/usr/bin │                  │              │                  │  back        │
│ /lib→/usr/lib │                  │ Use drop-ins │                  │              │
└───────────────┘                  └───────────────┘                  └───────────────┘
        │                                    │                                    │
        │                                    │                                    │
  Lifecycled with                     Retained across                    Like Docker
  container image                     upgrades (merge)                   VOLUME
```

---

## /usr: READ-ONLY When Deployed

### Contents

- All OS content: binaries, libraries, kernel modules
- `/bin` → `/usr/bin`, `/lib` → `/usr/lib` (UsrMove symlinks)
- Prefer putting configs here for **immutability**

### /usr/local

Default: **regular directory** (part of image). Base images typically keep it this way so derived images can add content.

> *"Projects that want to produce 'final' images that are themselves not intended to be derived from can enable [the symlink to /var/usrlocal] in derived builds."* — [bootc filesystem](https://bootc-dev.github.io/bootc/filesystem.html)

### /usr/etc — DO NOT USE

`/usr/etc` is an **internal implementation detail**. It holds the default `/etc` from the image. **Do not put files here manually**; undefined behavior. `bootc container lint` checks for this.

### Practical: Put Config in /usr

```dockerfile
# Good: config in /usr (immutable)
COPY configs/nginx.conf /usr/share/nginx/nginx.conf
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf
```

---

## /etc: MUTABLE, Persistent, 3-Way Merge

### Default Behavior

- `/etc` **persists** across reboots
- On upgrade: **3-way merge**:
  1. New default `/etc` from image as base
  2. Local modifications are retained
  3. Diff from previous `/etc` applied to new base

### Viewing Local Changes

```bash
ostree admin config-diff
```

Metadata (uid, gid, xattrs) counts as "modified"—changing any of these blocks image updates for that file.

### Best Practice: Drop-In Directories

Avoid editing main config files. Use drop-ins instead:

```dockerfile
# Good: drop-in, less drift
COPY configs/sshd-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf

# Risky: editing main file; 3-way merge can conflict
# COPY configs/sshd_config /etc/ssh/sshd_config
```

### Option: Transient /etc

For stateless systems, set in `/usr/lib/ostree/prepare-root.conf`:

```ini
[etc]
transient = true
```

Then `/etc` is regenerated from image each boot. Machine-specific state may need kernel command line or other mechanisms.

---

## /var: MUTABLE, PERSISTENT, NOT ROLLED BACK

### Critical: Acts Like Docker VOLUME

Content in `/var` in the container image behaves like `VOLUME /var`:

- Unpacked **only on first install**
- **Subsequent changes** to `/var` in new image versions are **NOT applied**
- DB data, logs, caches **survive** upgrades **and** rollbacks

```
Image v1: /var/lib/postgresql/ (initial unpack)
Image v2: /var/lib/postgresql/ (changed structure)
         └── On upgrade: v2 structure NOT applied; v1 content kept
```

### Use tmpfiles.d or StateDirectory=

Pre-create directories needed by services:

```dockerfile
# tmpfiles.d (bootc container lint warns if missing for /var dirs)
COPY apps/hello/hello-tmpfiles.conf /usr/lib/tmpfiles.d/hello.conf
```

```conf
# hello-tmpfiles.conf
d /var/lib/hello/uploads 0750 - - -
```

**Better:** use systemd `StateDirectory=` and `LogsDirectory=`:

```ini
[Service]
StateDirectory=hello
LogsDirectory=hello
ExecStart=/usr/bin/hello
```

This creates `/var/lib/hello` and `/var/log/hello` automatically—no tmpfiles.d needed for those.

### As of bootc 1.1.6

`bootc container lint` warns about missing tmpfiles.d entries for `/var` directories.

---

## /opt: READ-ONLY (Problem Area)

With composefs, `/opt` is **read-only** like `/usr`. Some third-party software (deb/rpm) expects to write under `/opt/examplepkg`.

### Decision Matrix for /opt

| Need | Solution | Trade-off |
|------|----------|-----------|
| App writes to `/opt/examplepkg` | Symlink subdirs to `/var` | Max immutability |
| | `BindPaths=` in systemd unit | Minimal change |
| | `ostree-state-overlay@opt.service` | Writable overlay, some drift |
| | `root.transient=true` | Entire root writable until reboot |

### Solution 1: Symlink to /var (Recommended)

```dockerfile
RUN dnf install -y examplepkg && \
    mv /opt/examplepkg/logs /var/log/examplepkg && \
    ln -sr /var/log/examplepkg /opt/examplepkg/logs
```

### Solution 2: BindPaths in systemd

```ini
[Service]
BindPaths=/var/log/exampleapp:/opt/exampleapp/logs
```

### Solution 3: State Overlay

```dockerfile
RUN systemctl enable ostree-state-overlay@opt.service
```

- Writable overlay on `/opt`
- New image files override local on update
- Persists across reboots
- Some temporary drift until next update

### Solution 4: Transient Root

```ini
# /usr/lib/ostree/prepare-root.conf
[root]
transient = true
```

- Entire root writable (until reboot)
- Combine with symlinks to `/var` for persistence
- Larger mutability surface

---

## Transient Root

Set in `/usr/lib/ostree/prepare-root.conf`:

```ini
[root]
transient = true
```

- Entire root filesystem writable **until next reboot**
- Use symlinks to `/var` for content that must persist
- Requires initramfs regeneration

---

## State Overlays: ostree-state-overlay@.service

Template unit for persistent writable overlay on normally read-only paths:

```dockerfile
RUN systemctl enable ostree-state-overlay@opt.service
```

Semantics:

- During updates: new image files override local versions
- Changes persist across reboots
- Smaller surface than transient root

---

## Mermaid: Build vs Deployed State

```mermaid
flowchart TB
    subgraph Build["Build Time (podman build)"]
        B_USR["/usr: writable"]
        B_ETC["/etc: writable"]
        B_VAR["/var: writable"]
        B_OPT["/opt: writable"]
    end

    subgraph Deploy["Deployed (booted)"]
        D_USR["/usr: READ-ONLY"]
        D_ETC["/etc: MUTABLE, 3-way merge"]
        D_VAR["/var: MUTABLE, PERSISTENT"]
        D_OPT["/opt: READ-ONLY (or overlay)"]
    end

    B_USR --> D_USR
    B_ETC --> D_ETC
    B_VAR --> D_VAR
    B_OPT --> D_OPT
```

---

## Practical Containerfile Examples

### Example 1: App with /var State

```dockerfile
# Pre-built binary in /usr (read-only when deployed)
COPY output/bin/ /usr/bin/

# systemd unit with StateDirectory (auto-creates /var/lib/hello)
COPY apps/hello/hello.service /usr/lib/systemd/system/hello.service

# Optional: extra /var dirs via tmpfiles.d
COPY apps/hello/hello-tmpfiles.conf /usr/lib/tmpfiles.d/hello.conf

RUN systemctl enable hello
```

### Example 2: Config in /usr, Symlink in /etc

```dockerfile
# Immutable config in /usr
COPY configs/nginx.conf /usr/share/nginx/nginx.conf
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf
```

### Example 3: Drop-In for /etc

```dockerfile
# Avoid editing main config; use drop-in
COPY configs/sshd-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf
```

### Example 4: /opt Package Needing Writable Dir

```dockerfile
RUN dnf install -y examplepkg && \
    mv /opt/examplepkg/logs /var/log/examplepkg && \
    ln -sr /var/log/examplepkg /opt/examplepkg/logs
```

---

## What NOT to Ship

- `/run`, `/proc` — API filesystems; not for image content
- Manual files in `/usr/etc` — internal use only

---

## composefs Integrity

Ensure `/usr/lib/ostree/prepare-root.conf` contains:

```ini
[composefs]
enabled = true
```

Makes `/` read-only for correct semantics.

Optional: `enabled = verity` for fsverity integrity (see [bootc filesystem](https://bootc-dev.github.io/bootc/filesystem.html) for caveats).

---

## References

- [bootc: Filesystem](https://bootc-dev.github.io/bootc/filesystem.html)
- [bootc: Building guidance](https://bootc-dev.github.io/bootc/building/guidance.html)
- [OSTree prepare-root](https://ostreedev.github.io/ostree/man/ostree-prepare-root.html)
- [OSTree atomic upgrades: 3-way merge](https://ostreedev.github.io/ostree/atomic-upgrades/#assembling-a-new-deployment-directory)
- [systemd tmpfiles.d](https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html)
- [systemd StateDirectory=](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#RuntimeDirectory=)
