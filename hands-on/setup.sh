#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Amazon S3 Files ハンズオンの事前準備
# S3 Files そのものの操作（ファイルシステム・同期の設定・マウントターゲットの作成、マウント）は、
# README の手順で 1 コマンドずつ実行します。このスクリプトは、その前提になる次のものだけを作成します。
#   1. S3 バケット                         … ファイルシステムとしてマウントするバケット。バージョニングを有効にする
#   2. 同期用ロール                         … S3 Files が引き受け、バケットの読み書きと EventBridge のルールの管理に使う
#   3. EC2 用ロールとインスタンスプロファイル … EC2 の中のプロキシ・マウントヘルパーと Session Manager が使う
#   4. セキュリティグループ 2 つ             … クライアントの EC2 用と、マウントターゲット用（TCP 2049）
#   5. EC2 インスタンス 1 台                 … t3.micro、Amazon Linux 2023。CPU クレジットは standard。起動から 4 時間で自動で終了する
# あわせて、ロググループ /aws/efs/utils がもとからあるかを記録します（cleanup.sh が、もとからあるロググループを消さないため）。

readonly PROJECT_NAME="aws-deepcuts"
readonly REGION="${DEEPCUTS_REGION:-ap-northeast-1}"
readonly INSTANCE_TYPE="t3.micro"
readonly AUTO_TERMINATE_MINUTES="${DEEPCUTS_EC2_MINUTES:-240}"
# AWS のサンプルの EC2 の例と同じ、x86_64 の Amazon Linux 2023
readonly AMI_PARAM="resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
readonly SYNC_ROLE_NAME="${PROJECT_NAME}-s3files-sync-role"
readonly EC2_ROLE_NAME="${PROJECT_NAME}-s3files-ec2-role"
readonly INSTANCE_PROFILE_NAME="${PROJECT_NAME}-s3files-ec2-profile"
readonly EC2_POLICY_NAME="${PROJECT_NAME}-s3files-client"
readonly CLIENT_SG_NAME="${PROJECT_NAME}-s3files-client-sg"
readonly MT_SG_NAME="${PROJECT_NAME}-s3files-mount-target-sg"
readonly INSTANCE_NAME="${PROJECT_NAME}-s3files-client"
readonly EFS_UTILS_LOG_GROUP="/aws/efs/utils"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"

# まだ何も作成していない段階で止まるときは、resource-ids.env も消して、setup.sh をそのままやり直せるようにする
fail_before_create() {
  rm -f "${RESOURCE_FILE}"
  exit 1
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Amazon S3 Files 事前準備"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/8] 前提の確認 ─────────────────────────────────────────
echo "[1/8] 前提を確認..."
if [[ -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が既に存在します。前回の環境が残っています。" >&2
  echo "   先に bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
if ! aws s3files list-file-systems --generate-cli-skeleton input >/dev/null 2>&1; then
  echo "❌ Error: この AWS CLI は s3files コマンドに対応していません（2.34.26 以降が必要です）。" >&2
  echo "   現在のバージョン: $(aws --version 2>&1)" >&2
  echo "   README の「前提条件」の手順で、ホームディレクトリに最新版の AWS CLI をインストールしてください。" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "❌ Error: python3 コマンドが見つかりません。" >&2; exit 1; }
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "❌ Error: AWS の認証情報を取得できません。CloudShell で実行しているか確認してください。" >&2
  exit 1
}
# このリージョンで S3 Files の API を呼び出せるかを確かめる（公式の提供リージョンの一覧は README で確かめていないため）
if ! aws s3files list-file-systems --region "${REGION}" --max-results 1 >/dev/null 2>&1; then
  echo "❌ Error: ${REGION} で S3 Files の API を呼び出せませんでした。" >&2
  echo "   このリージョンで S3 Files を使えないか、権限が足りない可能性があります。" >&2
  echo "   別のリージョンで試す場合は、DEEPCUTS_REGION=<リージョン> bash ./setup.sh のように実行してください。" >&2
  exit 1
fi
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION}"

