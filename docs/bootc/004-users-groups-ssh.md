# Users, Groups & SSH Keys

A beginner-friendly, deep-dive guide for managing users, groups, and SSH access in bootc-based systems. bootc itself does not handle user configuration — it is a generic OS update mechanism. User management patterns must align with the read-only `/usr` and 3-way merge behavior of `/etc` and `/var`.

**Think of it this way:** the container image is a *template*, and each deployed machine is a *copy*. If you bake a password or SSH key into the template, every copy gets the same credential. That is why bootc strongly encourages injecting credentials *outside* the image, at provisioning or runtime.

**Sources:**
- [bootc: Users, groups, SSH keys](https://bootc-dev.github.io/bootc/building/users-and-groups.html)
- [Fedora bootc: Authentication, Users and Groups](https://docs.fedoraproject.org/en-US/bootc/authentication/)
- [RHEL 10 Image Mode: Managing users, groups, SSH keys, and secrets](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/appendix-managing-users-groups-ssh-keys-and-secrets-in-image-mode-for-rhel)

---

## When Do Credentials Get Injected?

Understanding *when* each mechanism runs is the key to choosing the right one:

```
Build time          Install time           Boot time             Runtime
(Containerfile)     (bootc install /       (systemd starts)      (after login)
                     kickstart / BIB)
     │                    │                     │                     │
     ▼                    ▼                     ▼                     ▼
 useradd in         bootc install            sysusers.d            cloud-init
 package scripts    --root-ssh-              creates users         fetches SSH
                    authorized-keys                                keys from
 Static UID/GID                              tmpfiles.d            metadata
 allocation         bootc-image-builder      sets up dirs          server
                    config.toml injects                            (AWS/GCP/Azure)
 bootc container    users + SSH keys         systemd
 lint validates                              credentials           OS Login
                    Kickstart rootpw,        inject secrets        (GCP IAM)
                    sshkey directives
```

**Rule of thumb:**
- Build time = user *structure* (system users for packages)
- Install time = initial *bootstrap* credentials (first SSH key, first password)
- Boot time = *dynamic* user creation (sysusers.d, tmpfiles.d)
- Runtime = *cloud-managed* credentials (cloud-init, OS Login, metadata)

---

## Generic Base Images Have No Default User

Generic bootc base images (e.g. Fedora, CentOS bootc) do **not** ship with a default non-root user, and `root` has no password set. There are no hardcoded credentials of any kind.

**Why?** If a base image shipped with a default password like `password123`, anyone who downloads that image would know the password to every machine running it. This is a fundamental security principle for immutable OS images.

---

## System Users via Packages

Packages often create system users during installation:

```dockerfile
RUN dnf install -y postgresql
```

The `postgresql` package runs `useradd` in its post-install script, modifying `/etc/passwd` and `/etc/shadow` during the build. This works for initial install, but creates problems on updates.

---

## Problem: Local `/etc/passwd` and 3-Way Merge

**What is the 3-way merge?** When bootc updates the OS image, it compares three things: (1) the *old* image's `/etc`, (2) the *new* image's `/etc`, and (3) the *current machine's* `/etc`. If the machine has modified a file (like `/etc/passwd`), bootc keeps the machine's version to avoid overwriting local changes.

This means: if you install the image and then someone sets a root password (which modifies `/etc/passwd`), any new users added in future image updates will **not** appear on that machine. They end up in `/usr/etc/passwd` (the image default) instead of the machine's `/etc/passwd`.

**Solution:** Prefer mechanisms that do not rely on `/etc/passwd` being the single source of truth, or use techniques that avoid drift.

---

## Solutions for System Users (Best to Worst)

### 1. DynamicUser=yes (Best)

For system services, use `DynamicUser=yes` in the systemd unit. systemd creates an ephemeral user/group at runtime — no `/etc/passwd` entries, no UID/GID drift.

This is what the `hello` service in this project uses:

```ini
# bootc/apps/hello/rootfs/usr/lib/systemd/system/hello.service
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

**What each line does:**
- `DynamicUser=yes` — systemd allocates a temporary user for this service. No entry in `/etc/passwd`, no drift across image updates.
- `StateDirectory=hello` — creates `/var/lib/hello` owned by the dynamic user. Data persists across reboots.
- `LogsDirectory=hello` — creates `/var/log/hello` owned by the dynamic user.

### 2. systemd-sysusers (At Boot)

When you need a *named* system user (e.g. for file ownership or multiple services sharing an identity), use sysusers.d. This creates the user at boot time instead of build time, avoiding the 3-way merge problem.

```dockerfile
COPY mycustom-user.conf /usr/lib/sysusers.d/
```

Example `mycustom-user.conf`:

```
u myapp 48 "My application user" /var/lib/myapp /usr/sbin/nologin
```

**What this line means:**
- `u` = create a user
- `myapp` = username
- `48` = fixed UID (use `-` for auto-allocation)
- `"My application user"` = GECOS/description
- `/var/lib/myapp` = home directory
- `/usr/sbin/nologin` = shell (no interactive login)

This project uses sysusers.d for `appuser` and `dhcpcd`:

```
# base/rootfs/usr/lib/sysusers.d/appuser.conf
u appuser - "Application User" /var/home/appuser /bin/bash
m appuser wheel
```

The `m appuser wheel` line adds `appuser` to the `wheel` group (sudo access).

### 3. Static UID/GID Allocation

If you must use package-installed users, allocate static UIDs/GIDs *before* the package runs its post-install scripts:

```dockerfile
RUN <<EORUN
set -xeuo pipefail
groupadd -g 10044 mycustom-group
useradd -u 10044 -g 10044 -d /dev/null -M mycustom-user
dnf install -y mycustom-package.rpm
bootc container lint
EORUN
```

**Why pre-allocate?** Package post-install scripts call `useradd` without specifying a UID, so they get whatever UID is next available. If you rebuild the image with different packages, the UID can change ("drift"), breaking ownership of persistent files in `/var`.

### 4. nss-altfiles

[nss-altfiles](https://github.com/aperezdc/nss-altfiles) splits system users into `/usr/lib/passwd` and `/usr/lib/group`. Some base images (built by rpm-ostree) use this. If `/etc/passwd` is modified locally, image updates to `/usr/lib/passwd` may not merge as expected. Prefer sysusers.d or `DynamicUser=yes`.

---

## SSH Keys: Do NOT Hardcode in Image

**Never bake SSH keys into the container image.** If the image is pushed to a registry (even a private one), anyone with pull access gets the keys. And since `/var/home` is persistent state, you cannot rotate keys by updating the image — existing machines keep the old keys.

Instead, inject SSH keys at one of these stages:

| Method | When it runs | Best for |
|--------|-------------|----------|
| `bootc install --root-ssh-authorized-keys` | Install time | Bare-metal, local VMs |
| bootc-image-builder `config.toml` | Disk image build | VMDK, QCOW2, AMI, OVA |
| Kickstart `sshkey` directive | Install time | Anaconda-based installs |
| cloud-init | Boot/runtime | AWS, Azure, any cloud with metadata |
| GCP OS Login | Runtime | GCP (IAM-managed) |
| systemd credentials (SMBIOS) | Boot time | QEMU/local VMs |
| tmpfiles.d | Boot time | Transient home directories |

Each method is explained in detail below.

---

## Credential Injection Methods

### bootc install (Bare-metal / VM)

When installing bootc to a disk, use the `--root-ssh-authorized-keys` flag to inject an SSH key for root:

```bash
bootc install to-disk /dev/sda \
  --root-ssh-authorized-keys "ssh-ed25519 AAAA... user@example.com"
```

This writes the key to `/root/.ssh/authorized_keys` at install time. It is **not** stored in the image — it becomes machine-local state.

### bootc-image-builder config.toml (Disk Images)

When building disk images (QCOW2, VMDK, AMI, etc.) with [bootc-image-builder](https://github.com/osbuild/bootc-image-builder), use a `config.toml` to inject users and SSH keys.

This project's `builder/gce/config.toml`:

```toml
# Inject a "devops" user with SSH key and wheel (sudo) group
[[customizations.user]]
name = "devops"
key = "ssh-ed25519 AAAA... duyne"
groups = ["wheel"]
```

**What each field means:**
- `name` = the Linux username to create
- `key` = the SSH public key (will be placed in `~devops/.ssh/authorized_keys`)
- `groups` = Linux groups to add the user to (`wheel` = sudo access)

The same config is used in `builder/vmdk/config.toml` and `builder/qcow2/config.toml`.

### Kickstart / Anaconda (RHEL/Fedora Installs)

When deploying via Anaconda installer with a kickstart file:

```
# Lock root password (no interactive login)
rootpw --iscrypted locked

# Inject SSH key for root
sshkey --username root "ssh-ed25519 AAAA... user@example.com"

# Create an admin user with sudo access
user --name=admin --groups=wheel --password=$6$rounds=4096$... --iscrypted
```

**Notes:**
- `rootpw` is currently required by Anaconda even if you don't want a root password (this is a [known bug](https://docs.fedoraproject.org/en-US/bootc/authentication/))
- Always use `--iscrypted` — never put plaintext passwords in kickstart files
- You **cannot** combine custom kickstart users with bootc-image-builder's `customizations.user` — pick one or the other

### cloud-init (Cloud Deployments)

cloud-init reads user-data from the cloud provider's metadata server and configures users/SSH keys automatically.

Example `#cloud-config` user-data:

```yaml
#cloud-config
users:
  - name: admin                    # Linux username
    groups: wheel                  # Add to sudo group
    sudo: ALL=(ALL) NOPASSWD:ALL   # Passwordless sudo
    ssh_authorized_keys:           # SSH public keys for this user
      - ssh-ed25519 AAAA... user@example.com
```

On AWS, you can skip the user-data entirely — cloud-init automatically fetches the EC2 key pair from the instance metadata server and injects it for the default user.

### systemd Credentials (QEMU / Local VMs)

For local testing with QEMU, inject credentials via SMBIOS firmware:

```bash
# Inject root password via SMBIOS
qemu-system-x86_64 ... \
  -smbios type=11,value=io.systemd.credential:passwd.hashed-password.root=$6$...

# Inject SSH authorized_keys for root
qemu-system-x86_64 ... \
  -smbios type=11,value=io.systemd.credential:ssh.authorized_keys.root="ssh-ed25519 AAAA..."
```

These are processed by `systemd-sysusers` and related services at boot. Currently limited to SMBIOS (QEMU/local VMs).

See [systemd credentials documentation](https://systemd.io/CREDENTIALS/) for the full list of well-known credential names.

### tmpfiles.d (Transient Home Directories)

For systems where `/home` is a tmpfs (wiped on reboot), use tmpfiles.d to inject SSH keys at every boot:

```
f~ /home/someuser/.ssh/authorized_keys 600 someuser someuser - <base64 encoded data>
```

Save as `/usr/lib/tmpfiles.d/someuser-keys.conf` in the image. The `f~` directive creates the file only if it doesn't already exist and decodes the base64 data.

---

## Cloud Agents: What the Base Image Does NOT Include

The bootc base image is intentionally **generic** and ships **without** any cloud-specific agent:

- No cloud-init
- No google-guest-agent
- No vmware-guest-agent
- No qemu-guest-agent
- No Ignition or Afterburn

**Why?** For bare-metal deployments, these agents are unnecessary. For immutable infrastructure, agents like cloud-init that fetch instance metadata and mutate the OS can cause "configuration drift" — the running system diverges from what the image defines, making it harder to reason about what state a machine is in.

**When to add them:** If deploying to a cloud provider that requires metadata-based provisioning (AWS, GCP, Azure), you install the needed agent in your derived image. This project's base Containerfile does exactly that:

```dockerfile
# base/centos/stream9/Containerfile
RUN dnf install -y cloud-init openssh-server ...
RUN systemctl enable cloud-init sshd ...
```

**Source:** [Fedora bootc: Understanding Cloud Agents](https://fedora.gitlab.io/bootc/docs/bootc/cloud-agents/)

---

## Cloud Provider Patterns

### AWS

**How to deploy:**
1. **AMI from bootc-image-builder:** `bootc-image-builder --type ami` creates an AMI directly. Requires AWS credentials and an S3 bucket.
2. **Install-to-existing-root:** Launch a stock RHEL/CentOS EC2 instance, then run:
   ```bash
   dnf -y install podman
   podman run --rm --privileged -v /dev:/dev -v /:/target \
     -v /var/lib/containers:/var/lib/containers --pid=host \
     --security-opt label=type:unconfined_t \
     ghcr.io/your-org/your-image:latest \
     bootc install to-existing-root
   reboot
   ```

**SSH key injection:**

EC2 has a built-in key pair mechanism. When you launch an instance with a key pair, the public key is available at `http://169.254.169.254/latest/meta-data/public-keys/`. cloud-init (which must be installed in your image) fetches this automatically and injects it for the default user.

For custom users or multiple keys, pass cloud-init user-data:

```yaml
#cloud-config
users:
  - name: devops
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... alice@company.com
      - ssh-ed25519 AAAA... bob@company.com
```

**For ECR registry auth,** see [doc 005 (Secrets Management)](005-secrets-management.md).

**Sources:** [Fedora bootc provisioning-aws](https://docs.fedoraproject.org/en-US/bootc/provisioning-aws/), [RHEL 10 bootc AMI docs](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/10/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/creating-bootc-compatible-base-disk-images-by-using-bootc-image-builder)

### GCP

**Important:** bootc-image-builder does **not** yet support GCP disk images directly. The recommended deployment path is `bootc install to-existing-root`.

**How to deploy with OpenTofu:**

The [Fedora bootc GCP guide](https://fedora-bootc-docs-7c668a.gitlab.io/bootc/provisioning-gcp/) shows a pattern: deploy a stock RHEL-9 instance on GCE, inject a startup script via instance metadata that installs podman, runs `bootc install to-existing-root`, and reboots into the bootc image.

```hcl
# Simplified from the Fedora guide
metadata_startup_script = <<-EOS
  dnf -y install podman && \
  podman run --rm --privileged -v /dev:/dev -v /:/target \
    -v /var/lib/containers:/var/lib/containers --pid=host \
    --security-opt label=type:unconfined_t \
    ${var.bootc_image} bootc install to-existing-root && reboot
EOS
```

**SSH access — OS Login (best practice):**

[GCP OS Login](https://cloud.google.com/compute/docs/oslogin/set-up-oslogin) links SSH access to Google IAM accounts. No manual key management — access is granted via IAM roles and keys auto-rotate.

Enable it via instance or project metadata:
```bash
gcloud compute instances add-metadata my-vm --metadata enable-oslogin=TRUE
```

Then add your SSH key to your OS Login profile:
```bash
gcloud compute os-login ssh-keys add --key-file=~/.ssh/id_ed25519.pub --ttl=365d
```

Connect:
```bash
gcloud compute ssh my-vm
```

**Caveat:** OS Login requires `google-guest-agent` in the image, which is not included in the bootc base. You must install it in your derived image if using OS Login.

**SSH access — metadata keys (fallback):**

If not using OS Login, inject SSH keys via instance metadata:
```bash
gcloud compute instances add-metadata my-vm \
  --metadata-from-file ssh-keys=pubkeys.txt
```

**Warning:** GCP's default SSH keys created by `gcloud compute ssh` have short lifespans. After `bootc install to-existing-root`, those keys may expire and you lose access. Use permanent keys or OS Login.

**Sources:** [Fedora bootc provisioning-gcp](https://fedora-bootc-docs-7c668a.gitlab.io/bootc/provisioning-gcp/), [GCP OS Login setup](https://cloud.google.com/compute/docs/oslogin/set-up-oslogin)

### Azure

**How to deploy:** bootc-image-builder does not have native Azure disk support yet. Use a raw image converted for Azure, or the `bootc install to-existing-root` pattern on a stock Azure VM.

**SSH key injection with cloud-init:**

Azure uses cloud-init as its primary Linux provisioning agent. Pass SSH keys via custom data:

```yaml
#cloud-config
users:
  - name: azureuser
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... user@example.com
```

Or let Azure generate keys automatically:
```bash
az vm create --name my-vm --image UbuntuLTS --generate-ssh-keys
```

**Managed identities:** Azure supports system-assigned or user-assigned managed identities for authentication without credential management. These are useful for service-to-service auth (e.g. accessing Azure Key Vault), not for SSH access.

**Source:** [Azure cloud-init docs](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/using-cloud-init)

### vSphere / VMware

**How to deploy:** bootc-image-builder creates VMDK or OVA images (`--type vmdk`). This project packages OVA in CI (see `build-artifacts.yml`).

**SSH keys:** Injected via bootc-image-builder `config.toml` at disk image build time. This project's builder configs all inject a `devops` user with an SSH key:

```toml
# builder/vmdk/config.toml
[[customizations.user]]
name = "devops"
key = "ssh-ed25519 AAAA... duyne"
groups = ["wheel"]
```

**No cloud-init needed** for the initial deployment — keys are baked into the disk image. For Day-2 key management, use Ansible, sssd/LDAP, or re-deploy with an updated config.

### Bare-metal / QEMU

**bootc install:**
```bash
bootc install to-disk /dev/sda \
  --root-ssh-authorized-keys "ssh-ed25519 AAAA... user@example.com"
```

**Anaconda kickstart:**
```
rootpw --iscrypted locked
sshkey --username root "ssh-ed25519 AAAA... user@example.com"
```

**systemd credentials for QEMU:**
```bash
qemu-system-x86_64 ... \
  -smbios type=11,value=io.systemd.credential:passwd.hashed-password.root=$6$...
```

**Source:** [bootc install docs](https://bootc-dev.github.io/bootc/bootc-install.html)

---

## Password Management

### This Project Disables Password Authentication

The SSH hardening drop-in at `base/rootfs/etc/ssh/sshd_config.d/99-hardening.conf` disables password-based SSH:

```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
MaxAuthTries 3
```

**Why?** SSH key authentication is stronger than passwords and immune to brute-force attacks. If someone compromises a password, they can access every machine where that password is set. SSH keys are unique per user and can be rotated independently.

### Setting a Root Password Safely (When Needed)

Sometimes you need a root password for emergency console access (e.g. when SSH is broken). **Never** put it in the Containerfile.

**Generate a hashed password:**
```bash
mkpasswd --method=sha-512
# Outputs: $6$rounds=656000$salt$hash...
```

**Inject via kickstart:**
```
rootpw --iscrypted $6$rounds=656000$salt$hash...
```

**Inject via cloud-init:**
```yaml
#cloud-config
chpasswd:
  expire: false
  users:
    - name: root
      password: $6$rounds=656000$salt$hash...
      type: HASH
```

**Inject via systemd credential (QEMU):**
```bash
qemu ... -smbios type=11,value=io.systemd.credential:passwd.hashed-password.root=$6$...
```

---

## UID/GID Drift

**What is UID/GID drift?** When a package creates a user with `useradd` without specifying a UID, the system assigns the next available number. If you rebuild the image with packages in a different order, the UID can change. Now the files in `/var` owned by the old UID belong to a different (or nonexistent) user.

**Example:** CentOS Stream 9 `postgresql` uses a [static uid 26](https://gitlab.com/redhat/centos-stream/rpms/postgresql/-/blob/a03cf81d4b9a77d9150a78949269ae52a0027b54/postgresql.spec#L847) — safe. Cockpit's `cockpit-ws` uses a floating UID — risky if it owns persistent state.

**Prevention:**
1. Prefer `DynamicUser=yes` for services
2. Use `systemd-sysusers` with stable allocation
3. Allocate static UID/GID before package install (see above)

---

## Home Directories: /home → /var/home

Common layout: `/home` is a symlink to `/var/home`. Home directories persist but are **not updated by image**. If you inject `/var/home/someuser/.ssh/authorized_keys` in the image, existing systems will not get updates on `bootc upgrade` — `/var` is persistent and not overwritten.

Use cloud-init, tmpfiles.d, or credentials for SSH keys instead of baking them into the image.

---

## tmpfiles.d for Ownership

Use tmpfiles.d `z` or `Z` directives to set ownership/SELinux context on files/dirs at boot:

```
+z /var/lib/my_file 0640 root tss -
```

**What this does:** At boot, systemd-tmpfiles adjusts the permissions of `/var/lib/my_file` to `0640`, owned by `root:tss`. The `+` means "don't fail if the file doesn't exist yet". This is useful when a package creates a file during install but with wrong ownership.

---

## Validating with `bootc container lint`

`bootc container lint` checks your image for common misconfigurations related to users, `/var` layout, and system structure. **Run it at the end of every Containerfile.**

**What it checks:**
- Missing `sysusers.d` entries for package-created users
- Bad `/var` layout (symlinks that conflict with bootc expectations)
- Missing `tmpfiles.d` entries for `/var` directories
- Multiple kernels (ambiguous which to boot)

**In a Containerfile:**
```dockerfile
# Last validation step before LABEL
RUN bootc container lint
LABEL containers.bootc=1
```

**In CI (strict mode — warnings become errors):**
```bash
podman run --rm $IMAGE bootc container lint --fatal-warnings
```

**In this project:**
- `make lint` — runs `bootc container lint` on the built image
- `make lint-strict` — runs with `--fatal-warnings` (used in CI)
- The `pr-check` job in `ci.yml` runs `bootc container lint --fatal-warnings`

---

## This Project's Configuration

How the theory above maps to actual files in this codebase:

| File | What it does |
|------|-------------|
| `base/rootfs/usr/lib/sysusers.d/appuser.conf` | Creates `appuser` at boot via sysusers (not at build time) |
| `base/rootfs/usr/lib/sysusers.d/dhcpcd.conf` | Satisfies `bootc container lint` for dhcpcd package |
| `base/rootfs/etc/ssh/sshd_config.d/99-hardening.conf` | Disables root login, password auth, limits auth attempts |
| `builder/gce/config.toml` | Injects `devops` user + SSH key for GCE disk images |
| `builder/vmdk/config.toml` | Same for VMware VMDK/OVA images |
| `builder/qcow2/config.toml` | Same for QCOW2 images |
| `base/centos/stream9/Containerfile` | Installs and enables `cloud-init` + `sshd` |

---

## Day-2: Credential Rotation

After initial deployment, how do you change SSH keys or passwords?

**SSH keys:**
- **Cloud (new instances):** Update cloud-init user-data or OS Login profile — new instances get the new key automatically.
- **Cloud (existing instances):** Use instance metadata update (AWS/GCP) or re-run cloud-init.
- **Centralized management:** Use FreeIPA, LDAP/sssd, or Ansible to manage SSH keys across a fleet.
- **Immutable pattern:** Build a new image with updated bootc-image-builder config and re-deploy. This is the cleanest approach for immutable infrastructure.

**Passwords:**
- `passwd` command on the running system
- [Cockpit](https://cockpit-project.org/) web UI
- Automated via config management (Ansible, etc.)

**Remember:** `/etc/passwd` and `/var/home` are persistent local state. Image updates via `bootc upgrade` do **not** overwrite them. Credential rotation must happen through a mechanism that modifies the running system, not just the image.

---

## Summary Checklist

- [ ] Prefer `DynamicUser=yes` for system services
- [ ] Use `systemd-sysusers` when you need named system users
- [ ] **Never** hardcode SSH keys or passwords in the image
- [ ] Use cloud-init / OS Login / metadata for SSH keys in cloud deployments
- [ ] Use `bootc install --root-ssh-authorized-keys` for bare-metal
- [ ] Use bootc-image-builder `customizations.user` for disk images
- [ ] Disable password auth via sshd_config drop-in (`PasswordAuthentication no`)
- [ ] For passwords, use `mkpasswd --method=sha-512` and inject via kickstart / cloud-init / systemd credential
- [ ] Do not rely on `/etc/passwd` being updated from image on systems that modified it locally
- [ ] Be aware of UID/GID drift with floating UIDs
- [ ] Use tmpfiles.d `z`/`Z` for ownership when needed
- [ ] Run `bootc container lint` in every Containerfile to catch misconfigurations at build time
