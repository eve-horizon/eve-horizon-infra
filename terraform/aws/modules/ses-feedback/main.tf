# SES Feedback Module
#
# Provisions a SESv2 configuration set + SNS topic + HTTPS subscription so
# the Eve API can correlate every outbound send with bounce/complaint/
# delivery/reject events. Suppression list management is enabled at the
# configuration set level so hard bounces and complaints are auto-added
# to the account-level suppression list — the API pre-flights this list
# before sending (see Lane 2.2 of the silent-drop plan) and reports
# `email_delivery_events` rows back to operators.
#
# SES is operated out of us-west-2 (the SMTP endpoint Eve's mailer points
# at), so all resources here use the `aws.us_west_2` provider alias from
# the root module. The SNS topic must live in the same region as the SES
# event destination, and the subscription endpoint is the Eve API webhook
# at https://api.<domain>/webhooks/ses-feedback.
#
# See docs/plans/magic-link-email-silent-drop-plan.md (Lane 3.1).

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.us_west_2]
    }
  }
}

data "aws_caller_identity" "current" {
  provider = aws.us_west_2
}

locals {
  topic_name = "${var.name_prefix}-ses-feedback"

  # SES publishes through its service principal; scope the topic policy to
  # this AWS account so cross-account SES senders can't push into our topic.
  event_types = compact(concat(
    ["BOUNCE", "COMPLAINT", "REJECT"],
    var.include_delivery_events ? ["DELIVERY"] : [],
    var.include_send_events ? ["SEND"] : [],
  ))
}

# -----------------------------------------------------------------------------
# Configuration set
# -----------------------------------------------------------------------------
# Suppression options keep the account-level suppression list authoritative
# for hard bounces and complaints, so the API can call
# `ses:GetSuppressedDestination` as a pre-flight check before sending.
resource "aws_sesv2_configuration_set" "eve_default" {
  provider               = aws.us_west_2
  configuration_set_name = var.configuration_set_name

  reputation_options {
    reputation_metrics_enabled = true
  }

  suppression_options {
    suppressed_reasons = ["BOUNCE", "COMPLAINT"]
  }

  sending_options {
    sending_enabled = true
  }

  tags = {
    Name = var.configuration_set_name
  }
}

# -----------------------------------------------------------------------------
# SNS topic for SES feedback
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "ses_feedback" {
  provider = aws.us_west_2
  name     = local.topic_name

  tags = {
    Name = local.topic_name
  }
}

# Topic policy: allow only the SES service principal in this account to
# publish. The webhook handler in the Eve API additionally checks the
# `TopicArn` of incoming SNS payloads against EVE_SES_FEEDBACK_TOPIC_ARN to
# reject spoofed messages from other topics.
data "aws_iam_policy_document" "ses_feedback" {
  provider = aws.us_west_2

  statement {
    sid    = "AllowSESPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.ses_feedback.arn]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "ses_feedback" {
  provider = aws.us_west_2
  arn      = aws_sns_topic.ses_feedback.arn
  policy   = data.aws_iam_policy_document.ses_feedback.json
}

# -----------------------------------------------------------------------------
# Event destination — config set → SNS topic
# -----------------------------------------------------------------------------
resource "aws_sesv2_configuration_set_event_destination" "sns_feedback" {
  provider               = aws.us_west_2
  configuration_set_name = aws_sesv2_configuration_set.eve_default.configuration_set_name
  event_destination_name = "sns-feedback"

  event_destination {
    enabled              = true
    matching_event_types = local.event_types

    sns_destination {
      topic_arn = aws_sns_topic.ses_feedback.arn
    }
  }
}

# -----------------------------------------------------------------------------
# HTTPS subscription → Eve API webhook
# -----------------------------------------------------------------------------
# AWS sends a SubscriptionConfirmation message immediately; the Eve API
# /webhooks/ses-feedback handler auto-confirms (see Lane 2.3). Until then
# the subscription stays in `PendingConfirmation`.
resource "aws_sns_topic_subscription" "eve_api" {
  provider               = aws.us_west_2
  topic_arn              = aws_sns_topic.ses_feedback.arn
  protocol               = "https"
  endpoint               = var.webhook_endpoint
  endpoint_auto_confirms = true
}
