# terraform/security_groups.tf

# 1. ALB Security Group: Accepts HTTP/HTTPS from Internet, forwards only to App SG on 8000
resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Public ALB SG allowing HTTP redirect and HTTPS only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from Internet for 301 Redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# 2. Application Tier SG: Accepts port 8000 ONLY from ALB SG (No SSH/22)
resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Private App SG accepting traffic strictly from ALB SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Allow Gunicorn/Flask port 8000 strictly from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "HTTPS outbound for SSM Session Manager, S3, Secrets Manager, and OS updates"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-app-sg" }
}

# Scoped ALB -> App egress rule
resource "aws_security_group_rule" "alb_to_app_egress" {
  type                     = "egress"
  from_port                = 8000
  to_port                  = 8000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb_sg.id
  source_security_group_id = aws_security_group.app_sg.id
  description              = "Forward traffic strictly to App SG on port 8000"
}

# 3. Database Tier SG: Accepts PostgreSQL 5432 ONLY from App SG
resource "aws_security_group" "db_sg" {
  name        = "${var.project_name}-db-sg"
  description = "Private RDS SG allowing PostgreSQL 5432 strictly from App SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL strictly from App Tier SG"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  tags = { Name = "${var.project_name}-db-sg" }
}

# Scoped App -> DB egress rule
resource "aws_security_group_rule" "app_to_db_egress" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.app_sg.id
  source_security_group_id = aws_security_group.db_sg.id
  description              = "Allow outbound PostgreSQL to DB SG"
}