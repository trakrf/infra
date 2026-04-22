variable "subscription_id" {
  type        = string
  description = "Azure subscription ID — injected via TF_VAR_subscription_id in .env.local"
}

variable "region" {
  type        = string
  description = "Azure region for all resources"
  default     = "southcentralus"
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

variable "location" {
  type        = string
  description = "Region short code (e.g. ussc for southcentralus) used in resource names"
  default     = "ussc"
}

variable "cluster_name" {
  type        = string
  description = "Name of the AKS cluster (applied in phase 2)"
  default     = "trakrf-demo"
}

variable "vnet_cidr" {
  type        = string
  description = "CIDR block for the VNet"
  default     = "10.143.0.0/16"
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the AKS cluster"
  default     = "1.35"
}

variable "primary_pool_zone" {
  type        = string
  description = "Availability zone for the primary node pool (single-AZ pin for CNPG PV stability). Zone 3 required: this subscription blocks D-ps_v5 ARM SKUs in zones 1 and 2."
  default     = "3"
}

variable "acr_name" {
  type        = string
  description = "ACR name (globally unique, alphanumeric 5-50 chars)"
  default     = "trakrf"
}
