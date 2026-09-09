###############################################################################
# ローカル値
###############################################################################

locals {
  name = var.name_prefix

  # サイドカーとアプリで共有するエフェメラルボリューム
  app_log_volume = "app-logs"
  app_log_dir    = "/var/log/app"
  app_log_file   = "/var/log/app/app.log"

  cwagent_container_name = "cloudwatch-agent"
  adot_container_name    = "adot-collector"

  # splat を使うことで count = 0 のときも安全に空リストになる
  security_group_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : aws_security_group.task[*].id

  # ダミーアプリ: 5 秒ごとに共有ボリューム上のファイルへ 1 行書き足すだけ
  app_command = "mkdir -p ${local.app_log_dir}; i=0; while true; do i=$((i+1)); line=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ') app log line $i\"; echo \"$line\" >> ${local.app_log_file}; echo \"$line\"; sleep 5; done"

  #############################################################################
  # ヘルスチェックコマンド
  #
  # simulate_unhealthy = true のときは必ず失敗するコマンドに差し替える。
  # CloudWatch Agent はシェルがあるので `exit 1`、
  # ADOT はシェルを持たないイメージなので「存在しないパスの exec 失敗」で落とす。
  #############################################################################
  cwagent_health_check_command = (
    var.cwagent_simulate_unhealthy
    ? ["CMD-SHELL", "exit 1"]
    : var.cwagent_health_check_command
  )

  adot_health_check_command = (
    var.adot_simulate_unhealthy
    ? ["CMD", "/nonexistent-force-unhealthy"]
    : var.adot_health_check_command
  )

  #############################################################################
  # サイドカー 1: CloudWatch Agent
  #
  # 設定は CW_CONFIG_CONTENT 環境変数で丸ごと渡す。
  # 共有ボリューム上のアプリログを tail して CloudWatch Logs へ転送する。
  #############################################################################
  cwagent_config = jsonencode({
    logs = {
      force_flush_interval = 5
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path       = local.app_log_file
              log_group_name  = aws_cloudwatch_log_group.this.name
              log_stream_name = "app/{hostname}"
              timezone        = "UTC"
            }
          ]
        }
      }
    }
  })

  container_cwagent = {
    name      = local.cwagent_container_name
    image     = var.cwagent_image
    essential = var.cwagent_essential

    environment = [
      {
        name  = "CW_CONFIG_CONTENT"
        value = local.cwagent_config
      },
      {
        name  = "RUN_IN_CONTAINER"
        value = "True"
      },
    ]

    mountPoints = [
      {
        sourceVolume  = local.app_log_volume
        containerPath = local.app_log_dir
        readOnly      = true
      }
    ]

    # ---- 検証ポイント ----
    healthCheck = {
      command     = local.cwagent_health_check_command
      interval    = var.cwagent_health_check_interval
      timeout     = var.cwagent_health_check_timeout
      retries     = var.cwagent_health_check_retries
      startPeriod = var.cwagent_health_check_start_period
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "cwagent"
      }
    }
  }

  #############################################################################
  # サイドカー 2: ADOT Collector
  #
  # 設定は AOT_CONFIG_CONTENT 環境変数で丸ごと渡す。
  # 既定設定は health_check extension (13133/tcp) を有効にし、
  # OTLP で受けたログを CloudWatch Logs へ流すだけの最小パイプライン。
  # 送信元が無くてもコレクタは正常起動し、healthCheck は成功する。
  #############################################################################
  adot_default_config = yamlencode({
    extensions = {
      health_check = {
        endpoint = "0.0.0.0:13133"
      }
    }
    receivers = {
      otlp = {
        protocols = {
          grpc = { endpoint = "0.0.0.0:4317" }
          http = { endpoint = "0.0.0.0:4318" }
        }
      }
    }
    processors = {
      batch = {}
    }
    exporters = {
      awscloudwatchlogs = {
        region          = var.aws_region
        log_group_name  = aws_cloudwatch_log_group.this.name
        log_stream_name = "adot"
      }
    }
    service = {
      extensions = ["health_check"]
      pipelines = {
        logs = {
          receivers  = ["otlp"]
          processors = ["batch"]
          exporters  = ["awscloudwatchlogs"]
        }
      }
    }
  })

  adot_config = var.adot_config != null ? var.adot_config : local.adot_default_config

  container_adot = {
    name      = local.adot_container_name
    image     = var.adot_image
    essential = var.adot_essential

    environment = [
      {
        name  = "AOT_CONFIG_CONTENT"
        value = local.adot_config
      },
    ]

    # ---- 検証ポイント ----
    healthCheck = {
      command     = local.adot_health_check_command
      interval    = var.adot_health_check_interval
      timeout     = var.adot_health_check_timeout
      retries     = var.adot_health_check_retries
      startPeriod = var.adot_health_check_start_period
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "adot"
      }
    }
  }

  #############################################################################
  # ダミーアプリ: 共有ボリュームにログを書き続けるだけ
  #############################################################################
  # 有効化したサイドカーすべての HEALTHY を待つ
  app_depends_on = var.app_depends_on_sidecar_healthy ? concat(
    var.enable_cwagent_sidecar ? [{ containerName = local.cwagent_container_name, condition = "HEALTHY" }] : [],
    var.enable_adot_sidecar ? [{ containerName = local.adot_container_name, condition = "HEALTHY" }] : [],
  ) : []

  container_app = merge(
    {
      name      = "app"
      image     = var.app_image
      essential = true
      command   = ["/bin/sh", "-c", local.app_command]

      mountPoints = [
        {
          sourceVolume  = local.app_log_volume
          containerPath = local.app_log_dir
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app-stdout"
        }
      }
    },
    # dependsOn は不要なときにキーごと落とす (空配列を API に送らない)
    length(local.app_depends_on) > 0 ? { dependsOn = local.app_depends_on } : {},
  )

  #############################################################################
  # タスク定義に載せるコンテナ一覧
  #############################################################################
  containers = concat(
    var.enable_cwagent_sidecar ? [local.container_cwagent] : [],
    var.enable_adot_sidecar ? [local.container_adot] : [],
    [local.container_app],
  )
}

