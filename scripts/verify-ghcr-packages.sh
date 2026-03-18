#!/usr/bin/env bash
# Verify OCI packages published to GHCR for bootc-testboot
# Prerequisite: gh auth login with read:packages scope (run: gh auth refresh -h github.com -s read:packages)

set -e

echo "=== 1. List all packages ==="
gh api /users/duyhenryer/packages?package_type=container --paginate | jq '.[].name'

echo ""
echo "=== 2. Artifact package versions (tags) ==="
for pkg in bootc-testboot-centos-stream9-ami bootc-testboot-centos-stream9-qcow2 bootc-testboot-centos-stream9-raw bootc-testboot-centos-stream9-vmdk bootc-testboot-centos-stream9-ova bootc-testboot-centos-stream9-anaconda-iso; do
  echo "--- $pkg ---"
  gh api /users/duyhenryer/packages/container/$pkg/versions --paginate | jq '.[].metadata.container.tags' 2>/dev/null || echo "(no versions or access denied)"
done

echo ""
echo "=== 3. Main app and base image tags ==="
echo "--- bootc-testboot ---"
gh api /users/duyhenryer/packages/container/bootc-testboot/versions --paginate | jq '.[].metadata.container.tags' 2>/dev/null || echo "(no versions or access denied)"
echo "--- bootc-testboot-base ---"
gh api /users/duyhenryer/packages/container/bootc-testboot-base/versions --paginate | jq '.[].metadata.container.tags' 2>/dev/null || echo "(no versions or access denied)"

echo ""
echo "=== 4. Pull and inspect AMI artifact ==="
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-ami:latest-amd64
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-ami:latest-amd64 /bin/true)
podman export $ctr | tar -t
podman rm $ctr

echo ""
echo "=== 5. Pull and inspect QCOW2 artifact ==="
podman pull ghcr.io/duyhenryer/bootc-testboot-centos-stream9-qcow2:latest-amd64
ctr=$(podman create ghcr.io/duyhenryer/bootc-testboot-centos-stream9-qcow2:latest-amd64 /bin/true)
podman export $ctr | tar -t
podman rm $ctr
