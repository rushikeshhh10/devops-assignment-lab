# Imports your locally-generated public key. The private key never touches
# Terraform or AWS - only the public key is uploaded.
resource "aws_key_pair" "lab" {
  key_name   = "${var.project_name}-key"
  public_key = file(var.public_key_path)
}
