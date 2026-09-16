# DevOps Practical Assignment — Terraform Lab

Terraform-based automation that stands up a complete lab — OWASP Juice Shop on K3s behind a
Caddy/Coraza WAF, a Wazuh SIEM with persistent storage, a WireGuard VPN, and a gated CI/CD
pipeline — with one documented command, no manual server/console/Wazuh setup.

## Architecture

```
                        Internet
                            |
                (Evaluator IP allowlist)
                            |
                    +---------------+
                    |   App VM       |
                    | - K3s          |
                    | - Juice Shop   |
                    | - Caddy+Coraza |  <- public :443 (allowlisted only)
                    |   WAF          |
                    | - WireGuard    |  <- public :51820 (crypto-authenticated)
                    | - Wazuh agent  |
                    +-------+-------+
                            | private VPC only (SG references, not CIDR)
                    +-------+-------+
                    |  Wazuh VM      |
                    | - manager      |
                    | - indexer      |
                    | - dashboard    |  <- reachable ONLY via VPN through App VM
                    | - EBS data vol |  <- persists across terraform apply reruns
                    +---------------+
```

- **Juice Shop** runs as a K3s Deployment/ClusterIP service — never exposed directly. The
  only path in is through Caddy.
- **Caddy + Coraza WAF** reverse-proxies to Juice Shop, terminates TLS (self-signed, `tls
  internal` with on-demand issuance — see "TLS handling" below), and blocks a deterministic
  set of SQLi/XSS patterns.
- **WireGuard** runs on the App VM. VPN client traffic is NATed (MASQUERADE) through the App
  VM's own network interface before reaching the Wazuh VM, so it satisfies the same
  security-group rule as ordinary app traffic — no separate ingress rule needed for VPN
  clients.
- **Wazuh** (manager + indexer + dashboard, official single-node Docker stack) has **zero**
  security-group rules open to the internet. Every ingress rule references the App VM's
  security group by ID, not a CIDR block.
- **Log pipeline**: Caddy's JSON access log -> Wazuh agent on the App VM -> Wazuh manager
  (custom rule `100010`, see `wazuh/caddy_rules.xml`) -> Wazuh Indexer, all confirmed
  end-to-end by the verifier.

## Prerequisites

- An AWS account with an IAM user that has programmatic access (this lab used
  `AdministratorAccess` for speed — see "Known tradeoffs" below for why, and what a
  production setup would do instead)
- AWS CLI configured with a named profile
- Terraform >= 1.6 (developed against 1.14.7)
- An SSH keypair (`ssh-keygen -t ed25519`)
- An S3 bucket + DynamoDB table for Terraform state (bootstrap once, manually, before
  `terraform init` — see below)
- Your public IP (`curl ifconfig.me`), used to allowlist SSH/HTTPS access

## One-time backend bootstrap (before first `terraform init`)

```bash
aws s3api create-bucket --bucket <your-unique-name>-tfstate --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
aws s3api put-bucket-versioning --bucket <your-unique-name>-tfstate \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket <your-unique-name>-tfstate \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws dynamodb create-table --table-name tfstate-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region ap-south-1
```
Update the bucket name in `terraform/backend.tf` to match.

## Deploy — the one command

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: allowed_ip, public_key_path, ssh_private_key_path
terraform init
terraform apply
```

`terraform apply` is the single documented command. It provisions all networking, IAM,
compute, and — critically — **does not report success until the deployment verifier passes**.
A `null_resource` SSHs into the App VM after boot, waits for both VMs' bootstrap to finish,
and runs `scripts/verify.py`, which:
1. Confirms the WAF-fronted Juice Shop and the Wazuh Indexer are both ready
2. Sends one HTTP request through the WAF carrying a fresh UUID marker
3. Polls the Wazuh Indexer until that exact marker appears in an indexed alert

If any of that fails, `verify.py` exits nonzero and the `terraform apply` itself fails —
readiness and log delivery are hard requirements of a successful deploy, not a separate
manual check.

**Reruns preserve data**: Wazuh's indexer/manager/dashboard data lives on a dedicated EBS
volume (`aws_ebs_volume.wazuh_data`), separate from the instance's root disk, with Docker's
own storage root pointed at it. As long as that volume isn't destroyed, repeated
`terraform apply` runs do not wipe Wazuh's history.

## Verify (standalone, without a full apply)

```bash
scp scripts/verify.py app-vm:/tmp/verify.py
ssh app-vm
sudo python3 /tmp/verify.py \
  --app-url https://localhost/ \
  --indexer-url https://<wazuh_private_ip>:9200 \
  --indexer-user admin --indexer-pass SecretPassword \
  --readiness-timeout 60 --delivery-timeout 60
```
Exit codes: `0` success, `1` readiness failure, `2` log-delivery failure.

## VPN access (private, evaluator-only)

```bash
scp app-vm:/home/ubuntu/client.conf ./wg-client.conf
```
Import `wg-client.conf` into the WireGuard app (https://www.wireguard.com/install/),
Activate. Once connected, `https://<wazuh_private_ip>/` becomes reachable — it is not
reachable at all without the VPN.

## WAF demonstration

