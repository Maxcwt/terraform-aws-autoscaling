variable "aws_region" {
  type        = string
  description = "AWS Region"
  default = "us-east-1"
}

variable "vpc_name" {
  type        = string
  description = "VPC Name"
  default = "insset"
}

variable "ec2_ami_names" {
  type        = list(string)
  description = "List of EC2 AMI names to filter (NAME, not ID)"
  default     = ["CCM V3"]
}

variable "ec2_ami_owners" {
  type        = string
  description = "AMI owners"
  default     = "221922982054"
}

variable "ec2_security_groups" {
  type        = list(string)
  description = "List of EC2 Security Group NAMES to filter"
  default     = ["insset-sg-web" , "insset-sg-web-private"]
}

variable "app_name" {
  type = string
    description = "Application name"
    default = "myapp"
}
variable "key_name" {
  type        = string
  description = "SSH Key pair name for EC2 access"
  default     = "zertgyhj"
}