terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    region = "us-east-1"
    bucket = "roh-terraform"
    key = "assessmet/terraform.tfstate"
  }
}

# Configure the AWS Provider
provider "aws" {
  region = "us-east-1"
}



# Add the resources relatedo to the provider

resource "aws_s3_bucket" "main" {
  for_each = toset(["app", "logs"])
  bucket = "${terraform.workspace}-${each.key}-sre-assesmet-bucket"

  tags = {
    Name        = "${terraform.workspace}-${each.key}-sre-assesmet-bucket"
    Environment = terraform.workspace
  }
}

resource "aws_s3_bucket_ownership_controls" "main" {
  for_each = aws_s3_bucket.main
  bucket = aws_s3_bucket.main[each.key].id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "main" {
  for_each = aws_s3_bucket.main
  depends_on = [aws_s3_bucket_ownership_controls.main]

  bucket = aws_s3_bucket.main[each.key].id
  acl    = "private"
}


resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  for_each = aws_s3_bucket.main
  bucket = aws_s3_bucket.main[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "AES256"
    }
  }
}




# See https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
data "aws_iam_policy_document" "origin_bucket_policy" {
  statement {
    sid    = "AllowCloudFrontServicePrincipalReadWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = [
      "${aws_s3_bucket.main["app"].arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.s3_distribution.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "b" {
  bucket = aws_s3_bucket.main["app"].bucket
  policy = data.aws_iam_policy_document.origin_bucket_policy.json
}

resource "aws_cloudfront_origin_access_control" "default" {
  name                              = "${terraform.workspace}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.main["app"].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.default.id
    origin_id                = local.s3_origin_id
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${terraform.workspace} distribution"
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  price_class = "PriceClass_200"

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA", "GB", "DE"]
    }
  }

  tags = {
    Environment = terraform.workspace
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

}

resource "aws_cloudwatch_log_delivery_source" "main" {
  region = "us-east-1"

  name         = "${terraform.workspace}-log"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.s3_distribution.arn
}


resource "aws_cloudwatch_log_delivery_destination" "main" {
  region = "us-east-1"

  name          = "${terraform.workspace}s3-destination"
  output_format = "parquet"

  delivery_destination_configuration {
    destination_resource_arn = "${aws_s3_bucket.main["logs"].arn}/prefix"
  }
}

resource "aws_cloudwatch_log_delivery" "main" {
  region = "us-east-1"

  delivery_source_name     = aws_cloudwatch_log_delivery_source.main.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.main.arn

  s3_delivery_configuration {
    suffix_path = "/120569633496/{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
  }
}
