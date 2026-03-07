# ─── S3 (backup CloudNativePG) ───────────────────────────────────────────────
module "s3_backup" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.name_prefix}-cnpg-backup"

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "expire-old-backups"
      enabled = true
      expiration = {
        days = 30
      }
    }
  ]

  tags = local.tags
}

# ─── S3 (chunks do Loki) ─────────────────────────────────────────────────────
module "s3_loki" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "${local.name_prefix}-loki-chunks"

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "expire-old-chunks"
      enabled = true
      expiration = {
        days = 30
      }
    }
  ]

  tags = local.tags
}
