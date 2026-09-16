variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile to use"
  type        = string
  default     = "devops-assignment"
}

variable "project_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "devops-assignment"
}

variable "allowed_ip" {
  description = "Evaluator/admin public IP allowed to reach SSH and the WAF-fronted app directly (CIDR form, e.g. 1.2.3.4/32). Update this if the evaluator's IP differs from yours."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the single public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_key_path" {
  description = "Path to the local SSH public key file to install on both VMs"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the local SSH private key (matching public_key_path) used by Terraform to run the post-deploy verifier over SSH"
  type        = string
}

variable "app_instance_type" {
  description = "Instance type for the App VM (K3s + Juice Shop + WAF + WireGuard)"
  type        = string
  default     = "t3.medium"
}

variable "wazuh_instance_type" {
  description = "Instance type for the Wazuh VM (manager + indexer + dashboard)"
  type        = string
  default     = "t3.large"
}

variable "wazuh_data_volume_size_gb" {
  description = "Size in GB of the persistent EBS volume for Wazuh data"
  type        = number
  default     = 50
}

variable "wireguard_vpn_cidr" {
  description = "Private CIDR handed out to WireGuard VPN clients"
  type        = string
  default     = "10.13.13.0/24"
}
