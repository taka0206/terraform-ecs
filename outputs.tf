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
  description = "実際に適用された healthCheck 設定"
  value = {
    command     = local.health_check_command
    interval    = var.sidecar_health_check_interval
    timeout     = var.sidecar_health_check_timeout
    retries     = var.sidecar_health_check_retries
    startPeriod = var.sidecar_health_check_start_period
    essential   = var.sidecar_essential
  }
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

    # サイドカーに入ってヘルスチェックコマンドを直接実行する
    exec_sidecar = join(" ", [
      "aws ecs execute-command --region ${var.aws_region}",
      "--cluster ${aws_ecs_cluster.this.name}",
      "--task $(aws ecs list-tasks --region ${var.aws_region} --cluster ${aws_ecs_cluster.this.name} --service-name ${aws_ecs_service.this.name} --query 'taskArns[0]' --output text)",
      "--container cloudwatch-agent --interactive --command /bin/sh",
    ])
  }
}
