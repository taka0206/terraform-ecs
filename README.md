# CloudWatch Agent サイドカー ヘルスチェック検証用 Terraform

ECS (Fargate) の `healthCheck` 設定が **CloudWatch Agent サイドカー** に対して
どう効くかを最短で確認するための、最小構成の Terraform です。

## 構成

```
ECS Cluster (Fargate)
└── Service (desired_count = 1)
    └── Task
        ├── cloudwatch-agent  ← 検証対象。healthCheck を設定
        │     CW_CONFIG_CONTENT で /var/log/app/app.log を tail し
        │     CloudWatch Logs へ転送
        └── app (busybox)     ← 5 秒ごとに /var/log/app/app.log へ 1 行追記
              dependsOn: cloudwatch-agent が HEALTHY になるまで起動待ち
```

作成されるリソースはこれだけです（VPC / サブネットは既存のものを指定）。

| リソース | 用途 |
| --- | --- |
| `aws_ecs_cluster` | Fargate クラスタ |
| `aws_ecs_task_definition` | サイドカー + ダミーアプリの 2 コンテナ |
| `aws_ecs_service` | 常時 1 タスク |
| `aws_cloudwatch_log_group` | `/ecs/<name_prefix>` (保持 1 日) |
| `aws_iam_role` × 2 | 実行ロール / タスクロール |
| `aws_security_group` | アウトバウンドのみ（未指定時のみ作成） |

## 前提

- 指定するサブネットは **プライベートサブネット** 想定です。
  イメージ取得（`public.ecr.aws`）とログ送信のために、
  **NAT Gateway** もしくは `com.amazonaws.<region>.ecr.api` /
  `ecr.dkr` / `logs` の Interface エンドポイント + `s3` の Gateway
  エンドポイントが必要です。
  経路が無いとタスクが `CannotPullContainerError` で起動しません。
- ECS Exec を使う場合は AWS CLI に
  [Session Manager Plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  が必要です。

## 使い方

```bash
cp terraform.tfvars.example terraform.tfvars
# vpc_id / subnet_ids / aws_region / aws_profile などを埋める
vi terraform.tfvars

terraform init
terraform apply
```

apply 後、出力された `check_commands` のコマンドで確認します。

```bash
# そのまま貼れるコマンド一覧を表示
terraform output check_commands

# コンテナごとの healthStatus / lastStatus
aws ecs describe-tasks --region ap-northeast-1 \
  --cluster cwagent-sidecar-test \
  --tasks "$(aws ecs list-tasks --region ap-northeast-1 \
      --cluster cwagent-sidecar-test --service-name cwagent-sidecar-test \
      --query 'taskArns[0]' --output text)" \
  --query 'tasks[0].{taskHealth:healthStatus,containers:containers[].{name:name,last:lastStatus,health:healthStatus,reason:reason}}' \
  --output table

# CloudWatch Agent が転送したログ
aws logs tail /ecs/cwagent-sidecar-test --region ap-northeast-1 --follow
```

`app/<hostname>` ストリームにアプリのログ行が届いていれば、
サイドカーによる転送が成功しています。
（`cwagent/...` と `app-stdout/...` ストリームは awslogs ドライバによる
コンテナ標準出力で、切り分け用です。）

## 検証シナリオ

すべて変数の変更 → `terraform apply` だけで切り替えられます。

### 1. ヘルスチェックコマンドの妥当性を確かめる

`cloudwatch-agent` イメージに何が入っているかで使えるコマンドが変わります。
まずコンテナに入って手で叩くのが確実です。

```bash
aws ecs execute-command --region ap-northeast-1 \
  --cluster cwagent-sidecar-test \
  --task "$(aws ecs list-tasks --region ap-northeast-1 \
      --cluster cwagent-sidecar-test --service-name cwagent-sidecar-test \
      --query 'taskArns[0]' --output text)" \
  --container cloudwatch-agent --interactive --command /bin/sh

# コンテナ内で
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status; echo "exit=$?"
pgrep -f amazon-cloudwatch-agent;                                    echo "exit=$?"
```

うまくいったものを `sidecar_health_check_command` に設定してください
（候補は `terraform.tfvars.example` の A〜D を参照）。
ヘルスチェックが常に成功する／常に失敗する挙動だけ見たい場合は
`["CMD-SHELL", "exit 0"]` / `["CMD-SHELL", "exit 1"]` が手っ取り早いです。

### 2. UNHEALTHY 時の挙動（essential の効き方）

```hcl
simulate_unhealthy = true
sidecar_essential  = true   # → タスクごと停止して再起動を繰り返す
```

```hcl
simulate_unhealthy = true
sidecar_essential  = false  # → サイドカーだけ停止、app は動き続ける
```

停止理由はサービスイベントに出ます。

```bash
aws ecs describe-services --region ap-northeast-1 \
  --cluster cwagent-sidecar-test --services cwagent-sidecar-test \
  --query 'services[0].events[:10].message' --output table
```

### 3. dependsOn (condition = HEALTHY) の待ち合わせ

```hcl
app_depends_on_sidecar_healthy = true
simulate_unhealthy             = true
```

サイドカーが HEALTHY にならないため `app` は `PENDING` のまま起動しません。
`false` にすると待ち合わせなしで両方同時に起動します。

### 4. startPeriod / interval / retries の効き方

`sidecar_health_check_start_period` を長くすると、その間の失敗は
`retries` にカウントされず UNHEALTHY 判定が遅れることを確認できます。
`interval × retries` が UNHEALTHY 判定までの実質的な時間になります。

## 反映を速くするコツ

`terraform apply` はタスク定義の新リビジョン登録とサービス更新までで完了し、
新タスクの起動完了は待ちません（`wait_for_steady_state = false`）。
すぐに結果を見たいときは、apply 後に強制デプロイをかけてください。

```bash
aws ecs update-service --region ap-northeast-1 \
  --cluster cwagent-sidecar-test --service cwagent-sidecar-test \
  --force-new-deployment
```

## 後片付け

```bash
terraform destroy
```

## 注意

- `log_retention_in_days = 1` にしてあります。検証後は `terraform destroy` で
  ロググループごと削除されます。
- `cwagent_image` は `:latest` を既定にしています。再現性が必要な検証では
  タグを固定してください。
