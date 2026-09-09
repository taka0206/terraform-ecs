# サイドカーコンテナ ヘルスチェック検証用 Terraform

ECS (Fargate) の `healthCheck` 設定が **CloudWatch Agent** と
**ADOT (AWS Distro for OpenTelemetry) Collector** の各サイドカーに対して
どう効くかを最短で確認するための、最小構成の Terraform です。

## 構成

```
ECS Cluster (Fargate)
└── Service (desired_count = 1)
    └── Task
        ├── cloudwatch-agent  ← 検証対象 1。healthCheck を設定
        │     CW_CONFIG_CONTENT で /var/log/app/app.log を tail し
        │     CloudWatch Logs へ転送
        ├── adot-collector    ← 検証対象 2。healthCheck を設定
        │     AOT_CONFIG_CONTENT で health_check extension (13133/tcp) を有効化
        │     OTLP 受信 → CloudWatch Logs の最小パイプライン
        └── app (busybox)     ← 5 秒ごとに /var/log/app/app.log へ 1 行追記
              dependsOn: 有効化した全サイドカーが HEALTHY になるまで起動待ち
```

作成されるリソースはこれだけです（VPC / サブネットは既存のものを指定）。

| リソース | 用途 |
| --- | --- |
| `aws_ecs_cluster` | Fargate クラスタ |
| `aws_ecs_task_definition` | サイドカー 2 本 + ダミーアプリ |
| `aws_ecs_service` | 常時 1 タスク |
| `aws_cloudwatch_log_group` | `/ecs/<name_prefix>` (保持 1 日) |
| `aws_iam_role` × 2 | 実行ロール / タスクロール |
| `aws_security_group` | アウトバウンドのみ（未指定時のみ作成） |

## 2 つのサイドカーのヘルスチェック方式の違い

|  | CloudWatch Agent | ADOT Collector |
| --- | --- | --- |
| イメージ | `public.ecr.aws/cloudwatch-agent/cloudwatch-agent` | `public.ecr.aws/aws-observability/aws-otel-collector` |
| 設定の渡し方 | `CW_CONFIG_CONTENT` (JSON) | `AOT_CONFIG_CONTENT` (YAML) |
| ヘルスの根拠 | エージェントプロセスの状態 | `health_check` extension (13133/tcp) |
| 既定コマンド | `CMD-SHELL` + `amazon-cloudwatch-agent-ctl -a status` | `CMD` + `/healthcheck` |
| シェルの有無 | あり（`CMD-SHELL` が使える） | **なし**（`CMD` でバイナリ直接指定のみ） |
| 強制 UNHEALTHY 方法 | `exit 1` | 存在しないパスを exec させて失敗 |

ADOT 側は `wget` / `curl` / `sh` を含まないイメージのため、
`CMD-SHELL` 形式のヘルスチェックは書けません。イメージに同梱される
`/healthcheck` バイナリが `health_check` extension を叩く仕組みです。
このため `adot_config` を独自設定に差し替える場合も、
**`extensions` に `health_check` を残す**必要があります。

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

# 各サイドカーに適用された healthCheck 設定
terraform output effective_health_check

# コンテナごとの healthStatus / lastStatus
aws ecs describe-tasks --region ap-northeast-1 \
  --cluster cwagent-sidecar-test \
  --tasks "$(aws ecs list-tasks --region ap-northeast-1 \
      --cluster cwagent-sidecar-test --service-name cwagent-sidecar-test \
      --query 'taskArns[0]' --output text)" \
  --query 'tasks[0].{taskHealth:healthStatus,containers:containers[].{name:name,last:lastStatus,health:healthStatus,reason:reason}}' \
  --output table

# 転送されたログ
aws logs tail /ecs/cwagent-sidecar-test --region ap-northeast-1 --follow
```

ログストリームの内訳:

| ストリーム | 中身 |
| --- | --- |
| `app/<hostname>` | CloudWatch Agent が転送したアプリのログファイル |
| `cwagent/...` | CloudWatch Agent の標準出力（awslogs ドライバ） |
| `adot/...` | ADOT Collector の標準出力（awslogs ドライバ） |
| `app-stdout/...` | アプリの標準出力（awslogs ドライバ） |

`app/<hostname>` に行が届いていればサイドカー経由の転送が成功しています。
ADOT は OTLP の送信元が無い状態でも正常起動し、`health_check` は成功します
（起動ログは `adot/...` ストリームで確認できます）。

## 検証シナリオ

すべて変数の変更 → `terraform apply` だけで切り替えられます。

### 1. サイドカーを 1 本ずつ切り分ける

```hcl
enable_cwagent_sidecar = true
enable_adot_sidecar    = false   # CloudWatch Agent だけを検証
```

```hcl
enable_cwagent_sidecar = false
enable_adot_sidecar    = true    # ADOT だけを検証
```

`terraform output container_names` で、実際にタスクへ載ったコンテナと
`app` の `dependsOn` の対象を確認できます。

### 2. ヘルスチェックコマンドの妥当性を確かめる

**CloudWatch Agent** はイメージに何が入っているかで使えるコマンドが変わるため、
コンテナに入って手で叩くのが確実です。

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

うまくいったものを `cwagent_health_check_command` に設定してください
（候補は `terraform.tfvars.example` の A〜D を参照）。

**ADOT** はシェルが無いため ECS Exec でシェルに入れません。
`/healthcheck` の成否は `describe-tasks` の `healthStatus` と、
`adot/...` ストリームの起動ログ（`health_check` extension が
13133 で待ち受けているか）で判断します。

ECS 側の挙動だけを見たい場合は、常に成功／常に失敗するコマンドが手っ取り早いです。

```hcl
cwagent_health_check_command = ["CMD-SHELL", "exit 0"]
adot_health_check_command    = ["CMD", "/healthcheck"]
```

### 3. UNHEALTHY 時の挙動（essential の効き方）

サイドカーごとに独立して強制 UNHEALTHY にできます。

```hcl
cwagent_simulate_unhealthy = true
cwagent_essential          = true   # → タスクごと停止して再起動を繰り返す
```

```hcl
adot_simulate_unhealthy = true
adot_essential          = false  # → ADOT だけ停止、他のコンテナは動き続ける
```

停止理由はサービスイベントに出ます。

```bash
aws ecs describe-services --region ap-northeast-1 \
  --cluster cwagent-sidecar-test --services cwagent-sidecar-test \
  --query 'services[0].events[:10].message' --output table
```

### 4. dependsOn (condition = HEALTHY) の待ち合わせ

```hcl
app_depends_on_sidecar_healthy = true
adot_simulate_unhealthy        = true
```

ADOT が HEALTHY にならないため `app` は `PENDING` のまま起動しません
（`dependsOn` は有効化した全サイドカーに対して張られます）。
`false` にすると待ち合わせなしで全コンテナが同時に起動します。

### 5. startPeriod / interval / retries の効き方

`*_health_check_start_period` を長くすると、その間の失敗は
`retries` にカウントされず UNHEALTHY 判定が遅れることを確認できます。
`interval × retries` が UNHEALTHY 判定までの実質的な時間になります。
2 本のサイドカーで別々の値を設定すれば、判定タイミングの差も比較できます。

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
- `cwagent_image` / `adot_image` は `:latest` を既定にしています。
  再現性が必要な検証ではタグを固定してください。
- タスクサイズの既定は 512 CPU / 1024 MiB です。サイドカーを 1 本に絞る場合は
  `task_cpu` / `task_memory` を下げられます。
- ADOT で X-Ray なども使う場合は
  `additional_task_policy_arns = ["arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"]`
  のようにタスクロールへポリシーを追加できます。
