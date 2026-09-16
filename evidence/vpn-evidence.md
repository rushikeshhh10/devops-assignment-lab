# VPN Evidence — Private Access to Wazuh

## WireGuard handshake (run on the App VM, the WireGuard server)

    root@app-vm:~# wg show
    interface: wg0
      public key: <REDACTED>
      private key: (hidden)
      listening port: 51820

    peer: <REDACTED>
      endpoint: <EVALUATOR_IP>:47209
      allowed ips: 10.13.13.2/32
      latest handshake: 59 seconds ago
      transfer: 1.50 KiB received, 1.50 KiB sent

Confirms a real WireGuard client successfully authenticated and established a tunnel.

## Private-only access to the Wazuh dashboard, over the VPN

    PS> curl.exe -kv https://<WAZUH_PRIVATE_IP>/
    *   Trying <WAZUH_PRIVATE_IP>:443...
    * Established connection to <WAZUH_PRIVATE_IP> ... from 10.13.13.2 port 53651
    > GET / HTTP/1.1
    > Host: <WAZUH_PRIVATE_IP>
    < HTTP/1.1 302 Found
    < location: /app/login?
    < osd-name: wazuh.dashboard

The connection's local source address (10.13.13.2) is the WireGuard tunnel IP, confirming
this request is routed through the VPN rather than directly. Wazuh's dashboard is not
reachable at all without the tunnel — its security group has no ingress rules open to
0.0.0.0/0; every rule references the App VM's security group by ID.

Following the redirect returns the actual dashboard login page:

    PS> curl.exe -kL https://<WAZUH_PRIVATE_IP>/app/login
    <!-- real Wazuh dashboard login page HTML -->
