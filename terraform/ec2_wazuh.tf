# Persistent data volume - deliberately a SEPARATE resource from the instance's
# root disk. As long as this volume (and its attachment) aren't destroyed,
# Wazuh's indexer/manager/dashboard data survives instance stop/start and
# repeated `terraform apply` runs, satisfying the "reruns must preserve data"
# requirement.
resource "aws_ebs_volume" "wazuh_data" {
  availability_zone = aws_subnet.public.availability_zone
  size              = var.wazuh_data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.project_name}-wazuh-data"
  }
}

resource "aws_instance" "wazuh" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.wazuh_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.wazuh.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  key_name               = aws_key_pair.lab.key_name

  # Deliberately NOT associating a public IP is not possible without a NAT
  # Gateway (which costs money) for outbound package/image pulls, so it does
  # get a public IP - but the security group has ZERO ingress rules open to
  # 0.0.0.0/0, so nothing can reach in from the internet regardless. Only the
  # App VM's security group (and, transitively, NATed VPN clients) can reach
  # this instance at all.
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = file("${path.module}/../scripts/wazuh-userdata.sh.tpl")

  tags = {
    Name = "${var.project_name}-wazuh-vm"
  }
}

resource "aws_volume_attachment" "wazuh_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.wazuh_data.id
  instance_id = aws_instance.wazuh.id
}
