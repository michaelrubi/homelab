# Off-site copy of everything in /var/lib/longhorn-backups on thinkcentre02.
#
# Until this existed, every backup lived on the same disk as that node's
# Longhorn replicas, so one disk failure could lose both.
#
# THREAT MODEL
#
# Restic needs to delete objects to prune, so a stolen cluster key can always
# delete what it can see. Object Lock would stop that, but it also stops prune.
# Instead the bucket is versioned and the key cannot touch versions: a delete
# only adds a delete marker, and the data stays recoverable for
# noncurrent_retention_days. The key also cannot change versioning, lifecycle
# or the bucket policy, so it cannot shorten that window first.
#
# The IAM access key is created by hand, not here. An aws_iam_access_key
# resource would write the secret into Terraform state.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Bucket comes from -backend-config=bucket=<bootstrap output>.
  backend "s3" {
    key          = "offsite-backups/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "homelab"
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "rubiconetic-offsite-backups-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "backups" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # Versioning must exist first or the noncurrent rule is rejected.
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "expire-deleted-data"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_retention_days
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.bucket.json

  # S3 rejects a policy while public-access settings are still being applied.
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

resource "aws_iam_user" "restic" {
  name = "homelab-restic"
}

data "aws_iam_policy_document" "restic" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backups.arn]
  }

  # Deliberately no s3:DeleteObjectVersion. See the threat model above.
  statement {
    sid       = "ReadWriteObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
}

resource "aws_iam_user_policy" "restic" {
  name   = "restic-backup-access"
  user   = aws_iam_user.restic.name
  policy = data.aws_iam_policy_document.restic.json
}

resource "aws_budgets_budget" "monthly" {
  name         = "homelab-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
