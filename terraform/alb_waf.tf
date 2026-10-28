# terraform/alb_waf.tf

# Generate TLS Certificate for ACM if no custom domain is provided
resource "tls_private_key" "alb_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb_cert" {
  private_key_pem = tls_private_key.alb_key.private_key_pem
  subject {
    common_name  = var.domain_name != "" ? var.domain_name : "${var.project_name}.internal.eu-west-1.elb.amazonaws.com"
    organization = "AltPay Financial Services"
  }
  validity_period_hours = 720
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "alb_cert" {
  private_key      = tls_private_key.alb_key.private_key_pem
  certificate_body = tls_self_signed_cert.alb_cert.cert_pem
  tags             = { Name = "${var.project_name}-acm-cert" }
}

# Application Load Balancer
resource "aws_lb" "public_alb" {
  name                       = "${var.project_name}-public-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb_sg.id]
  subnets                    = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  drop_invalid_header_fields = true
  tags                       = { Name = "${var.project_name}-public-alb" }
}

resource "aws_lb_target_group" "app_tg" {
  name        = "${var.project_name}-app-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "app_attach" {
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.app_server.id
  port             = 8000
}

# HTTP 80 -> Redirects 301 to HTTPS 443
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.public_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS 443 Listener Enforcing TLS 1.2+
resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.public_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.alb_cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# AWS WAFv2 Web ACL with OWASP Core Rule Set & SQLi Protection
resource "aws_wafv2_web_acl" "altpay_waf" {
  count       = var.enable_waf ? 1 : 0
  name        = "${var.project_name}-waf-acl"
  description = "OWASP Top 10 and SQLi protection for AltPay ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AltPayCommonRules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AltPaySQLiRules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "AltPayWAFACL"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb_waf_assoc" {
  count        = var.enable_waf ? 1 : 0
  resource_arn = aws_lb.public_alb.arn
  web_acl_arn  = aws_wafv2_web_acl.altpay_waf[0].arn
}
