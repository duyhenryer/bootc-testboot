# Deep Dive: The Limitations of `bootc`

As a capable DevOps engineer, you must clearly outline the boundaries and trade-offs of this Containerized OS architecture to management, preparing for potential roadblocks:

## 1. Conflict with Legacy Apps
- **Filesystem Read-Only:** This is the most critical barrier. `bootc` locks down (Read-Only) `/usr` and almost the entire operating system, leaving only `/etc` (for configuration) and `/var` (for data) as Read-Write.
- If legacy applications (e.g., older banking software) arbitrarily dump logs into their root installation directories like `/opt/myapp/logs`, they will immediately **crash** on bootc. Overcoming this requires standardizing the applications or heavily utilizing `systemd-tmpfiles`.

## 2. Configuration Management & State Drift
- **No Hot-Fixes:** Imagine a network error at 2 AM. A Sysadmin SSHes into the VM and edits an OS file to restore the app. The next morning, upon reboot or a bootc image update, that manual fix **vaporizes**, as the system reverts back to the exact Container Image state from GitHub.
- **Mindset Shift:** All OS configuration changes must be committed as Infrastructure as Code into the `Containerfile`, rebuilt via CI, and pulled by the server. Local state mutability is completely abolished.

## 3. Disconnect in Managing Out-of-Tree Drivers (e.g., GPUs)
- For VMs running complex peripherals, like NVIDIA GPUs for AI workloads, loading third-party or Out-of-Tree kernel modules into bootc is a severe challenge.
- Drivers must be compiled (kmod pull, akmods) directly into the Container Image during the GitHub Actions pipeline, which massively increases complexity and build times.

## 4. An Evolving Ecosystem (Primarily Red Hat)
- `bootc` originated from Red Hat's OSTree ecosystem (CoreOS), performing flawlessly on Fedora, CentOS Stream, and RHEL.
- Porting `bootc` to Ubuntu or Debian remains highly experimental (as noted in earlier status docs). It requires maturation of `systemd-sysupdate` alongside APT architecture.

## 5. Debugging & Observability
- You cannot arbitrarily run `dnf install strace tcpdump` on a production machine due to the Read-Only `/usr` filesystem.
- Sysadmins must rely on isolated utility containers (using `toolbox` or `distrobox`) packed with debug tools, then cross-mount process namespaces to diagnose issues. The systemic mindset forces a pivot toward Kubernetes-style operations rather than traditional Linux VM administration.
