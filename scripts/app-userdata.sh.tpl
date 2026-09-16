#!/bin/bash
set -euxo pipefail
exec > >(tee /var/log/app-bootstrap.log) 2>&1

echo "=== [1/6] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git jq build-essential

echo "Installing Go 1.22 toolchain (apt's golang-go is too old to build xcaddy plugins)..."
GO_VERSION="1.22.5"
curl -sSL "https://go.dev/dl/go$${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
echo 'export PATH=$PATH:/usr/local/go/bin:/root/go/bin' >> /root/.bashrc
go version

echo "=== [2/6] Install K3s (single-node) ==="
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "Waiting for K3s node Ready..."
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 5
done

echo "=== [3/6] Deploy Juice Shop ==="
cat <<'EOF' > /root/juice-shop.yaml
${juice_shop_manifest}
EOF
kubectl apply -f /root/juice-shop.yaml

echo "Waiting for Juice Shop pod Ready..."
kubectl -n juice-shop wait --for=condition=Ready pod -l app=juice-shop --timeout=180s

JUICE_CLUSTER_IP=$(kubectl -n juice-shop get svc juice-shop -o jsonpath='{.spec.clusterIP}')
echo "Juice Shop ClusterIP: $JUICE_CLUSTER_IP"

echo "=== [4/6] Build Caddy with Coraza WAF plugin ==="
export PATH=$PATH:/usr/local/go/bin:/root/go/bin
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
xcaddy build --with github.com/corazawaf/coraza-caddy/v2 --output /usr/local/bin/caddy
/usr/local/bin/caddy version

echo "=== [5/6] Write Caddyfile with WAF rules ==="
mkdir -p /etc/caddy
cat <<CADDYFILE > /etc/caddy/Caddyfile
{
	auto_https disable_redirects
	admin off
	order coraza_waf first
}

:443 {
	tls internal {
		on_demand
	}

	coraza_waf {
		directives \`
			SecRuleEngine On
			SecRequestBodyAccess On
			SecRule ARGS "@rx (?i:union(\s|\+)+select|or\s+1\s*=\s*1|or\s+'1'\s*=\s*'1|--\s|;--|<script|onerror\s*=)" "id:1000,phase:2,deny,status:403,log,msg:'Blocked: SQLi/XSS pattern in request'"
		\`
	}

	reverse_proxy $JUICE_CLUSTER_IP:3000

	log {
		output file /var/log/caddy/access.log
		format json
	}
}
CADDYFILE

mkdir -p /var/log/caddy

echo "=== [6/6] systemd service for Caddy ==="
cat <<'UNIT' > /etc/systemd/system/caddy.service
[Unit]
Description=Caddy WAF (Coraza) fronting Juice Shop
After=network.target k3s.service

[Service]
Environment=HOME=/root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

echo "=== [7/9] Install and configure WireGuard VPN server ==="
apt-get install -y wireguard

cat <<'EOF' > /etc/sysctl.d/99-wireguard-forward.conf
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-wireguard-forward.conf

mkdir -p /etc/wireguard
cd /etc/wireguard
umask 077
wg genkey | tee server_private.key | wg pubkey > server_public.key
wg genkey | tee client_private.key | wg pubkey > client_public.key

SERVER_PRIV=$(cat server_private.key)
SERVER_PUB=$(cat server_public.key)
CLIENT_PRIV=$(cat client_private.key)
CLIENT_PUB=$(cat client_public.key)
PRIMARY_IFACE=$(ip -4 route list default | awk '{print $5}' | head -1)

cat <<EOF > /etc/wireguard/wg0.conf
[Interface]
Address = 10.13.13.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $PRIMARY_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $PRIMARY_IFACE -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.13.13.2/32
EOF
chmod 600 /etc/wireguard/wg0.conf

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

APP_PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
cat <<EOF > /home/ubuntu/client.conf
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.13.13.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $APP_PUBLIC_IP:51820
AllowedIPs = 10.0.0.0/16, 10.13.13.0/24
PersistentKeepalive = 25
EOF
chown ubuntu:ubuntu /home/ubuntu/client.conf

echo "=== [8/9] Install and enroll Wazuh agent ==="
curl -so /tmp/wazuh-repo.gpg https://packages.wazuh.com/key/GPG-KEY-WAZUH
gpg --no-default-keyring --keyring /usr/share/keyrings/wazuh.gpg --import /tmp/wazuh-repo.gpg
chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
apt-get update -y
WAZUH_MANAGER="${wazuh_manager_ip}" WAZUH_AGENT_NAME="app-vm" apt-get install -y wazuh-agent

echo "=== [9/9] Add Caddy access log as a monitored source ==="
python3 - <<'PYEOF'
path = "/var/ossec/etc/ossec.conf"
with open(path) as f:
    content = f.read()
block = """  <localfile>
    <log_format>json</log_format>
    <location>/var/log/caddy/access.log</location>
  </localfile>
"""
if "/var/log/caddy/access.log" not in content:
    content = content.replace("</ossec_config>", block + "</ossec_config>")
    with open(path, "w") as f:
        f.write(content)
PYEOF

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent

echo "=== App VM bootstrap complete ==="
touch /var/log/app-bootstrap.done
