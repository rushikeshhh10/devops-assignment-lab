resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/../scripts/app-userdata.sh.tpl", {
    juice_shop_manifest = file("${path.module}/../k8s/juice-shop.yaml")
    wazuh_manager_ip    = aws_instance.wazuh.private_ip
  })

  tags = {
    Name = "${var.project_name}-app-vm"
  }
}

# Stable public IP - needed for the WAF endpoint and WireGuard client configs
# to survive instance stop/start without changing address.
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-app-eip"
  }
}
