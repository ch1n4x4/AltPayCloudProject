# terraform/ec2_app.tf
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "app_server" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro" # Free-Tier eligible
  subnet_id                   = aws_subnet.private_app_a.id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.app_profile.name
  associate_public_ip_address = false

  # Enforce IMDSv2 (blocks SSRF credential theft)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = aws_kms_key.altpay_cmk.arn
  }

  user_data = templatefile("${path.module}/userdata.sh", {
    aws_region     = var.aws_region
    uploads_bucket = aws_s3_bucket.uploads.id
    db_secret_arn  = aws_secretsmanager_secret.db_credentials.arn
  })

  tags = { Name = "${var.project_name}-private-app-server" }
  depends_on = [aws_nat_gateway.nat]
}