# -----------------------------------------------------------------------------
# SES Feedback (Lane 3.1, magic-link silent-drop plan)
# -----------------------------------------------------------------------------
# Provisions the SESv2 configuration set, SNS feedback topic, event
# destination, HTTPS subscription, and the API-side IAM grant needed to
# pre-flight the account-level suppression list before each send.
#
# All SES resources live in us-west-2 (where Eve's SMTP endpoint is) via the
# `aws.us_west_2` provider alias. The cluster (and the rest of this root
# module) runs in eu-west-1.
#
# See docs/plans/magic-link-email-silent-drop-plan.md (Lane 3.1).

module "ses_feedback" {
  source = "./modules/ses-feedback"

  providers = {
    aws.us_west_2 = aws.us_west_2
  }

  name_prefix            = var.name_prefix
  configuration_set_name = var.ses_configuration_set_name
  webhook_endpoint       = var.ses_feedback_endpoint
}

# -----------------------------------------------------------------------------
# API IRSA — read-only access to the SES suppression list
# -----------------------------------------------------------------------------
# `ses:GetSuppressedDestination` is the only call the mailer pre-flight
# needs. We intentionally do NOT grant `ses:DeleteSuppressedDestination` —
# `eve admin email bounces list` reads Eve's own email_delivery_events
# table; clearing SES suppression entries is a separate, audited admin
# action.
resource "aws_iam_role_policy" "api_ses_suppression_read" {
  count = local.effective_compute_model == "eks" ? 1 : 0
  name  = "${var.name_prefix}-api-ses-suppression-read"
  role  = aws_iam_role.api_irsa[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSuppressionList"
        Effect = "Allow"
        Action = ["ses:GetSuppressedDestination"]
        # The SESv2 API doesn't support resource-level restriction on
        # GetSuppressedDestination — `*` here means "in any region". The
        # condition pins the call to us-west-2 (Eve's SES region).
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = "us-west-2"
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SMTP user — permission to use the SES configuration set
# -----------------------------------------------------------------------------
# The SMTP IAM user (`eve-eh1-ses-smtp`) was created out-of-band when SES was
# first set up; its existing inline policy only allows SendEmail/SendRawEmail
# on the `incept5.com` identity. Now that mailer sends pass
# `X-SES-CONFIGURATION-SET: eve-default` so events route to the SNS feedback
# topic, the user also needs `ses:SendRawEmail` permission on the
# configuration-set resource. Without this, SES returns 554 Access denied.
resource "aws_iam_user_policy" "ses_smtp_configuration_set" {
  count = var.ses_smtp_user_name != "" ? 1 : 0
  name  = "${var.name_prefix}-ses-smtp-configuration-set"
  user  = var.ses_smtp_user_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UseEveDefaultConfigurationSet"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = module.ses_feedback.configuration_set_arn
      }
    ]
  })
}
