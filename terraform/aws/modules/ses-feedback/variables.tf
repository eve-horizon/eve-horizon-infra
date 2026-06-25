# SES Feedback Module — Input Variables
#
# Provisions a SESv2 configuration set with bounce/complaint suppression
# and reputation tracking, plus an SNS topic + HTTPS subscription that
# routes SES events to the Eve API webhook. Lets the API correlate per-send
# delivery state with its own `email_delivery_events` table and pre-empt
# silent-drop bugs caused by account-level recipient suppression.
#
# See docs/plans/magic-link-email-silent-drop-plan.md, Lane 3.1.

variable "name_prefix" {
  description = "Prefix for AWS resource names (matches root name_prefix, e.g. eve)."
  type        = string
}

variable "configuration_set_name" {
  description = "Name of the SESv2 configuration set. Eve API attaches this via the X-SES-CONFIGURATION-SET header on outbound sends."
  type        = string
  default     = "eve-default"
}

variable "webhook_endpoint" {
  description = "HTTPS URL the SNS topic subscribes to. The Eve API SES feedback handler confirms the subscription and persists events into email_delivery_events."
  type        = string
}

variable "include_delivery_events" {
  description = "Whether to include DELIVERY events in the event destination. Useful for correlating successful sends; can be noisy at scale."
  type        = bool
  default     = true
}

variable "include_send_events" {
  description = "Whether to include SEND events. Off by default — most pipelines only need failure/bounce/complaint signal."
  type        = bool
  default     = false
}