# 作成したリソースは、作成した直後に resource-ids.env へ書き足す。
# 途中で失敗しても、cleanup.sh がこのファイルを読んで、作成済みのリソースを削除できるようにするため。
cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts Amazon S3 Files - リソース情報（setup.sh が作成。README の手順で行を追記します）
REGION="${REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
SYNC_ROLE_NAME="${SYNC_ROLE_NAME}"
EC2_ROLE_NAME="${EC2_ROLE_NAME}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME}"
EC2_POLICY_NAME="${EC2_POLICY_NAME}"
CLIENT_SG_NAME="${CLIENT_SG_NAME}"
MT_SG_NAME="${MT_SG_NAME}"
EOF
echo "  リソース情報の保存先: ${RESOURCE_FILE}"
echo ""

# ─── [2/8] 既定の VPC とサブネット ─────────────────────────────
echo "[2/8] 既定の VPC と、EC2 を起動するサブネットを確認..."
VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  echo "❌ Error: ${REGION} に既定の VPC が見つかりません。" >&2
  echo "   aws ec2 create-default-vpc --region ${REGION} で作成してから、bash ./setup.sh をやり直してください。" >&2
  fail_before_create
fi
DNS_SUPPORT=$(aws ec2 describe-vpc-attribute --region "${REGION}" --vpc-id "${VPC_ID}" \
  --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text)
DNS_HOSTNAMES=$(aws ec2 describe-vpc-attribute --region "${REGION}" --vpc-id "${VPC_ID}" \
  --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text)
if [[ "${DNS_SUPPORT}" != "True" || "${DNS_HOSTNAMES}" != "True" ]]; then
  echo "❌ Error: 既定の VPC ${VPC_ID} で、DNS 解決と DNS ホスト名の両方が有効になっていません。" >&2
  echo "   DNS 解決: ${DNS_SUPPORT} / DNS ホスト名: ${DNS_HOSTNAMES}" >&2
  echo "   S3 Files のマウントには、両方が有効であることが必要です。README のトラブルシューティングを確認してください。" >&2
  fail_before_create
fi
# t3.micro を提供している AZ のうち、既定のサブネットがある最初の AZ を選ぶ
OFFERED_AZS=$(aws ec2 describe-instance-type-offerings --region "${REGION}" \
  --location-type availability-zone --filters "Name=instance-type,Values=${INSTANCE_TYPE}" \
  --query 'InstanceTypeOfferings[].Location' --output text)
SUBNET_ID=""
AZ_NAME=""
for AZ in $(echo "${OFFERED_AZS}" | tr '\t' '\n' | sort); do
  CANDIDATE=$(aws ec2 describe-subnets --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" Name=default-for-az,Values=true "Name=availability-zone,Values=${AZ}" \
    --query 'Subnets[0].SubnetId' --output text)
  if [[ -n "${CANDIDATE}" && "${CANDIDATE}" != "None" ]]; then
    SUBNET_ID="${CANDIDATE}"
    AZ_NAME="${AZ}"
    break
  fi
done
if [[ -z "${SUBNET_ID}" ]]; then
  echo "❌ Error: ${INSTANCE_TYPE} を起動できる既定のサブネットが見つかりません。" >&2
  fail_before_create
fi
{
  echo "VPC_ID=\"${VPC_ID}\""
  echo "SUBNET_ID=\"${SUBNET_ID}\""
  echo "AZ_NAME=\"${AZ_NAME}\""
} >> "${RESOURCE_FILE}"
echo "  VPC: ${VPC_ID} / サブネット: ${SUBNET_ID} / AZ: ${AZ_NAME}"
echo ""

# ─── [3/8] S3 バケット ─────────────────────────────────────────
echo "[3/8] ファイルシステムとしてマウントする S3 バケットを作成..."
BUCKET_NAME="${PROJECT_NAME}-s3files-${ACCOUNT_ID}-$(date +%Y%m%d-%H%M%S)"
if [[ "${REGION}" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" >/dev/null
else
  aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
    --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
fi
echo "BUCKET_NAME=\"${BUCKET_NAME}\"" >> "${RESOURCE_FILE}"
aws s3api put-public-access-block --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
# AWS のサンプルが前提条件に挙げているため、バージョニングを有効にする。
# 手順 7 で、古い版と削除マーカーを確かめるためにも使う。
aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --versioning-configuration Status=Enabled
echo "  作成: s3://${BUCKET_NAME}（バージョニング有効）"
echo ""

# ─── [4/8] 同期用ロール ─────────────────────────────────────────
echo "[4/8] 同期用ロールを作成..."
# 信頼ポリシーは、AWS のサンプル（sample-code-for-deploying-s3-files-with-terraform の environments/dev/main.tf）と同じ。
# プリンシパルは s3files.amazonaws.com ではなく elasticfilesystem.amazonaws.com。
SYNC_TRUST_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{
    \"Effect\": \"Allow\",
    \"Principal\": {\"Service\": \"elasticfilesystem.amazonaws.com\"},
    \"Action\": \"sts:AssumeRole\",
    \"Condition\": {
      \"StringEquals\": {\"aws:SourceAccount\": \"${ACCOUNT_ID}\"},
      \"ArnLike\": {\"aws:SourceArn\": \"arn:aws:s3files:${REGION}:${ACCOUNT_ID}:file-system/*\"}
    }
  }]
}"
if aws iam get-role --role-name "${SYNC_ROLE_NAME}" >/dev/null 2>&1; then
  echo "  既に存在するため、信頼ポリシーを更新して使います: ${SYNC_ROLE_NAME}"
  aws iam update-assume-role-policy --role-name "${SYNC_ROLE_NAME}" --policy-document "${SYNC_TRUST_POLICY}"
