# terraform/variables.tf
variable "aws_region" {
  description = "Primary region aligned with EU GDPR data residency"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  type    = string
  default = "altpay"
}

variable "domain_name" {
  description = "Custom domain for ACM DNS validation (leave empty to import self-signed TLS cert into ACM for testing)"
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "Attach AWS WAFv2 to the ALB"
  type        = bool
  default     = true
}

variable "enable_guardduty" {
  description = "Enable Amazon GuardDuty (30-day Free Trial)"
  type        = bool
  default     = false
}
