variable "region" {
  description = "AWS region. Must match the backup bucket so restore traffic stays free."
  type        = string
  default     = "us-west-2"
}

variable "kubernetes_version" {
  description = "EKS version. Must be on standard support, or the cluster bills six times as much."
  type        = string
  default     = "1.34"
}

variable "home_ip_cidr" {
  description = "The only address range allowed to reach the Kubernetes API, as x.x.x.x/32."
  type        = string

  validation {
    condition     = can(cidrhost(var.home_ip_cidr, 0)) && endswith(var.home_ip_cidr, "/32")
    error_message = "Use a single address in /32 form, not a wider range."
  }
}

variable "instance_type" {
  description = "Node instance type. Two of these must fit the account's 5 vCPU on-demand limit."
  type        = string
  default     = "t3.large"
}

variable "node_count" {
  description = "Number of nodes."
  type        = number
  default     = 2
}

variable "node_disk_gb" {
  description = "Root disk size on each node. Holds the restored backups and Longhorn replicas."
  type        = number
  default     = 100
}
