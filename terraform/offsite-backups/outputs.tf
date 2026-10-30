output "bucket" {
  description = "Backup bucket name."
  value       = aws_s3_bucket.backups.bucket
}

output "restic_repository" {
  description = "Value for RESTIC_REPOSITORY in offsite-backup-secrets."
  value       = "s3:s3.${var.region}.amazonaws.com/${aws_s3_bucket.backups.bucket}/restic"
}

output "restic_iam_user" {
  description = "IAM user that needs an access key created by hand."
  value       = aws_iam_user.restic.name
}
