output "cluster_name" {
  description = "ECS クラスタ名"
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS サービス名"
  value       = aws_ecs_service.this.name
}

output "task_definition_arn" {
  description = "タスク定義 ARN"
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "CloudWatch Logs ロググループ名"
  value       = aws_cloudwatch_log_group.this.name
}

output "effective_health_check" {
  description = "実際に適用された各サイドカーの healthCheck 設定"
  value = {
    cloudwatch-agent = var.enable_cwagent_sidecar ? {
      command     = local.cwagent_health_check_command
      interval    = var.cwagent_health_check_interval
      timeout     = var.cwagent_health_check_timeout
      retries     = var.cwagent_health_check_retries
      startPeriod = var.cwagent_health_check_start_period
      essential   = var.cwagent_essential
    } : null

    adot-collector = var.enable_adot_sidecar ? {
      command     = local.adot_health_check_command
      interval    = var.adot_health_check_interval
      timeout     = var.adot_health_check_timeout
      retries     = var.adot_health_check_retries
      startPeriod = var.adot_health_check_start_period
      essential   = var.adot_essential
    } : null
  }
}

output "container_names" {
  description = "タスクに載っているコンテナ名 (起動順の依存関係を確認するとき用)"
  value       = [for c in local.containers : c.name]
}

output "adot_config" {
  description = "ADOT Collector に渡される設定 (YAML)"
  value       = var.enable_adot_sidecar ? local.adot_config : null
}

output "check_commands" {
  description = "動作確認に使う AWS CLI コマンド"
  value = {
    # コンテナごとの healthStatus / lastStatus を見る
    describe_containers = join(" ", [
      "aws ecs describe-tasks --region ${var.aws_region}",
      "--cluster ${aws_ecs_cluster.this.name}",
      "--tasks $(aws ecs list-tasks --region ${var.aws_region} --cluster ${aws_ecs_cluster.this.name} --service-name ${aws_ecs_service.this.name} --query 'taskArns[0]' --output text)",
      "--query 'tasks[0].{taskHealth:healthStatus,containers:containers[].{name:name,last:lastStatus,health:healthStatus,reason:reason}}'",
      "--output table",
    ])

    # UNHEALTHY による停止イベントを追う
    service_events = join(" ", [
      "aws ecs describe-services --region ${var.aws_region}",
      "--cluster ${aws_ecs_cluster.this.name}",
      "--services ${aws_ecs_service.this.name}",
      "--query 'services[0].events[:10].message' --output table",
    ])

    # CloudWatch Agent が転送したログを見る
    tail_logs = "aws logs tail ${aws_cloudwatch_log_group.this.name} --region ${var.aws_region} --follow"

    # CloudWatch Agent に入ってヘルスチェックコマンドを直接実行する
    # (ADOT イメージはシェルを持たないので exec で入れない点に注意)
    exec_cwagent = join(" ", [
      "aws ecs execute-command --region ${var.aws_region}",
      "--cluster ${aws_ecs_cluster.this.name}",
      "--task $(aws ecs list-tasks --region ${var.aws_region} --cluster ${aws_ecs_cluster.this.name} --service-name ${aws_ecs_service.this.name} --query 'taskArns[0]' --output text)",
      "--container ${local.cwagent_container_name} --interactive --command /bin/sh",
    ])

    # ADOT Collector の起動ログ (health_check extension の待受を確認できる)
    adot_logs = "aws logs tail ${aws_cloudwatch_log_group.this.name} --region ${var.aws_region} --log-stream-name-prefix adot/ --follow"
  }
}
