# ==========================
# Providers
# ==========================

# ACM + CloudFront (must be in us-east-1)
provider "aws" {
  region  = "us-east-1"
  profile = "philip-work"
}

# S3 bucket (af-south-1)
provider "aws" {
  alias   = "af_south"
  region  = "af-south-1"
  profile = "philip-work"
}

# ==========================
# Variables
# ==========================
variable "main_domain" {
  default = "nextphaserugby.co.za"
}

variable "subdomain" {
  default = "test" # leave empty "" for root domain
}

# ==========================
# Locals
# ==========================
locals {
  domain_name = length(var.subdomain) > 0 ? "${var.subdomain}.${var.main_domain}" : var.main_domain
  bucket_name = length(var.subdomain) > 0 ? "${var.subdomain}.nextphaserugby.co.za" : "nextphaserugby.co.za"
}

# ==========================
# S3 Bucket
# ==========================
resource "aws_s3_bucket" "website_bucket" {
  provider = aws.af_south
  bucket   = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "website_bucket_access" {
  provider = aws.af_south
  bucket   = aws_s3_bucket.website_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "website_bucket" {
  provider = aws.af_south
  bucket   = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

resource "aws_s3_bucket_policy" "website_policy" {
  provider = aws.af_south
  bucket   = aws_s3_bucket.website_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:aws:s3:::${local.bucket_name}/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.website_bucket_access]
}

# ==========================
# ACM Certificate
# ==========================
resource "aws_acm_certificate" "cert" {
  domain_name               = local.domain_name
  validation_method         = "DNS"
  subject_alternative_names = ["www.${local.domain_name}"]

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_route53_zone" "main" {
  name         = var.main_domain
  private_zone = false
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "cert_validation" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# ==========================
# CloudFront Distribution
# ==========================
resource "aws_cloudfront_distribution" "cdn" {
  origin {
    domain_name = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id   = "S3-${local.bucket_name}"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = [local.domain_name, "www.${local.domain_name}"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${local.bucket_name}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.cert.arn
    ssl_support_method  = "sni-only"
  }

  depends_on = [aws_acm_certificate_validation.cert_validation]
}

# ==========================
# Route 53 Records
# ==========================
resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.${local.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

# ==========================
# Outputs
# ==========================
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "s3_bucket_name" {
  value = aws_s3_bucket.website_bucket.bucket
}
