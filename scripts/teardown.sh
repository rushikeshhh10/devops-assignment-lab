#!/bin/bash
# Tears down every resource this lab created, including the Wazuh data
# volume. Data persistence applies across repeated `apply` runs, not
# across an explicit destroy - this is intentional for a short-lived
# evaluation lab.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
terraform destroy
