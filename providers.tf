provider "aws" {
  region = var.aws_region

  # 空文字/未指定なら環境変数(AWS_PROFILE)や既定のクレデンシャルチェーンに委ねる
  profile = var.aws_profile

  # 事故防止: 意図しないアカウントへの apply をブロックする
  allowed_account_ids = var.allowed_account_ids

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "terraform-cwagent-sidecar"
      external_id  = var.assume_role_external_id
    }
  }

  default_tags {
    tags = var.default_tags
  }
}
