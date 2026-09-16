output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "wazuh_security_group_id" {
  value = aws_security_group.wazuh.id
}

output "app_public_ip" {
  description = "Public IP of the App VM (Juice Shop via WAF, WireGuard endpoint)"
  value       = aws_eip.app.public_ip
}

output "app_private_ip" {
  value = aws_instance.app.private_ip
}

output "wazuh_public_ip" {
  description = "Public IP of the Wazuh VM - has one for outbound internet only; SG blocks all inbound from 0.0.0.0/0"
  value       = aws_instance.wazuh.public_ip
}

output "wazuh_private_ip" {
  value = aws_instance.wazuh.private_ip
}
