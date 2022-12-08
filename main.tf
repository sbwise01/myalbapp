provider "aws" {
  region  = "us-east-2"
}

###########################
# Route 53
###########################
resource "aws_route53_zone" "parent_zone" {
  name              = "aws.bradandmarsha.com"
  delegation_set_id = "N03386422VXZJKGR4YO18"
}

resource "aws_route53_zone" "zone" {
  name              = "myalbapp.${aws_route53_zone.parent_zone.name}"
}

resource "aws_route53_record" "delegation" {
  allow_overwrite = true
  name            = "myalbapp"
  ttl             = 300
  type            = "NS"
  zone_id         = aws_route53_zone.parent_zone.id
  records         = aws_route53_zone.zone.name_servers
}

###########################
# VPC and Subnets
###########################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.18.1"

  name = "myalbapp"
  cidr = "10.11.0.0/16"
  azs  = ["us-east-2a", "us-east-2b", "us-east-2c"]

  private_subnets = ["10.11.0.0/24", "10.11.1.0/24", "10.11.2.0/24"]
  public_subnets  = ["10.11.3.0/24", "10.11.4.0/24", "10.11.5.0/24"]

  enable_nat_gateway = true
}

###########################
# EC2 Instance
###########################
data "aws_ami" "amzn2" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-*-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = [
    "137112412989" # Amazon
  ]
}

resource "aws_key_pair" "myalbapp" {
  key_name   = "myalbapp-key"
  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDVZ1AzSzTTSr2v98UA6Swx5udfiDb7DRU0S3kNHHGjp5eJcqUouipoOWYqZwkTQ7LHXwVhs/c58y2sKKnKSAQlBDN6rlpwZBoXG96vBULALmRREdaTcQD8XMJxSVWU0vEolM1DgK2lp6a9tPPs3Ltxb1Zd5J4kTIDBM3Zdz1Gj4IHDLABZzo/GdzFVlIaLtw3PrkUykYG6ZPtg/OZ+ccJSOEHyOqf0L411HiaFOKpejjyOSqwSaEIRWWw0Ro9gdbhZ4m4zzvMCT4ukj9ysM6P//7d705cGkZNSJRXVImrLf6UBKZ+4QmblJivRYzz2mOcBFvI5V9TAT2Bl363dqka5 bwise@Brads-MBP"
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.amzn2.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.myalbapp.key_name
  vpc_security_group_ids = [aws_security_group.ec2_ingress_allow.id]
  subnet_id              = module.vpc.private_subnets[0]
  user_data              = <<EOF
#!/bin/bash
yum update -y
yum install httpd -y
systemctl enable httpd
systemctl start httpd
EOF
}

resource "aws_security_group" "ec2_ingress_allow" {
  name   = "myalbapp-ec2-ingress-allow"
  vpc_id = module.vpc.vpc_id
}

resource "aws_security_group_rule" "ec2_ingress_instances_80" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_egress_allow.id
  description              = "Allow (port 80) traffic inbound to app instances from alb"

  security_group_id = aws_security_group.ec2_ingress_allow.id
}

resource "aws_security_group_rule" "ec2_egress_instances_all" {
  type              = "egress"
  from_port         = "0"
  to_port           = "65535"
  protocol          = "all"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.ec2_ingress_allow.id
}

resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.default.arn
  target_id        = aws_instance.web.id
  port             = 80
}

###########################
# ACM Certificate
###########################
resource "aws_acm_certificate" "cert" {
  domain_name       = aws_route53_zone.zone.name
  subject_alternative_names = ["*.${aws_route53_zone.zone.name}"]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = merge([
    for dvo in aws_acm_certificate.cert.domain_validation_options : {
      "dns_record" = {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
      }
    }
  ]...)

  name    = each.value.name
  type    = each.value.type
  zone_id = aws_route53_zone.zone.zone_id
  records = [each.value.record]
  ttl     = 60
}

###########################
# Application Load Balancer
###########################
resource "aws_lb" "alb" {
  name = "myalbapp-web-alb"

  load_balancer_type         = "application"
  subnets                    = module.vpc.public_subnets
  drop_invalid_header_fields = true

  security_groups = [
    aws_security_group.alb_ingress_allow.id,
    aws_security_group.alb_egress_allow.id
  ]
}

resource "aws_lb_listener" "alb_443" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = aws_acm_certificate.cert.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.default.arn
  }
}

resource "aws_lb_target_group" "default" {
  name     = "myalbapp-alb-tg-443"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    protocol            = "HTTP"
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 7
    timeout             = 5
    interval            = 30
    matcher             = "200,403"
  }
}

resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.zone.zone_id
  name    = "app"
  type    = "A"

  alias {
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
    evaluate_target_health = true
  }
}

output "application_url" {
  value = "https://${aws_route53_record.app.fqdn}/"
}

###########################
# ALB Security Groups
###########################
resource "aws_security_group" "alb_ingress_allow" {
  name        = "myalbapp-lb-allow"
  description = "ALB ingress"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group_rule" "alb_ingress_allow_https" {
  type      = "ingress"
  from_port = 443
  to_port   = 443
  protocol  = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
  description = "Allow HTTPS (port 443) traffic inbound to LB"

  security_group_id = aws_security_group.alb_ingress_allow.id
}

resource "aws_security_group" "alb_egress_allow" {
  name   = "myalbapp-alb-egress-allow"
  vpc_id = module.vpc.vpc_id
}

resource "aws_security_group_rule" "alb_egress_instances_80" {
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2_ingress_allow.id
  description              = "Allow (port 80) traffic outbound to app instances"

  security_group_id = aws_security_group.alb_egress_allow.id
}

