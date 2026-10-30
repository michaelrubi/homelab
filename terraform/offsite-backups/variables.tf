variable "region" {
  description = "AWS region for the backup bucket. Must match the backend region."
  type        = string
  default     = "us-west-2"
}

variable "noncurrent_retention_days" {
  description = "Days that deleted or overwritten backup objects stay recoverable."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_retention_days >= 7
    error_message = "Keep at least 7 days, or a compromise can outlast the recovery window."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly AWS spend that triggers a budget alert."
  type        = number
  default     = 10
}

variable "budget_alert_email" {
  description = "Address that receives budget alerts."
  type        = string
}
