# Registries & Offline Updates

> *Source: [bootc Accessing Registries and Disconnected Updates](https://bootc-dev.github.io/bootc/registries-and-offline.html)*
>
> Related: [containers-registries.conf](https://github.com/containers/image/blob/main/docs/containers-registries.conf.5.md), [containers-auth.json](https://man.archlinux.org/man/containers-auth.json.5)

bootc uses the same image-fetching stack as podman. Registry configuration, mirrors, and offline workflows work the same way you'd expect for container workloads—configure once, bootc honors it automatically.

---

## Image Fetching: containers/image Library

bootc uses the [containers/image](https://github.com/containers/image) library—the same one used by **podman**—to fetch container images. This means:

- bootc honors almost all the same configuration options in `/etc/containers/`
- If you configure podman for a registry, bootc typically works with that config too
- No separate registry setup for bootc vs. application containers

---

## Configuration Locations

| Config | Purpose |
|--------|---------|
| `/etc/containers/registries.conf` | Main registry config |
| `/etc/containers/registries.conf.d/` | Drop-in configs (recommended) |
| `/etc/ostree/auth.json` | Registry authentication (private registries) |

> bootc uses `/etc/ostree/auth.json` for auth, not `~/.docker/config.json` or `$XDG_RUNTIME_DIR/containers/auth.json`. See [auth.json](https://man.archlinux.org/man/containers-auth.json.5).

---

## Mirror Registries

Mirroring applies to bootc the same way it does for podman. Configure once for podman; bootc honors it automatically.

From the [containers/image remapping and mirroring docs](https://github.com/containers/image/blob/main/docs/containers-registries.conf.5.md#remapping-and-mirroring-registries):

**Example: Mirror quay.io to internal registry**

```toml
# /etc/containers/registries.conf.d/mirror.conf

[[registry]]
location = "quay.io"
prefix = "quay.io"

[[registry.mirror]]
location = "registry.internal.corp:5000"
insecure = false
```

All pulls for `quay.io/*` will go to `registry.internal.corp:5000` first. If that fails, it falls back to `quay.io`.

**Example: Block external registries, use only internal**

```toml
# /etc/containers/registries.conf.d/airgap.conf

[[registry]]
location = "quay.io"
blocked = true

[[registry]]
location = "registry.internal.corp:5000"
insecure = true
```

---

## Insecure Registries

Unlike `podman pull --tls-verify=false`, **bootc has no CLI flag** to disable TLS. You must configure it in registries.conf.

**Example: Local registry without TLS**

```toml
# /etc/containers/registries.conf.d/local-registry.conf

[[registry]]
location = "localhost:5000"
insecure = true
```

Or for an internal hostname:

```toml
[[registry]]
location = "registry.corp.local:5000"
insecure = true
```

---

## Private Registries (Authentication)

Private registries need authentication. bootc uses:

```
/etc/ostree/auth.json
```

Format (same as containers-auth.json):

```json
{
  "auths": {
    "quay.io": {
      "auth": "base64(username:password)"
    },
    "registry.internal.corp:5000": {
      "auth": "base64(username:password)"
    }
  }
}
```

Generate the auth string:

```bash
echo -n 'username:password' | base64 -w0
```

Or use `podman login` and copy the auth entry—but place it in `/etc/ostree/auth.json`, not the default podman auth location.

---

## Offline Updates via USB

For fully disconnected environments, you can perform updates by copying the OS image to a USB drive.

### Step 1: Copy Image to OCI Directory (on connected machine)

```bash
skopeo copy docker://quay.io/exampleos/myos:latest oci:/path/to/usb/myos.oci
```

Or for a specific tag:

```bash
skopeo copy docker://quay.io/exampleos/myos:v1.2.3 oci:/media/usb/myos.oci
```

### Step 2: Mount USB on Target and Switch Image Source

```bash
# USB mounted at /mnt/usb
bootc switch --transport oci /mnt/usb/myos.oci
```

This tells bootc to use the OCI directory as the image source. It is **idempotent**—you only need to run it once per image/location.

### Step 3: Apply the Update

```bash
bootc upgrade --apply
```

bootc will fetch and apply the update from the USB device (no network required).

---

## Automating USB-Based Updates

You can automate this with systemd units that:

1. Watch for a USB device with a specific label
2. Mount it (optionally with LUKS)
3. Trigger `bootc switch --transport oci` and `bootc upgrade --apply`

**Example: udev + systemd path unit**

```ini
# /etc/systemd/system/bootc-usb-update.service
[Unit]
Description=Apply bootc update from USB
After=local-fs.target
ConditionPathIsMountPoint=/mnt/usb-update

[Service]
Type=oneshot
ExecStart=/usr/bin/bootc switch --transport oci /mnt/usb-update/myos.oci
ExecStart=/usr/bin/bootc upgrade --apply
```

Combine with a path unit or mount unit that activates when the USB is mounted.

---

## Example: Complete registries.conf.d Setup

**Mirror + insecure internal registry**

```toml
# /etc/containers/registries.conf.d/10-mirrors.conf

# Internal registry (no TLS)
[[registry]]
location = "registry.internal.corp:5000"
insecure = true

# Mirror quay.io via internal
[[registry]]
location = "quay.io"
prefix = "quay.io"

[[registry.mirror]]
location = "registry.internal.corp:5000"
insecure = true
```

---

## Example: Offline Workflow End-to-End

**On connected machine (build/staging):**

```bash
# 1. Pull and copy to USB
skopeo copy docker://quay.io/myorg/myos:latest oci:/media/usb/myos.oci

# 2. Sync to ensure written
sync
# 3. Safely eject USB
```

**On disconnected target:**

```bash
# 1. Insert USB, mount (e.g. /mnt/usb)
# 2. Switch to USB image source (once)
bootc switch --transport oci /mnt/usb/myos.oci

# 3. Apply update
bootc upgrade --apply
# System reboots into new image
```

---

## Quick Reference

| Scenario | Config / Action |
|----------|-----------------|
| Mirror registry | `registries.conf.d` with `[[registry.mirror]]` |
| Insecure registry | `insecure = true` in `[[registry]]` |
| Private registry | `/etc/ostree/auth.json` with `auth` entries |
| Offline USB update | `skopeo copy` → `bootc switch --transport oci` → `bootc upgrade --apply` |
