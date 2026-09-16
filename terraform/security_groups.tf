# App VM: hosts K3s+Juice Shop behind Caddy/Coraza WAF, and the WireGuard VPN endpoint.
# This is the ONLY security group with any rule open to 0.0.0.0/0, and that rule is
# limited to the WireGuard UDP port, which is authenticated via public-key crypto.
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "App VM: WAF-fronted Juice Shop + WireGuard VPN endpoint"
  vpc_id      = aws_vpc.main.id

  # SSH restricted to the evaluator/admin IP only
  ingress {
    description = "SSH from admin/evaluator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  # WireGuard VPN - the only rule open to the internet, but auth is cryptographic
  # (a peer without the correct keypair cannot establish a tunnel at all)
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS to the WAF (Caddy+Coraza) fronting Juice Shop - restricted to the
  # evaluator/admin IP allowlist. VPN-connected clients reach it via the
  # tunnel's private routing, not this rule.
  ingress {
    description = "HTTPS to WAF (evaluator IP allowlist)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

# Wazuh VM: NOT internet-facing at all. Only reachable from the App VM's
# security group - which covers both direct App VM traffic (agent enrollment,
# verifier queries to the Indexer API) and NATed WireGuard VPN client traffic,
# since the App VM masquerades VPN peer traffic as its own private IP before
# it reaches this VM.
resource "aws_security_group" "wazuh" {
  name        = "${var.project_name}-wazuh-sg"
  description = "Wazuh VM: manager, indexer, dashboard - private only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH (bastion via App VM only)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "Wazuh agent enrollment + event collection"
    from_port       = 1514
    to_port         = 1515
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "Wazuh manager API"
    from_port       = 55000
    to_port         = 55000
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "Wazuh Indexer API (used by verifier)"
    from_port       = 9200
    to_port         = 9200
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "Wazuh Dashboard (accessed only via VPN through App VM)"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-wazuh-sg"
  }
}
