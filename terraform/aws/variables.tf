variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
  default     = "trakrf-demo"
}

variable "cluster_version" {
  type        = string
  description = "Kubernetes version for the EKS cluster"
  default     = "1.31"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.142.0.0/16"
}

variable "environment" {
  type        = string
  description = "Environment name for tagging"
  default     = "demo"
}

variable "project" {
  type        = string
  description = "Project name for tagging"
  default     = "trakrf"
}
