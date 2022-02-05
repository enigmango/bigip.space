resource "aws_s3_bucket" "bigip" {
  bucket = "bigip"
  acl    = "private"

  provider = aws.use2
}

data "aws_iam_policy_document" "bigip_public" {
  statement {
    sid = "PublicReadGetObject"
    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "${aws_s3_bucket.bigip.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_public_access_block" "bigip" {
  bucket = aws_s3_bucket.bigip.id

  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
  block_public_acls       = true

  provider = aws.use2
}

resource "aws_s3_bucket_policy" "bigip_public" {
  bucket = aws_s3_bucket.bigip.id
  policy = data.aws_iam_policy_document.bigip_public.json

  provider = aws.use2
}

data "aws_cloudfront_origin_request_policy" "managed_all_viewer" {
  name = "Managed-AllViewer"
}

data "aws_cloudfront_cache_policy" "managed_caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_function" "myip" {
  name    = "myip"
  runtime = "cloudfront-js-1.0"
  publish = true
  code    = <<CODE
function handler(event) {
    var request = event.request;
    var clientIP = event.viewer.ip;

    //Add the true-client-ip header to the incoming request
    request.headers['true-client-ip'] = {value: clientIP};

    return request;
}
CODE
}

locals {
  origin_id = "placeholder-origin"
}

resource "aws_cloudfront_distribution" "bigip" {
  origin {
    domain_name = aws_s3_bucket.bigip.bucket_regional_domain_name
    origin_id   = local.origin_id
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = aws_s3_bucket_object.index.key

  aliases = ["bigip.space"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", ]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.origin_id

    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.managed_all_viewer.id
    cache_policy_id          = data.aws_cloudfront_cache_policy.managed_caching_optimized.id

    compress = true

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0


    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.myip.arn
    }

    lambda_function_association {
      event_type   = "origin-request"
      include_body = false
      lambda_arn   = aws_lambda_function.bigip.qualified_arn
    }
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.bigip.arn
    minimum_protocol_version = "TLSv1.1_2016"
    ssl_support_method       = "sni-only"
  }
}

resource "aws_acm_certificate" "bigip" {
  domain_name       = "bigip.space"
  validation_method = "DNS"

  subject_alternative_names = ["*.bigip.space"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "bigip" {
  certificate_arn         = aws_acm_certificate.bigip.arn
  validation_record_fqdns = [for record in aws_route53_record.bigip_validation : record.fqdn]
}

resource "aws_route53_zone" "bigip" {
  name = "bigip.space"
}

resource "aws_route53_record" "bigip_validation" {
  for_each = {
    for dvo in aws_acm_certificate.bigip.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    } if dvo.domain_name != "*.bigip.space" # wildcard on root domain is a dupe record of root domain
  }

  allow_overwrite = true
  name            = split(".", each.value.name)[0]
  records         = [each.value.record]
  ttl             = 300
  type            = each.value.type
  zone_id         = aws_route53_zone.bigip.zone_id
}

resource "aws_iam_role_policy_attachment" "bigip" {
  role       = aws_iam_role.bigip.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "bigip" {
  name = "bigip"
  path = "/service-role/"

  assume_role_policy = <<-POLICY
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Service": [
                        "edgelambda.amazonaws.com",
                        "lambda.amazonaws.com"
                    ]
                },
                "Action": "sts:AssumeRole"
            }
        ]
    }
POLICY
}

data "archive_file" "lambda" {
  type             = "zip"
  output_file_mode = "0666"
  output_path      = "${path.module}/.terraform/bigip.zip"

  source {
    content = templatefile(
      "./lambda_function.tftpl",
      {
        css_file = "https://${aws_s3_bucket.bigip.bucket_regional_domain_name}/${aws_s3_bucket_object.css.key}"
        bg_file  = "https://${aws_s3_bucket.bigip.bucket_regional_domain_name}/${aws_s3_bucket_object.bg.key}"
      }
    )
    filename = "lambda_function.py"
  }
}

resource "aws_lambda_function" "bigip" {
  filename      = data.archive_file.lambda.output_path
  function_name = "bigip"
  role          = aws_iam_role.bigip.arn
  handler       = "lambda_function.lambda_handler"

  publish = true

  source_code_hash = filebase64sha256(data.archive_file.lambda.output_path)

  runtime = "python3.9"
}

resource "aws_s3_bucket_object" "css" {
  bucket = aws_s3_bucket.bigip.id
  key    = "main.css"
  source = "${path.module}/../public/main.css"

  content_type = "text/css"

  provider = aws.use2
}

resource "aws_s3_bucket_object" "bg" {
  bucket = aws_s3_bucket.bigip.id
  key    = "bg.png"
  source = "${path.module}/../public/bg.png"

  provider = aws.use2

}

resource "aws_s3_bucket_object" "index" {
  bucket = aws_s3_bucket.bigip.id
  key    = "index.html"
  source = "${path.module}/../public/index.html"

  provider = aws.use2
}