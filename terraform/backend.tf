terraform {
  backend "s3" {
    bucket         = "rushi-devops-assignment-tfstate-1789590547"
    key            = "devops-assignment/terraform.tfstate"
    region         = "ap-south-1"
    profile        = "devops-assignment"
    dynamodb_table = "tfstate-locks"
    encrypt        = true
  }
}
