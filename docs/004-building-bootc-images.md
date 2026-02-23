# Building bootc Images

A deep-dive guide for DevOps teams building bootc-compatible container images. bootc applies the same "layers" technique used for application containers to bootable host systems, using OCI/Docker as the transport format.

**Sources:**
- [bootc: Generic guidance for building images](https://bootc-dev.github.io/bootc/building/guidance.html)
- [bootc: "bootc compatible" images](https://bootc-dev.github.io/bootc/bootc-images.html)

---

## Core Principle: Same as App Containers

Every tool and technique for creating application base images applies to bootc host images. The core pattern is:

```dockerfile
RUN $pkgsystem install somepackage && $pkgsystem clean all
```

For Fedora/RHEL:

```dockerfile
RUN dnf install -y postgresql nginx && dnf clean all
```

For Debian/Ubuntu:

```dockerfile
RUN apt-get update && apt-get install -y postgresql nginx && apt-get clean
```

There is nothing special here compared to application containers. bootc's goal is that building host OS images feels like building app containers.

---

## Understanding Mutability

**During build (inside the container):** The filesystem is fully mutable. Writing to `/usr`, `/etc`, and anywhere else is normal and encouraged. This is when you run `dnf install`, copy config files, create symlinks, etc.

**When deployed:** The container image files are **read-only by default**. The OSTree backend mounts `/usr` (and other image content) read-only. Only specific locations like `/var`, `/etc` (with 3-way merge), and `/home` persist as writable.

Plan your layout accordingly: static content in `/usr`, writable data in `/var`, and machine-local config in `/etc`.

---

## systemd as pid 1

bootc expects **systemd as pid 1**. Unlike microservice containers where the application is pid 1, bootc systems run systemd, which then launches your services via systemd units.

When you install a package:

```dockerfile
RUN dnf -y install postgresql && dnf clean all
```

PostgreSQL ships with a systemd unit. That service will be started the same way as on a package-based system. Embed your own software the same way:

1. Install binaries into `/usr/bin` or `/usr/local/bin`
2. Add a `.service` unit under `/usr/lib/systemd/system/`
3. Enable it with `systemctl enable myservice`

Do not use `ENTRYPOINT` or `CMD` to run your main software—systemd units handle that.

---

## LABEL containers.bootc 1

Add this label to signal that your image is bootc-compatible:

```dockerfile
LABEL containers.bootc=1
```

This helps tooling and documentation identify bootc images. It is strongly recommended by the bootc project.

---

## Kernel Placement

The kernel and initramfs must be in a specific location:

- **Kernel:** `/usr/lib/modules/$kver/vmlinuz`
- **Initramfs:** `initramfs.img` in the same directory

**Do not put content in `/boot`** in your container image. bootc copies the kernel/initramfs from the container image to `/boot` at install/upgrade time.

The `bootc container lint` command checks this. Run it in your build to catch violations.

---

## bootc container lint

Run `bootc container lint` during your image build to catch common misconfigurations:

- Multiple kernels (ambiguous which to boot)
- Bad `/var` layout (e.g. symlinks that conflict with expectations)
- Missing or incorrect tmpfiles.d entries
- Kernel placement issues

Example:

```dockerfile
RUN bootc container lint
```

Add this near the end of your Containerfile, after all layers are applied.

---

## Configuration Placement

### Prefer `/usr` for Static Config (Immutable)

Put configuration in `/usr` when it should be part of the immutable image:

- `/usr/lib/systemd/system/` — systemd units
- `/usr/lib/tmpfiles.d/` — tmpfiles.d fragments
- `/usr/share/<app>/` — application default config

For apps that look in `/etc`, symlink:

```dockerfile
COPY configs/nginx.conf /usr/share/nginx/nginx.conf
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf
```

### `/etc` for Machine-Local Config (3-Way Merge)

`/etc` is machine-local state. OSTree performs a **3-way merge** on `/etc` during updates: changes in the image are applied unless the file was modified locally.

### Drop-in Directories Preferred

Avoid editing monolithic config files. Use drop-in directories instead:

- systemd: `/etc/systemd/system/unit.d/` or `unit.d/*.conf`
- sudoers: `/etc/sudoers.d/` instead of editing `/etc/sudoers`
- SSH: `/etc/ssh/sshd_config.d/`

These reduce state drift and merge conflicts during updates.

---

## Handling Read-Only vs Writable

| Location | Purpose |
|----------|---------|
| `/usr` | Read-only: executables, libraries, static config |
| `/var` | Writable: logs, databases, caches, state |
| `/etc` | Machine-local: config with 3-way merge |

For apps that install to `/opt` and mix data with code:

```dockerfile
RUN apt|dnf install examplepkg && \
    mv /opt/examplepkg/logs /var/log/examplepkg && \
    ln -sr /var/log/examplepkg /opt/examplepkg/logs
```

Alternative: use systemd `BindPaths=` in the unit:

```ini
BindPaths=/var/log/exampleapp:/opt/exampleapp/logs
```

---

## Nesting OCI Containers (Avoid)

OCI uses "whiteouts" (`.wh` files) in the tar stream. Without special handling, whiteouts cannot be nested. A line like:

```dockerfile
RUN podman pull quay.io/exampleimage/someimage
```

can create whiteout files inside your image filesystem and cause problems. Avoid nesting OCI container pulls in bootc builds unless your toolchain explicitly supports it. See [this tracker issue](https://github.com/bootc-dev/bootc/issues/128).

---

## Deriving from Base Images

Start from an official bootc base image and customize:

```dockerfile
FROM quay.io/fedora/fedora-bootc:41
RUN dnf -y install foo && dnf clean all
```

For CentOS Stream:

```dockerfile
FROM quay.io/centos-bootc/centos-bootc:stream9
RUN dnf -y install nginx && dnf clean all
```

Use `podman build`, `buildah`, or `docker build`—any tool that produces OCI images.

---

## Practical Example: Complete Containerfile

```dockerfile
# =============================================================================
# Stage 1: Build application binaries (optional)
# =============================================================================
FROM docker.io/library/golang:1.22-alpine AS builder
WORKDIR /build
COPY apps/hello/go.mod apps/hello/
COPY apps/hello/*.go   apps/hello/
RUN cd apps/hello && CGO_ENABLED=0 go build -o /out/hello .

# =============================================================================
# Stage 2: bootc OS image
# =============================================================================
FROM quay.io/fedora/fedora-bootc:41

# --- System packages ---
RUN dnf install -y nginx cloud-init htop curl jq \
    && dnf clean all && rm -rf /var/cache/dnf

# --- App binaries from builder stage ---
COPY --from=builder /out/hello /usr/bin/hello

# --- App systemd units ---
COPY apps/hello/hello.service /usr/lib/systemd/system/hello.service

# --- App tmpfiles.d (for extra /var dirs if needed) ---
COPY apps/hello/hello-tmpfiles.conf /usr/lib/tmpfiles.d/hello.conf

# --- Config in /usr for immutability ---
COPY configs/nginx.conf /usr/share/nginx/nginx.conf
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf

# --- Drop-in for SSH (avoids 3-way merge issues) ---
COPY configs/sshd-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf

# --- Enable services ---
RUN systemctl enable nginx hello cloud-init

# --- Image metadata ---
LABEL containers.bootc=1
LABEL org.opencontainers.image.source="https://github.com/your-org/your-repo"

# --- Validate image ---
RUN bootc container lint
```

---

## Summary Checklist

- [ ] Use `RUN dnf install` / `apt install` as in app containers
- [ ] Add `LABEL containers.bootc=1`
- [ ] Put kernel at `/usr/lib/modules/$kver/vmlinuz` (base images handle this)
- [ ] Do not add content under `/boot`
- [ ] Put static config in `/usr`, machine-local in `/etc`
- [ ] Prefer drop-in directories over editing monolithic configs
- [ ] Put data under `/var`; symlink from `/opt` if needed
- [ ] Launch services via systemd units, not entrypoint
- [ ] Run `bootc container lint` before finalizing the image
- [ ] Avoid `RUN podman pull` inside the build
