# SES Feedback Module — Outputs

output "configuration_set_name" {
  description = "Name of the SESv2 configuration set. Passed to the Eve API as EVE_SES_CONFIGURATION_SET and attached to outbound SMTP sends via the X-SES-CONFIGURATION-SET header."
  value       = aws_sesv2_configuration_set.eve_default.configuration_set_name
}

output "topic_arn" {
  description = "ARN of the SNS topic receiving SES feedback events. Passed to the Eve API as EVE_SES_FEEDBACK_TOPIC_ARN so the webhook handler can reject SNS messages from unexpected topics."
  value       = aws_sns_topic.ses_feedback.arn
}

output "topic_name" {
  description = "Plain name of the SNS topic (region/account independent)."
  value       = aws_sns_topic.ses_feedback.name
}

output "subscription_arn" {
  description = "ARN of the HTTPS subscription. Stays in PendingConfirmation until the Eve API webhook handler confirms."
  value       = aws_sns_topic_subscription.eve_api.arn
}