else
  aws iam create-role --role-name "${SYNC_ROLE_NAME}" \
    --description "AWS Deep Cuts Amazon S3 Files hands-on (synchronization role)" \
    --tags "Key=Project,Value=${PROJECT_NAME}" \
    --assume-role-policy-document "${SYNC_TRUST_POLICY}" >/dev/null
  echo "  作成: ${SYNC_ROLE_NAME}"
fi
# インラインポリシーの名前と中身は、AWS のサンプルと同じ（バケットの ARN・リージョン・アカウント ID だけを入れ替える）
aws iam put-role-policy --role-name "${SYNC_ROLE_NAME}" --policy-name s3-access \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"BucketAccess\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:ListBucket*\"],
        \"Resource\": [\"arn:aws:s3:::${BUCKET_NAME}\"]
      },
      {
        \"Sid\": \"ObjectAccess\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:AbortMultipartUpload\", \"s3:DeleteObject*\", \"s3:GetObject*\", \"s3:List*\", \"s3:PutObject*\"],
        \"Resource\": [\"arn:aws:s3:::${BUCKET_NAME}/*\"]
      }
    ]
  }"
aws iam put-role-policy --role-name "${SYNC_ROLE_NAME}" --policy-name eventbridge-access \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"EventBridgeManage\",
        \"Effect\": \"Allow\",
        \"Action\": [\"events:DeleteRule\", \"events:DisableRule\", \"events:EnableRule\", \"events:PutRule\", \"events:PutTargets\", \"events:RemoveTargets\"],
        \"Resource\": [\"arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/DO-NOT-DELETE-S3-Files*\"],
        \"Condition\": {\"StringEquals\": {\"events:ManagedBy\": \"elasticfilesystem.amazonaws.com\"}}
      },
      {
        \"Sid\": \"EventBridgeRead\",
        \"Effect\": \"Allow\",
        \"Action\": [\"events:DescribeRule\", \"events:ListRuleNamesByTarget\", \"events:ListRules\", \"events:ListTargetsByRule\"],
        \"Resource\": [\"arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/*\"]
      }
    ]
  }"
SYNC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SYNC_ROLE_NAME}"
echo "SYNC_ROLE_ARN=\"${SYNC_ROLE_ARN}\"" >> "${RESOURCE_FILE}"
echo "  インラインポリシー: s3-access、eventbridge-access"
echo ""

