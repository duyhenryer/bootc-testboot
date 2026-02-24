# Configuration Reference

All configuration files live under `configs/` with two sub-directories:

```
configs/
  os/          <- COPYed into the bootc image (Containerfile)
  builder/     <- Used by bootc-image-builder (AMI / VMDK / OVA)
```

---

## configs/os/ — OS-Level Configs

These files are COPYed into the bootc image at build time via the [Containerfile](../Containerfile).

| File | Installed To | Purpose | Docs |
|------|-------------|---------|------|
| `nginx.conf` | `/usr/share/nginx/nginx.conf` (symlinked to `/etc/nginx/nginx.conf`) | Reverse proxy: routes port 80 to app upstreams (hello:8080). Stored in `/usr` for immutability. | [S6 guidance](https://bootc-dev.github.io/bootc/building/guidance.html) |
| `sshd-hardening.conf` | `/etc/ssh/sshd_config.d/99-hardening.conf` | SSH drop-in: `PermitRootLogin no`, `PasswordAuthentication no`. Drop-in avoids 3-way merge conflicts. | [S6 drop-ins](https://bootc-dev.github.io/bootc/building/guidance.html) |
| `containers-auth.json` | `/etc/containers/auth.json` | Registry credential helper. Currently points to AWS ECR via IMDS (no expiring tokens). | [bootc registries](https://bootc-dev.github.io/bootc/registries-and-offline.html) |
| `dhcpcd-sysusers.conf` | `/usr/lib/sysusers.d/dhcpcd.conf` | Declares `dhcpcd` system user/group. Required by `bootc container lint --fatal-warnings`. | [systemd-sysusers(8)](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysusers.html) |
| `bootc-poc-tmpfiles.conf` | `/usr/lib/tmpfiles.d/bootc-poc.conf` | Declares `/var` directories for system packages (cloud-init, dhcpcd, nginx). Required by `bootc container lint --fatal-warnings`. | [systemd-tmpfiles(5)](https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html) |

### Defaults

**nginx.conf** — key defaults:

```
worker_processes auto;
upstream hello { server 127.0.0.1:8080; }
listen 80 default_server;
```

**sshd-hardening.conf** — all settings:

```
PermitRootLogin no
PasswordAuthentication no
```

**containers-auth.json** — ECR helper (change to match your registry):

```json
{ "credHelpers": { "123456789.dkr.ecr.ap-southeast-1.amazonaws.com": "ecr-login" } }
```

---

## configs/builder/ — Disk Image Builder Configs

Used by `bootc-image-builder` when creating AMI, VMDK, or OVA disk images.

| File | Used By | Purpose |
|------|---------|---------|
| `config.toml` | `scripts/create-ami.sh`, `scripts/create-vmdk.sh` | bootc-image-builder customizations (users, filesystem, kernel) |
| `bootc-poc.ovf` | `scripts/create-ova.sh` | OVF descriptor XML for OVA packaging. Defines VM hardware for vSphere import. |

### config.toml — Defaults

| Section | Key | Default | Purpose |
|---------|-----|---------|---------|
| `customizations.user` | name | `devops` | Default SSH user on the VM |
| | key | `ssh-rsa AAAA...` | SSH public key (replace with yours) |
| | groups | `["wheel"]` | User groups (wheel = sudo) |
| `customizations.filesystem` | `/` minsize | `10 GiB` | Root partition minimum |
| | `/var/data` minsize | `50 GiB` | App data partition |
| `customizations.kernel` | append | `console=tty0 console=ttyS0,115200n8` | Serial console for AWS/VMware |

Docs: [bootc-image-builder config](https://github.com/osbuild/bootc-image-builder)

### bootc-poc.ovf — Placeholders (filled at build time by `create-ova.sh`)

| Placeholder | Default | Meaning |
|-------------|---------|---------|
| `__VM_NAME__` | `bootc-poc-<version>` | VM display name |
| `__NUM_CPUS__` | `2` | Virtual CPUs |
| `__MEMORY_MB__` | `4096` | RAM in MB |
| `__DISK_SIZE__` | auto-detected from VMDK | VMDK file size in bytes |
| `__DISK_CAPACITY__` | `60` | Disk capacity in GiB |

---

## apps/\*/ — Per-App Configs

Each app under `apps/` has its own config files alongside the source code.

| File Pattern | Installed To | Purpose |
|-------------|-------------|---------|
| `<app>.service` | `/usr/lib/systemd/system/<app>.service` | systemd unit file |
| `<app>-tmpfiles.conf` | `/usr/lib/tmpfiles.d/<app>.conf` | Extra `/var` directories (optional -- `StateDirectory=` in the service handles most cases) |

### Current: `apps/hello/`

**hello.service** — key settings:

```ini
DynamicUser=yes          # no static useradd needed
StateDirectory=hello     # auto-creates /var/lib/hello
LogsDirectory=hello      # auto-creates /var/log/hello
ExecStart=/usr/bin/hello
Restart=always
```

**hello-tmpfiles.conf** — currently empty (demonstrates the pattern for complex apps).

---

## Adding a New Config

**OS config** (baked into bootc image):

1. Create the file in `configs/os/`
2. Add a `COPY` line in the [Containerfile](../Containerfile)
3. Update this README

**Builder config** (used by bootc-image-builder):

1. Create the file in `configs/builder/`
2. Reference it in the relevant script under `scripts/`
3. Update this README

**Where to install (bootc filesystem rules):**

| Type | Install To | Why |
|------|-----------|-----|
| Read-only config | `/usr/share/<pkg>/` or `/usr/lib/` | Immutable, always matches image version |
| Machine-local config | `/etc/<pkg>/` or drop-in under `/etc/<pkg>.d/` | Mutable, survives upgrades via 3-way merge |
| Runtime data dirs | Declare in `tmpfiles.d` or use `StateDirectory=` | Created at boot under `/var` |
| sysusers entries | `/usr/lib/sysusers.d/` | Declares system users for lint compliance |

---

## Adding a New App

1. Create `apps/<name>/` with:

```
apps/<name>/
  main.go              # app source
  go.mod               # Go module
  <name>.service       # systemd unit (copy hello.service as template)
  <name>-tmpfiles.conf # optional extra /var dirs
```

2. In [Containerfile](../Containerfile), add:

```dockerfile
COPY apps/<name>/<name>.service /usr/lib/systemd/system/<name>.service
COPY apps/<name>/<name>-tmpfiles.conf /usr/lib/tmpfiles.d/<name>.conf
```

3. Enable the service:

```dockerfile
RUN systemctl enable <name>
```

4. Add upstream in `configs/os/nginx.conf` (if the app serves HTTP):

```nginx
upstream <name> {
    server 127.0.0.1:<port>;
}
```

5. Run `make build` and `make lint-strict` to verify.
