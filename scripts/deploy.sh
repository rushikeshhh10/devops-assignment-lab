#!/bin/bash
# One-command deploy. Assumes terraform/terraform.tfvars already exists
# (copy terraform.tfvars.example and fill in real values first).
set -euo pipefail
cd "$(dirname "$0")/../terraform"
terraform init
terraform apply
