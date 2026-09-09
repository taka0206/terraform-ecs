###############################################################################
# ローカル値
###############################################################################

locals {
  name = var.name_prefix

  # サイドカーとアプリで共有するエフェメラルボリューム
  app_log_volume = "app-logs"
  app_log_dir    = "/var/log/app"
  app_log_file   = "/var/log/app/app.log"

  # 検証用: simulate_unhealthy = true なら必ず失敗するコマンドに差し替える
  health_check_command = var.simulate_unhealthy ? ["CMD-SHELL", "exit 1"] : var.sidecar_health_check_command

  # splat を使うことで count = 0 のときも安全に空リストになる
  security_group_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : aws_security_group.task[*].id

  # ダミーアプリ: 5 秒ごとに共有ボリューム上のファイルへ 1 行書き足すだけ
  app_command = "mkdir -p ${local.app_log_dir}; i=0; while true; do i=$((i+1)); line=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ') app log line $i\"; echo \"$line\" >> ${local.app_log_file}; echo \"$line\"; sleep 5; done"

  # CloudWatch Agent の設定は CW_CONFIG_CONTENT 環境変数で丸ごと渡す
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

  #############################################################################
  # 検証対象: CloudWatch Agent サイドカー
  #############################################################################
  container_cwagent = {
    name      = "cloudwatch-agent"
    image     = var.cwagent_image
    essential = var.sidecar_essential

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

    # ---- ここが今回の検証ポイント ----
    healthCheck = {
      command     = local.health_check_command
      interval    = var.sidecar_health_check_interval
      timeout     = var.sidecar_health_check_timeout
      retries     = var.sidecar_health_check_retries
      startPeriod = var.sidecar_health_check_start_period
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
  # ダミーアプリ: 共有ボリュームにログを書き続けるだけ
  #############################################################################
  # dependsOn は不要なときにキーごと落とす (空配列を API に送らない)
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
    # サイドカーが HEALTHY になるまでアプリの起動を待たせる
    var.app_depends_on_sidecar_healthy ? {
      dependsOn = [
        {
          containerName = "cloudwatch-agent"
          condition     = "HEALTHY"
        }
      ]
    } : {},
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

# タスクロール: CloudWatch Agent がログ/メトリクスを送るために使う
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_cwagent" {
  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
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

  container_definitions = jsonencode([
    local.container_cwagent,
    local.container_app,
  ])
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