# ─── [5/8] EC2 用ロールとインスタンスプロファイル ─────────────────
echo "[5/8] EC2 用ロールとインスタンスプロファイルを作成..."
EC2_TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'
if aws iam get-role --role-name "${EC2_ROLE_NAME}" >/dev/null 2>&1; then
  echo "  既に存在するため、そのまま使います: ${EC2_ROLE_NAME}"
else
  aws iam create-role --role-name "${EC2_ROLE_NAME}" \
    --description "AWS Deep Cuts Amazon S3 Files hands-on (EC2 client role)" \
    --tags "Key=Project,Value=${PROJECT_NAME}" \
    --assume-role-policy-document "${EC2_TRUST_POLICY}" >/dev/null
  echo "  作成: ${EC2_ROLE_NAME}"
fi
# S3FilesClient: マウント・書き込み・ルートとしてのアクセス（AWS のサンプルの EC2 用と同じアクション）。
#   ファイルシステムの ID が決まる前に作成するため、このアカウントとリージョンのファイルシステム全体を対象にする。
# DirectRead:     大きなオブジェクトをバケットから直接読むため、と、プロキシがバケットへの接続を確かめるため。
# PublishMetrics: プロキシが efs-utils/S3Files と efs-utils/EFS の 2 つの名前空間にメトリクスを送るため。
# PublishLogs:    マウントヘルパーとプロキシが、ロググループ /aws/efs/utils にログを送るため。
aws iam put-role-policy --role-name "${EC2_ROLE_NAME}" --policy-name "${EC2_POLICY_NAME}" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"S3FilesClient\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3files:ClientMount\", \"s3files:ClientWrite\", \"s3files:ClientRootAccess\", \"s3files:GetFileSystem\", \"s3files:GetMountTarget\"],
        \"Resource\": \"arn:aws:s3files:${REGION}:${ACCOUNT_ID}:file-system/*\"
      },
      {
        \"Sid\": \"DirectRead\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:GetObjectVersion\", \"s3:ListBucket\"],
        \"Resource\": [\"arn:aws:s3:::${BUCKET_NAME}\", \"arn:aws:s3:::${BUCKET_NAME}/*\"]
      },
      {
        \"Sid\": \"PublishMetrics\",
        \"Effect\": \"Allow\",
        \"Action\": \"cloudwatch:PutMetricData\",
        \"Resource\": \"*\",
        \"Condition\": {\"StringEquals\": {\"cloudwatch:namespace\": [\"efs-utils/S3Files\", \"efs-utils/EFS\"]}}
      },
      {
        \"Sid\": \"PublishLogs\",
        \"Effect\": \"Allow\",
        \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutRetentionPolicy\", \"logs:PutLogEvents\", \"logs:DescribeLogStreams\"],
        \"Resource\": [
          \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${EFS_UTILS_LOG_GROUP}\",
          \"arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${EFS_UTILS_LOG_GROUP}:*\"
        ]
      }
    ]
  }"
# AmazonSSMManagedInstanceCore は、AWS のサンプルの EC2 の例と同じ（Session Manager で接続するため）。
# AmazonElasticFileSystemsUtils は、EFS CSI ドライバーの文書が、efs-utils のログを CloudWatch に送るためのものとして挙げている管理ポリシー。
# AmazonElasticFileSystemsUtils の中身は確かめていないため、ログとメトリクスに要る権限は上のインラインポリシーに明示している。
for POLICY_ARN in arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore arn:aws:iam::aws:policy/AmazonElasticFileSystemsUtils; do
  aws iam attach-role-policy --role-name "${EC2_ROLE_NAME}" --policy-arn "${POLICY_ARN}"
done
if aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  echo "  既に存在するため、そのまま使います: ${INSTANCE_PROFILE_NAME}"
else
  aws iam create-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --tags "Key=Project,Value=${PROJECT_NAME}" >/dev/null
  echo "  作成: ${INSTANCE_PROFILE_NAME}"
fi
ROLES_IN_PROFILE=$(aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
  --query 'InstanceProfile.Roles[].RoleName' --output text)
if [[ "${ROLES_IN_PROFILE}" != *"${EC2_ROLE_NAME}"* ]]; then
  aws iam add-role-to-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" --role-name "${EC2_ROLE_NAME}"
