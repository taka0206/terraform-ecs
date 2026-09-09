###############################################################################
# アカウント / プロバイダ
###############################################################################

variable "aws_region" {
  description = "リソースを作成するリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_profile" {
  description = "使用する AWS CLI プロファイル名。null なら既定のクレデンシャルチェーンを使用"
  type        = string
  default     = null
}

variable "assume_role_arn" {
  description = "AssumeRole する IAM ロール ARN。null なら AssumeRole しない"
  type        = string
  default     = null
}

variable "assume_role_external_id" {
  description = "AssumeRole 時の ExternalId (任意)"
  type        = string
  default     = null
}

variable "allowed_account_ids" {
  description = "apply を許可する AWS アカウント ID のリスト。空なら制限なし"
  type        = list(string)
  default     = []
}

variable "default_tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default = {
    Project   = "cwagent-sidecar-healthcheck-test"
    ManagedBy = "terraform"
  }
}

###############################################################################
# ネットワーク (既存 VPC / サブネットを指定)
###############################################################################

variable "vpc_id" {
  description = "既存 VPC の ID"
  type        = string
}

variable "subnet_ids" {
  description = "ECS タスクを起動するサブネット ID のリスト (プライベートサブネット想定。NAT Gateway もしくは ECR/S3/Logs の VPC エンドポイントが必要)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids は 1 つ以上指定してください。"
  }
}

variable "security_group_ids" {
  description = "タスクに割り当てる既存セキュリティグループ。空の場合はアウトバウンド全許可の SG を新規作成する"
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = "タスク ENI にパブリック IP を割り当てるか。プライベートサブネットでは false"
  type        = bool
  default     = false
}

###############################################################################
# 命名 / ログ
###############################################################################

variable "name_prefix" {
  description = "作成するリソース名のプレフィックス"
  type        = string
  default     = "cwagent-sidecar-test"
}

variable "log_retention_in_days" {
  description = "CloudWatch Logs のロググループ保持期間 (日)"
  type        = number
  default     = 1
}

###############################################################################
# タスク定義
###############################################################################

variable "task_cpu" {
  description = "タスク全体の CPU ユニット (Fargate)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "タスク全体のメモリ MiB (Fargate)"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "ECS サービスの希望タスク数"
  type        = number
  default     = 1
}

variable "cwagent_image" {
  description = "CloudWatch Agent サイドカーのイメージ"
  type        = string
  default     = "public.ecr.aws/cloudwatch-agent/cloudwatch-agent:latest"
}

variable "app_image" {
  description = "ログを吐き出すだけのダミーアプリコンテナのイメージ"
  type        = string
  default     = "public.ecr.aws/docker/library/busybox:latest"
}

variable "enable_execute_command" {
  description = "ECS Exec を有効にするか。true ならコンテナに入ってヘルスチェックコマンドを直接検証できる"
  type        = bool
  default     = true
}

###############################################################################
# ヘルスチェック (今回の検証対象)
###############################################################################

variable "sidecar_health_check_command" {
  description = <<-EOT
    CloudWatch Agent サイドカーの healthCheck.command。
    既定は amazon-cloudwatch-agent-ctl の status 出力を判定する方式。
    イメージに含まれるコマンド次第で成否が変わるため、
    terraform.tfvars.example の代替パターンも参照のこと。
  EOT
  type        = list(string)
  default = [
    "CMD-SHELL",
    "/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status | grep -q '\"status\": *\"running\"' || exit 1"
  ]
}

variable "sidecar_health_check_interval" {
  description = "healthCheck.interval (秒)"
  type        = number
  default     = 30
}

variable "sidecar_health_check_timeout" {
  description = "healthCheck.timeout (秒)"
  type        = number
  default     = 5
}

variable "sidecar_health_check_retries" {
  description = "healthCheck.retries (UNHEALTHY と判定するまでの連続失敗回数)"
  type        = number
  default     = 3
}

variable "sidecar_health_check_start_period" {
  description = "healthCheck.startPeriod (秒)。この間の失敗は retries にカウントされない"
  type        = number
  default     = 30
}

variable "sidecar_essential" {
  description = <<-EOT
    サイドカーを essential にするか。
    true  : サイドカーが UNHEALTHY で停止するとタスク全体が停止し、サービスが再起動する
    false : サイドカーだけが停止し、アプリコンテナはそのまま動き続ける
  EOT
  type        = bool
  default     = true
}

variable "app_depends_on_sidecar_healthy" {
  description = "アプリコンテナを dependsOn condition=HEALTHY でサイドカーの healthy 待ちにするか"
  type        = bool
  default     = true
}

variable "simulate_unhealthy" {
  description = <<-EOT
    true にすると healthCheck.command を `exit 1` に差し替え、
    UNHEALTHY 時の挙動 (essential / dependsOn の効き方) を強制的に再現する。
    var.sidecar_health_check_command より優先される。
  EOT
  type        = bool
  default     = false
}
