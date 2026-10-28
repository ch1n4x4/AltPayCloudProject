# terraform/rds.tf
resource "aws_db_subnet_group" "db_subnets" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = [aws_subnet.private_db_a.id, aws_subnet.private_db_b.id]
  tags       = { Name = "${var.project_name}-db-subnet-group" }
}

resource "aws_db_instance" "postgres" {
  identifier              = "${var.project_name}-postgres-db"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = "db.t3.micro" # Free-Tier eligible
  allocated_storage       = 20
  storage_type            = "gp3"
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.altpay_cmk.arn

  db_name                 = "altpaydb"
  username                = "altpay_admin"
  password                = random_password.db_password.result

  db_subnet_group_name    = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  publicly_accessible     = false
  multi_az                = false # Single-AZ to stay within AWS Free Tier 750 hrs/month

  backup_retention_period = 1
  backup_window           = "03:00-04:00"
  copy_tags_to_snapshot   = true
  skip_final_snapshot     = true # Simplifies cleanup after grading
  deletion_protection     = false

  tags = { Name = "${var.project_name}-postgres-db" }
}