fi
echo "  インラインポリシー: ${EC2_POLICY_NAME}"
echo "  管理ポリシー: AmazonSSMManagedInstanceCore、AmazonElasticFileSystemsUtils"
echo ""

# ─── [6/8] セキュリティグループ ─────────────────────────────────
echo "[6/8] セキュリティグループを作成..."
find_or_create_sg() {
  local name="$1" description="$2" sg_id
  sg_id=$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${name}" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [[ -z "${sg_id}" || "${sg_id}" == "None" ]]; then
    sg_id=$(aws ec2 create-security-group --region "${REGION}" --vpc-id "${VPC_ID}" \
      --group-name "${name}" --description "${description}" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT_NAME}}]" \
      --query GroupId --output text)
  fi
  echo "${sg_id}"
}
# クライアント用: 受信の規則は無い。送信は、作成時の既定の規則ですべて許可される
CLIENT_SG_ID=$(find_or_create_sg "${CLIENT_SG_NAME}" "AWS Deep Cuts S3 Files client (EC2)")
echo "CLIENT_SG_ID=\"${CLIENT_SG_ID}\"" >> "${RESOURCE_FILE}"
# マウントターゲット用: TCP 2049（NFS）の受信を、クライアント用のセキュリティグループからだけ許可する
MT_SG_ID=$(find_or_create_sg "${MT_SG_NAME}" "AWS Deep Cuts S3 Files mount target (NFS 2049 from client SG)")
echo "MT_SG_ID=\"${MT_SG_ID}\"" >> "${RESOURCE_FILE}"
if ! INGRESS_OUT=$(aws ec2 authorize-security-group-ingress --region "${REGION}" --group-id "${MT_SG_ID}" \
     --protocol tcp --port 2049 --source-group "${CLIENT_SG_ID}" 2>&1); then
  if [[ "${INGRESS_OUT}" == *"InvalidPermission.Duplicate"* ]]; then
    echo "  TCP 2049 の受信の規則は既にあります"
  else
    echo "${INGRESS_OUT}" >&2
    exit 1
  fi
fi
echo "  クライアント用:           ${CLIENT_SG_NAME}（${CLIENT_SG_ID}）"
echo "  マウントターゲット用:     ${MT_SG_NAME}（${MT_SG_ID}）TCP 2049 をクライアント用から許可"
echo ""

# ─── [7/8] ロググループの有無の記録 ─────────────────────────────
echo "[7/8] ロググループ ${EFS_UTILS_LOG_GROUP} がもとからあるかを確認..."
LOG_GROUP_COUNT=$(aws logs describe-log-groups --region "${REGION}" --log-group-name-prefix "${EFS_UTILS_LOG_GROUP}" \
  --query "length(logGroups[?logGroupName=='${EFS_UTILS_LOG_GROUP}'])" --output text)
if [[ "${LOG_GROUP_COUNT}" =~ ^[1-9] ]]; then
  EFS_UTILS_LOG_GROUP_EXISTED="true"
  echo "  もとからあります。cleanup.sh は、このハンズオンの EC2 のログストリームだけを削除します"
else
  EFS_UTILS_LOG_GROUP_EXISTED="false"
  echo "  ありません。手順 6 のマウントで作成されます。cleanup.sh は、このハンズオンの EC2 のログストリームを削除し、ロググループが空になればロググループも削除します"
fi
echo "EFS_UTILS_LOG_GROUP_EXISTED=\"${EFS_UTILS_LOG_GROUP_EXISTED}\"" >> "${RESOURCE_FILE}"
echo ""

