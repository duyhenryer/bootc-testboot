# Users, Groups & SSH Keys

A deep-dive guide for DevOps teams managing users, groups, and SSH access in bootc-based systems. bootc itself does not handle user configuration; it is a generic OS update mechanism. User management patterns must align with the read-only `/usr` and 3-way merge behavior of `/etc` and `/var`.

**Source:** [bootc: Users, groups, SSH keys](https://bootc-dev.github.io/bootc/building/users-and-groups.html)

---

## Generic Base Images Have No Default User

Generic bootc base images (e.g. Fedora, CentOS bootc) do not ship with a default non-root user. Avoid hardcoded passwords and SSH keys with publicly-available private keys in generic images.

---

## System Users via Packages

Packages often create system users during installation:

```dockerfile
RUN dnf install -y postgresql
```

The `postgresql` package runs `useradd` in its post-install script, modifying `/etc/passwd` and `/etc/shadow` during the build. This works for initial install, but creates problems on updates.

---

## Problem: Local `/etc/passwd` and 3-Way Merge

When the system is first installed, the image's `/etc/passwd` is applied. By default, `/etc` is **machine-local persistent state**. If `/etc/passwd` is later modified (e.g. setting root password, adding a user), the 3-way merge will not apply new users from the image on updates—they end up in `/usr/etc/passwd` instead.

**Solution:** Prefer mechanisms that do not rely on `/etc/passwd` being the single source of truth, or use techniques that avoid drift.

---

## Solutions Ranked (Best to Worst)

### 1. DynamicUser=yes (Best)

For system services, use `DynamicUser=yes` in the systemd unit. systemd creates an ephemeral user/group at runtime—no `/etc/passwd` entries, no UID/GID drift.

```ini
[Unit]
Description=Hello World HTTP Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=hello
LogsDirectory=hello
ExecStart=/usr/bin/hello
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`StateDirectory=hello` creates `/var/lib/hello` with correct ownership. `LogsDirectory=hello` does the same for `/var/log/hello`. No `useradd` needed, no UID drift.

### 2. systemd-sysusers (At Boot)

Create users at boot time via sysusers instead of at package install time:

```dockerfile
COPY mycustom-user.conf /usr/lib/sysusers.d/
```

Example `mycustom-user.conf`:

```
u myapp 48 "My application user" /var/lib/myapp /usr/sbin/nologin
```

sysusers modifies `/etc/passwd` at boot, so changes persist across image updates. Avoid having non-root owned files in `/usr` managed by sysusers—system users should not own image content.

### 3. Static UID/GID Allocation

If you must use package-installed users, allocate static UIDs/GIDs before the package runs:

```dockerfile
RUN <<EORUN
set -xeuo pipefail
groupadd -g 10044 mycustom-group
useradd -u 10044 -g 10044 -d /dev/null -M mycustom-user
dnf install -y mycustom-package.rpm
bootc container lint
EORUN
```

### 4. nss-altfiles

[nss-altfiles](https://github.com/aperezdc/nss-altfiles) splits system users into `/usr/lib/passwd` and `/usr/lib/group`. Some base images use this. If `/etc/passwd` is modified locally, image updates to `/usr/lib/passwd` may not merge as expected. Prefer sysusers.d or `DynamicUser=yes`.

---

## SSH Keys: Do NOT Hardcode in Image

Do not bake SSH keys into the image. Use one of:

- **cloud-init / Ignition** — fetch from metadata server (AWS IMDS, GCP, etc.)
- **systemd credentials** — injected at boot (SMBIOS, qemu fw_cfg, etc.)
- **tmpfiles.d** — for transient home dirs with base64-encoded content
- **bootc-image-builder config.toml** — inject at disk image build time (see doc 007)

Example tmpfiles.d for transient `/home` with injected keys:

```
f~ /home/someuser/.ssh/authorized_keys 600 someuser someuser - <base64 encoded data>
```

Save as `/usr/lib/tmpfiles.d/someuser-keys.conf`.

---

## UID/GID Drift

Packages that use "floating" UIDs (without fixed numeric IDs) can allocate different UIDs across rebuilds. Example: CentOS Stream 9 `postgresql` uses [static uid 26](https://gitlab.com/redhat/centos-stream/rpms/postgresql/-/blob/a03cf81d4b9a77d9150a78949269ae52a0027b54/postgresql.spec#L847)—safe. Cockpit's `cockpit-ws` uses a floating UID—risky if it owns persistent state.

**Prevention:**
1. Prefer `DynamicUser=yes` for services
2. Use `systemd-sysusers` with stable allocation
3. Allocate static UID/GID before package install (see above)

---

## Home Directories: /home → /var/home

Common layout: `/home` is a symlink to `/var/home`. Home directories persist but are **not updated by image**. If you inject `/var/home/someuser/.ssh/authorized_keys` in the image, existing systems will not get updates on `bootc upgrade`—`/var` is persistent and not overwritten.

Use cloud-init, tmpfiles.d, or credentials for SSH keys instead of baking them into the image.

---

## tmpfiles.d for Ownership

Use tmpfiles.d `z` or `Z` directives to set ownership/SELinux context on files/dirs:

```
+z /var/lib/my_file 0640 root tss -
```

---

## Practical Example: systemd Unit with DynamicUser=yes + StateDirectory

Service unit (`/usr/lib/systemd/system/hello.service`):

```ini
[Unit]
Description=Hello World HTTP Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=hello
LogsDirectory=hello
ExecStart=/usr/bin/hello
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- `DynamicUser=yes` — no user in /etc/passwd, no drift
- `StateDirectory=hello` — creates `/var/lib/hello` owned by the dynamic user
- `LogsDirectory=hello` — creates `/var/log/hello` owned by the dynamic user

Optional tmpfiles.d if you need extra directories:

```
# /usr/lib/tmpfiles.d/hello.conf
d /var/lib/hello/uploads 0750 - - -
```

---

## Summary Checklist

- [ ] Prefer `DynamicUser=yes` for system services
- [ ] Use `systemd-sysusers` when you need named system users
- [ ] Avoid hardcoding SSH keys; use cloud-init, credentials, or tmpfiles.d
- [ ] Do not rely on `/etc/passwd` being updated from image on systems that modified it locally
- [ ] Be aware of UID/GID drift with floating UIDs
- [ ] Use tmpfiles.d `z`/`Z` for ownership when needed
