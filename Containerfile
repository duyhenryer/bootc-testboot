# =============================================================================
# bootc OS image
# =============================================================================
# Apps are pre-built externally (make apps -> output/bin/).
# This Containerfile only assembles the OS: packages + binaries + configs.
# =============================================================================
FROM quay.io/fedora/fedora-bootc:41

# --- System packages ---
RUN dnf --setopt=fedora-cisco-openh264.enabled=0 install -y \
        nginx \
        cloud-init \
        htop curl jq \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# --- Pre-built app binaries (from output/bin/) ---
COPY output/bin/ /usr/bin/

# --- App systemd units ---
COPY apps/hello/hello.service /usr/lib/systemd/system/hello.service
# COPY apps/api/api.service   /usr/lib/systemd/system/api.service

# --- App tmpfiles.d (for apps needing extra /var dirs) ---
COPY apps/hello/hello-tmpfiles.conf /usr/lib/tmpfiles.d/hello.conf
# COPY apps/api/api-tmpfiles.conf   /usr/lib/tmpfiles.d/api.conf

# --- nginx: config in /usr for immutability (per S6 guidance) ---
COPY configs/nginx.conf /usr/share/nginx/nginx.conf
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf

# --- SSH hardening via drop-in (cleaner than sed for 3-way merge) ---
COPY configs/sshd-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf

# --- ECR credential helper config ---
COPY configs/containers-auth.json /etc/containers/auth.json

# --- Enable services ---
RUN systemctl enable nginx hello cloud-init
# RUN systemctl enable api worker

# --- Image metadata ---
LABEL containers.bootc=1
LABEL org.opencontainers.image.source="https://github.com/duyhenryer/bootc-testboot"

# --- Validate image (catches misconfigurations) ---
RUN bootc container lint


