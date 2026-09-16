#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/wazuh-bootstrap.log) 2>&1

echo "=== [1/6] Locate and mount persistent EBS data volume ==="
DEVICE=""
for i in $(seq 1 30); do
  for d in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
    if [ -b "$d" ]; then DEVICE=$d; break 2; fi
  done
  echo "Waiting for data volume to attach... ($i/30)"
  sleep 5
done

if [ -z "$DEVICE" ]; then
  echo "ERROR: data volume never appeared" >&2
  exit 1
fi
echo "Using data volume: $DEVICE"

# Only format if the volume has no existing filesystem - this is what makes
# reruns/reboots preserve data instead of wiping it every boot.
if ! blkid "$DEVICE" > /dev/null 2>&1; then
  echo "No filesystem found - formatting (first boot only)"
  mkfs.ext4 -F "$DEVICE"
else
  echo "Existing filesystem detected - preserving data, skipping format"
fi

mkdir -p /data/wazuh
mount "$DEVICE" /data/wazuh
grep -q "$DEVICE" /etc/fstab || echo "$DEVICE /data/wazuh ext4 defaults,nofail 0 2" >> /etc/fstab

echo "=== [2/6] Install Docker ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "=== [3/6] Point Docker's storage at the persistent EBS volume ==="
# Must happen BEFORE the first docker start - this makes every named volume
# Wazuh's compose file creates live physically on /data/wazuh, so it survives
# instance stop/start and terraform re-applies as long as the EBS volume and
# its attachment aren't destroyed.
mkdir -p /data/wazuh/docker
cat <<'EOF' > /etc/docker/daemon.json
{
  "data-root": "/data/wazuh/docker"
}
EOF

systemctl enable docker
systemctl restart docker
docker info | grep "Docker Root Dir"

echo "=== [4/6] Fetch Wazuh single-node Docker stack ==="
if [ ! -d /opt/wazuh-docker ]; then
  git clone --depth 1 --branch v4.9.2 https://github.com/wazuh/wazuh-docker.git /opt/wazuh-docker
fi
cd /opt/wazuh-docker/single-node

echo "=== [5/6] Generate indexer TLS certs (self-signed, one-time) ==="
if [ ! -d ./config/wazuh_indexer_ssl_certs ] || [ -z "$(ls -A ./config/wazuh_indexer_ssl_certs 2>/dev/null)" ]; then
  docker compose -f generate-indexer-certs.yml run --rm generator
else
  echo "Certs already exist - skipping generation (preserves identity across reruns)"
fi

echo "=== [6/6] Start Wazuh stack (manager + indexer + dashboard) ==="
docker compose up -d

echo "Waiting for Wazuh Indexer API to become ready..."
for i in $(seq 1 60); do
  if curl -sk -u admin:SecretPassword https://localhost:9200 -o /dev/null; then
    echo "Wazuh Indexer is up."
    break
  fi
  echo "Waiting for indexer... ($i/60)"
  sleep 10
done

echo "Waiting for Wazuh Manager API to become ready..."
for i in $(seq 1 60); do
  if curl -sk -u wazuh-wui:MyS3cr37P450r.*- https://localhost:55000/ -o /dev/null; then
    echo "Wazuh Manager API is up."
    break
  fi
  echo "Waiting for manager API... ($i/60)"
  sleep 10
done

echo "=== Wazuh VM bootstrap complete ==="
echo "NOTE: This uses wazuh-docker's default demo credentials (admin/SecretPassword" > /root/wazuh-credentials-NOTE.txt
echo "for the indexer, wazuh-wui/MyS3cr37P450r.*- for the manager API by default)." >> /root/wazuh-credentials-NOTE.txt
echo "Rotate these before any real/production use - documented tradeoff for this lab." >> /root/wazuh-credentials-NOTE.txt
touch /var/log/wazuh-bootstrap.done
