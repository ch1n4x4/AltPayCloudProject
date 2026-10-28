# terraform/kms_secrets.tf
resource "aws_kms_key" "altpay_cmk" {
  description             = "AltPay CMK for S3 SSE-KMS, RDS Storage Encryption, and Secrets Manager"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMUserPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudTrailAndLogsToEncrypt"
        Effect    = "Allow"
        Principal = {
          Service = [
            "cloudtrail.amazonaws.com",
            "logs.${var.aws_region}.amazonaws.com"
          ]
        }
        Action = [
          "kms:Encrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = { Name = "${var.project_name}-cmk" }
}

resource "aws_kms_alias" "altpay_cmk_alias" {
  name          = "alias/${var.project_name}-cmk"
  target_key_id = aws_kms_key.altpay_cmk.key_id
}

resource "random_password" "db_password" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.project_name}/prod/rds-credentials-v1"
  description             = "AltPay RDS PostgreSQL Master Credentials"
  kms_key_id              = aws_kms_key.altpay_cmk.arn
  recovery_window_in_days = 0 # Allows immediate cleanup upon terraform destroy
}

resource "aws_secretsmanager_secret_version" "db_credentials_val" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "altpay_admin"
    password = random_password.db_password.result
    dbname   = "altpaydb"
    port     = 5432
  })
}
