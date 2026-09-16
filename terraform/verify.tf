# Deployment gate: runs the verifier over SSH after the lab is up, and fails
# the `terraform apply` itself if either readiness or log delivery fails.
# This is what makes "deployment succeeds only after readiness and log
# delivery pass" literally true of running `terraform apply` - not just a
# separate manual step.
resource "null_resource" "verify_deployment" {
  depends_on = [
    aws_instance.app,
    aws_instance.wazuh,
    aws_volume_attachment.wazuh_data,
  ]

  # Re-run the verifier on every apply, not just the first one - reruns must
  # still prove the pipeline works, matching the assignment's requirement.
  triggers = {
    always_run = timestamp()
  }

  connection {
    type        = "ssh"
    host        = aws_eip.app.public_ip
    user        = "ubuntu"
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/../scripts/verify.py"
    destination = "/tmp/verify.py"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for App VM bootstrap to finish...'",
      "timeout 600 bash -c 'until [ -f /var/log/app-bootstrap.done ]; do sleep 5; done'",
      "echo 'Bootstrap confirmed complete. Running verifier...'",
      "python3 /tmp/verify.py --app-url https://localhost/ --indexer-url https://${aws_instance.wazuh.private_ip}:9200 --indexer-user admin --indexer-pass SecretPassword --readiness-timeout 120 --delivery-timeout 120",
    ]
  }
}
