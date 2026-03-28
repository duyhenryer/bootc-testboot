# =============================================================================
# Application Image (Layer 2)
# =============================================================================
# Base image is pre-built with production tuning (make base).
# This layer adds: middleware + app binaries + systemd units + configs.
#
# Build:
#   make build BASE_DISTRO=centos-stream9
#   make build BASE_DISTRO=fedora-41
# =============================================================================
# Repo root for GHCR path-style names: ghcr.io/<owner>/bootc-testboot/{base/,}<distro>:<tag>
ARG IMAGE_ROOT=ghcr.io/duyhenryer/bootc-testboot
ARG BASE_DISTRO=centos-stream9
ARG BASE_IMAGE_VERSION=latest
ARG GIT_SHA=unknown
# Official MongoDB SELinux module — compile in a throwaway stage so selinux-policy-devel
# does not leave /var/lib/selinux + sepolgen debris in the final image (bootc container lint).
# https://github.com/mongodb/mongodb-selinux
ARG MONGODB_SELINUX_SHA=18181652362a46fd4511a56f20c4055712deb252

FROM ${IMAGE_ROOT}/base/${BASE_DISTRO}:${BASE_IMAGE_VERSION} AS mongodb-selinux-builder
ARG MONGODB_SELINUX_SHA
RUN dnf install -y git make checkpolicy selinux-policy-devel && \
    dnf clean all && \
    rm -rf /var/cache/{dnf,ldconfig} /var/log/{dnf*,hawkey*,rhsm} /var/lib/dnf
RUN git clone https://github.com/mongodb/mongodb-selinux.git /tmp/mongodb-selinux && \
    cd /tmp/mongodb-selinux && git checkout "${MONGODB_SELINUX_SHA}" && \
    make -j"$(nproc)" && \
    install -D -m 0644 build/targeted/mongodb.pp /mongodb.pp && \
    rm -rf /tmp/mongodb-selinux
# Supplemental local module: FTDC proc/sysctl/nfs rules not covered upstream.
COPY bootc/services/mongodb/selinux/mongodb_ftdc_local.te /tmp/mongodb_ftdc_local.te
RUN checkmodule -M -m -o /tmp/mongodb_ftdc_local.mod /tmp/mongodb_ftdc_local.te && \
    semodule_package -o /mongodb-ftdc-local.pp -m /tmp/mongodb_ftdc_local.mod && \
    rm /tmp/mongodb_ftdc_local.te /tmp/mongodb_ftdc_local.mod

FROM ${IMAGE_ROOT}/base/${BASE_DISTRO}:${BASE_IMAGE_VERSION}

# --- Rootfs Overlays (immutable configs, systemd units, tmpfiles, repo files) ---
# Must come BEFORE dnf install so MongoDB + RabbitMQ repo files are visible.
COPY bootc/libs/*/rootfs/ /
COPY bootc/apps/*/rootfs/ /
COPY bootc/services/*/rootfs/ /

# --- Import GPG keys for external repos (MongoDB 8.0 + RabbitMQ/Erlang) ---
RUN rpm --import https://pgp.mongodb.com/server-8.0.asc && \
    rpm --import https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc && \
    rpm --import https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key && \
    rpm --import https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key

RUN dnf install -y logrotate nginx mongodb-org-server mongodb-mongosh erlang rabbitmq-server valkey \
      iptables arptables iputils \
      policycoreutils policycoreutils-python-utils && \
    dnf clean all && \
    rm -rf /var/cache/{dnf,ldconfig} && \
    rm -rf /var/log/{dnf*,hawkey*,rhsm} /var/lib/dnf

COPY --from=mongodb-selinux-builder /mongodb.pp /usr/share/selinux/targeted/mongodb.pp
COPY --from=mongodb-selinux-builder /mongodb-ftdc-local.pp /usr/share/selinux/targeted/mongodb-ftdc-local.pp
# --- SELinux: install MongoDB policy modules at build time (bootc-idiomatic) ---
# semodule writes the compiled policy to /etc/selinux/targeted/policy/ which is
# preserved across upgrades via the /etc 3-way merge. The kernel reads it at boot.
# The kernel-load step (semodule final phase) silently fails in a container build
# context (no /sys/fs/selinux mounted) — || true is intentional.
# restorecon for /var/lib/mongodb is deferred to mongod ExecStartPre because /var
# does not exist at build time (it is created by tmpfiles.d on first boot).
RUN semodule --priority 200 --store targeted \
      --install /usr/share/selinux/targeted/mongodb.pp || true && \
    semodule --priority 100 --store targeted \
      --install /usr/share/selinux/targeted/mongodb-ftdc-local.pp || true && \
    semanage fcontext -a -t mongod_var_lib_t '/var/lib/mongodb(/.*)?' || true

# --- Pre-built app binaries (from output/bin/) ---
COPY output/bin/ /usr/bin/

# --- Immutable configs: symlink /etc -> /usr/share (read-only at runtime) ---
RUN ln -sf /usr/share/nginx/nginx.conf /etc/nginx/nginx.conf && \
    rm -rf /etc/nginx/conf.d && \
    ln -sf /usr/share/nginx/conf.d /etc/nginx/conf.d && \
    ln -sf /usr/share/mongodb/mongod.conf /etc/mongod.conf && \
    mkdir -p /etc/valkey && \
    ln -sf /usr/share/valkey/valkey.conf /etc/valkey/valkey.conf && \
    mkdir -p /etc/rabbitmq && \
    ln -sf /usr/share/rabbitmq/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf

# --- SELinux: allow nginx to proxy to upstream apps ---
RUN setsebool -P httpd_can_network_connect 1 || true

# --- Firewall rules ---
RUN firewall-offline-cmd --zone=public \
    --add-port=80/tcp --add-port=443/tcp --add-port=8080/tcp \
    --add-port=6379/tcp --add-port=27017/tcp \
    --add-port=5672/tcp --add-port=15672/tcp

# --- Auto-enable all services that declare WantedBy= ---
RUN for svc in /usr/lib/systemd/system/*.service; do \
      if grep -q '^WantedBy=' "$svc" 2>/dev/null; then \
        systemctl enable "$(basename "$svc")" 2>/dev/null || true; \
      fi; \
    done

# Cloud / generic hosts: do not keep arptables or rdisc enabled (often fail or are unused on VPC VMs).
RUN systemctl disable arptables.service rdisc.service 2>/dev/null || true && \
    rm -f /etc/systemd/system/multi-user.target.wants/arptables.service \
          /etc/systemd/system/multi-user.target.wants/rdisc.service

# --- Clean /var and /run artifacts from package install + overlay layer merges ---
RUN rm -f /var/log/mongodb/mongod.log && \
    rm -rf /var/lib/dnf /var/lib/rhsm \
    /var/log/{dnf*,hawkey*,rhsm} /var/log/sa \
    /var/cache/{dnf,ldconfig,libdnf5} \
    /var/home/appuser/.bash* \
    /var/roothome/buildinfo \
    /run/cloud-init /run/mongodb /run/rhsm

# --- Validate ---
RUN bootc container lint --fatal-warnings || exit 1

# --- Image metadata ---
ARG IMAGE_ROOT
ARG BASE_DISTRO
ARG BASE_IMAGE_VERSION
ARG GIT_SHA
LABEL containers.bootc=1
LABEL org.opencontainers.image.source="https://github.com/duyhenryer/bootc-testboot"
LABEL org.opencontainers.image.base.name="${IMAGE_ROOT}/base/${BASE_DISTRO}:${BASE_IMAGE_VERSION}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