###############################################################################
# CloudWatch Logs
###############################################################################

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_in_days
}

###############################################################################
# セキュリティグループ (未指定時のみ作成 / アウトバウンドのみ)
###############################################################################

resource "aws_security_group" "task" {
  count = length(var.security_group_ids) > 0 ? 0 : 1

  name        = "${local.name}-task"
  description = "Egress only SG for ${local.name} ECS task"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-task" }
}

###############################################################################
# IAM
###############################################################################

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# タスク実行ロール: イメージ pull と awslogs ドライバ用
resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# タスクロール: サイドカーが AWS API を叩くために使う
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# CloudWatch Agent / ADOT Collector がログとメトリクスを送るために使う。
# CloudWatchAgentServerPolicy に logs:CreateLogGroup / CreateLogStream /
# PutLogEvents / DescribeLogStreams が含まれるので両サイドカーで共用できる。
resource "aws_iam_role_policy_attachment" "task_cwagent" {
  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# 追加ポリシー (例: ADOT で X-Ray を使う場合の AWSXrayWriteOnlyAccess)
resource "aws_iam_role_policy_attachment" "task_additional" {
  for_each = toset(var.additional_task_policy_arns)

  role       = aws_iam_role.task.name
  policy_arn = each.value
}

# ECS Exec (コンテナに入ってヘルスチェックコマンドを直接叩くため)
data "aws_iam_policy_document" "exec" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "${local.name}-ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.exec[0].json
}

###############################################################################
# ECS
###############################################################################

resource "aws_ecs_cluster" "this" {
  name = local.name
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # Fargate のエフェメラルストレージ上に作られる共有ボリューム
  volume {
    name = local.app_log_volume
  }

  container_definitions = jsonencode(local.containers)
}

resource "aws_ecs_service" "this" {
  name                   = local.name
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  platform_version       = "1.4.0"
  enable_execute_command = var.enable_execute_command

  # UNHEALTHY で再起動ループになっても apply が止まらないようにする
  wait_for_steady_state              = false
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = local.security_group_ids
    assign_public_ip = var.assign_public_ip
  }
}