# ─── [8/8] EC2 インスタンス ─────────────────────────────────────
echo "[8/8] EC2 インスタンスを起動..."
echo "  IAM の反映を待機（10 秒）..."
sleep 10
# 消し忘れたときの費用の上限を決めるため、起動から AUTO_TERMINATE_MINUTES 分で OS をシャットダウンする。
# --instance-initiated-shutdown-behavior terminate により、OS のシャットダウンでインスタンスが終了する。
# T3 の CPU クレジットの方式は既定で unlimited のため、standard を指定して、余剰の CPU クレジットの料金がかからないようにする。
USER_DATA="#!/bin/bash
shutdown -h +${AUTO_TERMINATE_MINUTES}"
INSTANCE_ID=""
RUN_ERR=$(mktemp)
for ATTEMPT in 1 2 3 4 5 6; do
  if RUN_OUT=$(aws ec2 run-instances --region "${REGION}" \
       --image-id "${AMI_PARAM}" \
       --instance-type "${INSTANCE_TYPE}" \
       --credit-specification CpuCredits=standard \
       --count 1 \
       --subnet-id "${SUBNET_ID}" \
       --security-group-ids "${CLIENT_SG_ID}" \
       --associate-public-ip-address \
       --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
       --metadata-options HttpTokens=required,HttpEndpoint=enabled \
       --instance-initiated-shutdown-behavior terminate \
       --user-data "${USER_DATA}" \
       --tag-specifications \
         "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_NAME}}]" \
         "ResourceType=volume,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_NAME}}]" \
       --query 'Instances[0].InstanceId' --output text 2>"${RUN_ERR}"); then
    INSTANCE_ID="${RUN_OUT}"
    break
  fi
  # 作成した直後のインスタンスプロファイルは、EC2 から使えるようになるまで時間がかかることがある
  if grep -q "InvalidParameterValue" "${RUN_ERR}" && [[ "${ATTEMPT}" -lt 6 ]]; then
    echo "  インスタンスプロファイルの反映を待って再試行します（${ATTEMPT}/6）..."
    sleep 10
    continue
  fi
  cat "${RUN_ERR}" >&2
  rm -f "${RUN_ERR}"
  exit 1
done
rm -f "${RUN_ERR}"
if [[ "${INSTANCE_ID}" != i-* ]]; then
  echo "❌ Error: EC2 インスタンスの ID を取得できませんでした: ${INSTANCE_ID}" >&2
  exit 1
fi
echo "INSTANCE_ID=\"${INSTANCE_ID}\"" >> "${RESOURCE_FILE}"
echo "  起動: ${INSTANCE_ID}（${INSTANCE_TYPE}、${AZ_NAME}）"
aws ec2 wait instance-running --region "${REGION}" --instance-ids "${INSTANCE_ID}"
echo "  状態: running"
VOLUME_INFO=$(aws ec2 describe-volumes --region "${REGION}" \
  --filters "Name=attachment.instance-id,Values=${INSTANCE_ID}" \
  --query 'Volumes[0].[Size, VolumeType]' --output text | tr '\t' ' ')
echo "  ルートボリューム（GB と種類）: ${VOLUME_INFO}"
echo "  Session Manager に登録されるのを待機（最長 5 分）..."
PING_STATUS="None"
for _ in $(seq 1 20); do
  PING_STATUS=$(aws ssm describe-instance-information --region "${REGION}" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  [[ "${PING_STATUS}" == "Online" ]] && break
  sleep 15
done
if [[ "${PING_STATUS}" == "Online" ]]; then
  echo "  Session Manager: Online"
else
  echo "  Session Manager: まだ登録されていません。手順 6 で「接続」が押せない場合は、数分待ってください"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "EC2 インスタンスは、起動から ${AUTO_TERMINATE_MINUTES} 分で自動で終了します。"
echo ""
echo "作成したリソースは、マネジメントコンソールの次の画面で確認できます。"
echo "  IAM ロール:    https://us-east-1.console.aws.amazon.com/iam/home#/roles/details/${SYNC_ROLE_NAME}"
echo "                 https://us-east-1.console.aws.amazon.com/iam/home#/roles/details/${EC2_ROLE_NAME}"
echo "  S3 バケット:   https://${REGION}.console.aws.amazon.com/s3/buckets/${BUCKET_NAME}?region=${REGION}"
echo "  EC2:           https://${REGION}.console.aws.amazon.com/ec2/home?region=${REGION}#InstanceDetails:instanceId=${INSTANCE_ID}"
echo ""
echo "次のステップ: README の手順 1 に戻り、次のコマンドで変数を読み込んでください。"
echo "  source ./resource-ids.env"
