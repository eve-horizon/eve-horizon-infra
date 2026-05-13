# Shared app-facing S3 credentials for the staging object bucket stopgap.
# The worker still provisions buckets through IRSA; these keys are injected
# into app pods and are intentionally scoped away from platform/org buckets.

resource "aws_iam_user" "app_buckets" {
  count = local.effective_compute_model == "eks" ? 1 : 0
  name  = "${var.name_prefix}-app-buckets"

  tags = {
    Name = "${var.name_prefix}-app-buckets"
  }
}

resource "aws_iam_user_policy" "app_buckets" {
  count = local.effective_compute_model == "eks" ? 1 : 0
  name  = "${var.name_prefix}-app-buckets"
  user  = aws_iam_user.app_buckets[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListAppBuckets"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = [
          "arn:aws:s3:::${local.storage_app_bucket_prefix}-*",
        ]
      },
      {
        Sid    = "ReadWriteAppObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "arn:aws:s3:::${local.storage_app_bucket_prefix}-*/*",
        ]
      },
    ]
  })
}

resource "aws_iam_access_key" "app_buckets" {
  count = local.effective_compute_model == "eks" ? 1 : 0
  user  = aws_iam_user.app_buckets[0].name
}

resource "kubernetes_secret_v1" "eve_app_storage" {
  count = local.effective_compute_model == "eks" ? 1 : 0

  metadata {
    name      = "eve-app-storage"
    namespace = "eve"
  }

  data = {
    EVE_APP_STORAGE_ACCESS_KEY_ID     = aws_iam_access_key.app_buckets[0].id
    EVE_APP_STORAGE_SECRET_ACCESS_KEY = aws_iam_access_key.app_buckets[0].secret
  }

  type = "Opaque"
}