Allowed request:
```bash
curl -k https://<app_public_ip>/
# -> HTTP 200, Juice Shop HTML
```
Deterministic blocked request:
```bash
curl -k "https://<app_public_ip>/?id=1%27%20OR%201%3D1%20--%20"
# -> HTTP 403, empty body, blocked by rule id:1000 (SecRule in scripts/app-userdata.sh.tpl)
```
Direct-origin bypass is prevented by design: Juice Shop's K8s Service is `ClusterIP` (never
`NodePort`/`LoadBalancer`), so there is no path to it that skips Caddy.

## Cloud security

- **Firewalls**: App VM's security group allows SSH/HTTPS only from an evaluator IP
  allowlist, plus WireGuard's UDP port (the only rule open to `0.0.0.0/0`, but
  cryptographically authenticated). Wazuh VM's security group has **no** CIDR-based ingress
  rules at all — every rule references the App security group by ID.
- **Identities**: both EC2 instances use a minimal IAM role (`AmazonSSMManagedInstanceCore`
  only — no S3/EC2/broad permissions).
- **Secrets**: nothing committed. `terraform.tfvars`, `.terraform/`, `*.tfstate`, and all key
  files are gitignored. CI uses GitHub Actions repository secrets
  (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `SSH_PRIVATE_KEY`, `SSH_PUBLIC_KEY`,
  `ALLOWED_IP`).
- **State**: S3 backend, versioned, AES256-encrypted, with a DynamoDB lock table.
- **TLS handling**: Caddy uses its internal CA (`tls internal { on_demand }`) to issue
  self-signed certificates on demand, since this is a private lab with no public domain.
  Browsers/curl will show a certificate warning (`-k`/`--insecure` needed) — this is expected
  and documented, not a bug. Wazuh's dashboard/indexer use their own self-signed certs
  generated by Wazuh's official cert-generation tooling at first boot.
- **IMDSv2** is enforced on both instances (`metadata_options { http_tokens = "required" }`).
- **Documented, consciously-accepted findings** (not silently suppressed): see
  `.trivyignore` (unrestricted egress + public-subnet auto-assign, both consequences of
  skipping a NAT Gateway to keep cost near zero) and `.gitleaksignore` (Wazuh's own published
  default demo credentials, flagged for rotation before any real use).

## CI/CD

`.github/workflows/ci.yml` runs on every push/PR: `terraform fmt`/`validate`, a Trivy IaC +
filesystem scan, a Gitleaks secret scan, and verifier unit tests (`scripts/test_verify.py`).
A `deploy` job only runs on a manual `workflow_dispatch` with an explicit `confirm_deploy:
deploy` input, and only if all four checks passed — see the repo's Actions tab for run
history. Add a required-reviewers rule on a `production` GitHub Environment for an
additional manual approval gate on top of this.

## Teardown

```bash
cd terraform
terraform destroy
```
This removes everything, including the Wazuh data volume — intentional, since the
assignment asks that assessment resources be torn down after testing. Data persistence
applies across repeated `apply` runs, not across an explicit `destroy`.

## Estimated cost

t3.medium (App) + t3.large (Wazuh) on-demand in `ap-south-1`, ~$0.125/hr combined, plus a
few cents/hr for EBS volumes and a negligible Elastic IP charge while attached. A full
build-test-teardown session (a few hours) costs well under $1.

## Actual effort

Built in a single extended session (~a few hours of active work), most of it spent on live
debugging real issues rather than initial authoring — see below for the honest list of what
actually went wrong along the way and how each was fixed, since that's arguably more useful
than pretending it worked on the first try.

## AI use

Built with heavy use of Claude (Anthropic) throughout: architecture design, all Terraform
and shell/Python code, and live interactive debugging of real deployment failures (dead
install script URLs, a K3s/Traefik port conflict, Caddy/Coraza directive parsing, Docker
storage-root misconfiguration, TLS on-demand issuance, Wazuh agent version mismatches, CI
tooling version/licensing issues, and false-positive security scan findings). Every fix was
verified against real command output before moving on, not accepted blindly.

## Known tradeoffs / incomplete items

- `terraform-deployer` IAM user uses `AdministratorAccess` for speed in this throwaway lab
  account — a production setup would scope this to exactly the services/actions Terraform
  needs.
- No NAT Gateway — both VMs have public IPs for outbound-only access (see `.trivyignore`).
- Wazuh VM is `t3.large` (2 vCPU/8GB), under Wazuh's stated recommendation of 4 vCPU, to
  keep cost down for a short-lived evaluation; the indexer's JVM heap was left at defaults
  and this was sufficient for the verifier's load.
- Wazuh's demo default credentials (`admin`/`SecretPassword`, `wazuh-wui`/its default
  password) are used as-is — documented for rotation before any real/production use.
- Juice Shop's own intentional vulnerabilities were not scanned in CI, per the assignment's
  explicit allowance ("Juice Shop vulnerability scanning is optional").
- The CI `deploy` job's manual-approval gate (GitHub Environment required reviewers) is
  recommended but not itself provisioned by Terraform — it's a one-time repo Settings step.
- WireGuard client key generation happens on first VM boot (inside `scripts/app-userdata.sh.tpl`)
  rather than being Terraform-managed, to avoid storing VPN private keys in Terraform state.

## Evidence

See `evidence/` for redacted command output confirming: an allowed vs. blocked WAF request,
a successful WireGuard VPN handshake with private dashboard access, and a fresh event
traveling end-to-end into the Wazuh Indexer via the verifier script.
