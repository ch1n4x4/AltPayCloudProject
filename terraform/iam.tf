# terraform/iam.tf
resource "aws_iam_role" "app_ec2_role" {
  name = "${var.project_name}-ec2-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 1. Least-Privilege S3 Prefix + Secrets Manager + KMS Policy
resource "aws_iam_policy" "app_s3_secrets_policy" {
  name        = "${var.project_name}-app-s3-access"
  description = "Allows s3:GetObject and s3:PutObject strictly on uploads/* prefix and reads DB secret"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "LeastPrivilegeS3UploadsPrefixOnly"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/uploads/*"
      },
      {
        Sid      = "ReadDatabaseCredentialsSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.db_credentials.arn
      },
      {
        Sid      = "AllowKMSCryptoForS3AndSecrets"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.altpay_cmk.arn
      }
    ]
  })
}

# 2. Least-Privilege CloudWatch Monitoring Policy
resource "aws_iam_policy" "monitoring_policy" {
  name        = "${var.project_name}-monitoring-policy"
  description = "Read/Write ingestion permissions for CloudWatch Logs and Metrics"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CloudWatchLogIngestionOnly"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.app_logs.arn}:*"
      },
      {
        Sid      = "CloudWatchPutCustomMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "AltPay/App" }
        }
      }
    ]
  })
}

# 3. Admin MFA Policy (created in IAM for evidence & attachment to console group)
resource "aws_iam_policy" "admin_mfa_policy" {
  name        = "${var.project_name}-enforce-admin-mfa"
  description = "Enforces MFA for privileged console users"
  policy      = file("${path.module}/../iam-policies/admin-mfa-policy.json")
}

resource "aws_iam_role_policy_attachment" "attach_app_s3" {
  role       = aws_iam_role.app_ec2_role.name
  policy_arn = aws_iam_policy.app_s3_secrets_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_monitoring" {
  role       = aws_iam_role.app_ec2_role.name
  policy_arn = aws_iam_policy.monitoring_policy.arn
}

# AWS Systems Manager Session Manager policy (replaces SSH/Bastion hosts)
resource "aws_iam_role_policy_attachment" "attach_ssm" {
  role       = aws_iam_role.app_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.app_ec2_role.name
}