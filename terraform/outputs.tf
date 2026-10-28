# terraform/outputs.tf
output "alb_https_endpoint" {
  value = "https://${aws_lb.public_alb.dns_name}"
}

output "app_instance_id" {
  value = aws_instance.app_server.id
}

output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.id
}

output "rds_endpoint" {
  value = aws_db_instance.postgres.endpoint
}

output "kms_key_arn" {
  value = aws_kms_key.altpay_cmk.arn
}

output "db_secret_arn" {
  value = aws_secretsmanager_secret.db_credentials.arn
}