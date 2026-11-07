#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Amazon S3 Files ハンズオンの後片付け
# 手順の中で作成した S3 Files のリソース（アクセスポイント・マウントターゲット・ファイルシステム）と、
# setup.sh が作成したリソースを、すべて削除します。
# S3 Files のリソースは、resource-ids.env の FS_ID の有無にかかわらず、バケットに結び付いたものをすべて探して削除します。
# 手順 3 をやり直してファイルシステムが 2 つ以上作成された場合も、消し残さないようにするためです。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
readonly EFS_UTILS_LOG_GROUP="/aws/efs/utils"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Amazon S3 Files 後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が見つかりません。" >&2
  echo "   setup.sh を実行したディレクトリ（hands-on）で実行してください。" >&2
  exit 1
fi
if ! aws s3files list-file-systems --generate-cli-skeleton input >/dev/null 2>&1; then
  echo "❌ Error: この AWS CLI は s3files コマンドに対応していません。" >&2
  echo "   前提条件で AWS CLI をホームディレクトリにインストールした場合は、" >&2
  echo "   export PATH=\"\$HOME/.local/bin:\$PATH\" を実行してから、もう一度実行してください。" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"
REGION="${REGION:-ap-northeast-1}"
BUCKET_NAME="${BUCKET_NAME:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
BUCKET_ARN=""
[[ -n "${BUCKET_NAME}" ]] && BUCKET_ARN="arn:aws:s3:::${BUCKET_NAME}"

# バケットに結び付いた、削除済みでないファイルシステムをすべて探す
FS_IDS=""
if [[ -n "${BUCKET_ARN}" ]]; then
  FS_IDS=$(aws s3files list-file-systems --region "${REGION}" --bucket "${BUCKET_ARN}" \
    --query "fileSystems[?status!='deleted'].fileSystemId" --output text 2>/dev/null || true)
  [[ "${FS_IDS}" == "None" ]] && FS_IDS=""
  # resource-ids.env の FS_ID も対象に加え、重複を除く
  FS_IDS=$({ echo "${FS_IDS}" | tr ' \t' '\n'; echo "${FS_ID:-}"; } | grep '^fs-' | sort -u | tr '\n' ' ' || true)
fi

# ─── [1/9] EC2 の終了 ─────────────────────────────────────────
echo "[1/9] EC2 インスタンスを終了..."
if [[ -n "${INSTANCE_ID}" ]]; then
  STATE=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "unknown")
  if [[ "${STATE}" == "terminated" ]]; then
    echo "  既に終了しています: ${INSTANCE_ID}（起動から 4 時間の自動終了を含む）"
  else
    aws ec2 terminate-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
    echo "  終了を依頼しました: ${INSTANCE_ID}。終了を待機..."
    aws ec2 wait instance-terminated --region "${REGION}" --instance-ids "${INSTANCE_ID}" 2>/dev/null \
      || echo "  ⚠️  終了の確認が時間内に終わりませんでした。後の段で、もう一度確かめます"
    echo "  終了: ${INSTANCE_ID}（マウントは EC2 の終了で外れます）"
  fi
else
  echo "  対象なし"
fi
echo ""

# ─── [2/9] アクセスポイント ─────────────────────────────────────
echo "[2/9] S3 Files のアクセスポイントを削除..."
if [[ -z "${FS_IDS// /}" ]]; then
  echo "  対象なし"
else
  FOUND_AP=""
  for FS in ${FS_IDS}; do
    AP_IDS=$(aws s3files list-access-points --region "${REGION}" --file-system-id "${FS}" \
      --query 'accessPoints[].accessPointId' --output text 2>/dev/null || true)
    [[ "${AP_IDS}" == "None" ]] && AP_IDS=""
    for AP in ${AP_IDS}; do
      FOUND_AP="yes"
      if aws s3files delete-access-point --region "${REGION}" --access-point-id "${AP}" >/dev/null 2>&1; then
        echo "  削除を依頼: ${AP}（${FS}）"
      else
        echo "  ⚠️  削除できませんでした: ${AP}（${FS}）" >&2
      fi
    done
  done
  [[ -z "${FOUND_AP}" ]] && echo "  対象なし"
fi
echo ""

# ─── [3/9] マウントターゲット ───────────────────────────────────
echo "[3/9] マウントターゲットを削除..."
if [[ -z "${FS_IDS// /}" ]]; then
  echo "  対象なし"
else
  for FS in ${FS_IDS}; do
    MT_IDS=$(aws s3files list-mount-targets --region "${REGION}" --file-system-id "${FS}" \
      --query "mountTargets[?status!='deleting' && status!='deleted'].mountTargetId" --output text 2>/dev/null || true)
    [[ "${MT_IDS}" == "None" ]] && MT_IDS=""
    for MT in ${MT_IDS}; do
      if aws s3files delete-mount-target --region "${REGION}" --mount-target-id "${MT}" >/dev/null 2>&1; then
        echo "  削除を依頼: ${MT}（${FS}）"
      else
        echo "  ⚠️  削除を依頼できませんでした: ${MT}（${FS}）" >&2
      fi
    done
  done
  # S3 Files には待機のコマンドが無いため、すべてのファイルシステムでマウントターゲットが無くなるまで、15 秒おきに最長 10 分待つ
  echo "  マウントターゲットが無くなるのを待機（最長 10 分）..."
  for _ in $(seq 1 40); do
    REMAINING=0
    for FS in ${FS_IDS}; do
      COUNT=$(aws s3files list-mount-targets --region "${REGION}" --file-system-id "${FS}" \
        --query "length(mountTargets[?status!='deleted'])" --output text 2>/dev/null || echo 0)
      [[ "${COUNT}" =~ ^[0-9]+$ ]] || COUNT=0
      REMAINING=$((REMAINING + COUNT))
    done
    [[ "${REMAINING}" -eq 0 ]] && break
    echo "    $(date +%H:%M:%S) 残り ${REMAINING} 個"
    sleep 15
  done
  echo "  完了"
fi
echo ""

# ─── [4/9] ファイルシステム ─────────────────────────────────────
echo "[4/9] ファイルシステムを削除..."
if [[ -z "${FS_IDS// /}" ]]; then
  echo "  対象なし"
else
  for FS in ${FS_IDS}; do
    # cleanup.sh を再実行したときに、削除済みや削除中のファイルシステムで再試行を繰り返さないため、先に状態を確かめる
    # （見つからない場合は、削除済みとして扱う）
    FS_STATUS=$(aws s3files get-file-system --region "${REGION}" --file-system-id "${FS}" \
      --query status --output text 2>/dev/null || echo "deleted")
    if [[ "${FS_STATUS}" == "deleted" || "${FS_STATUS}" == "deleting" ]]; then
      echo "  既に削除済みか削除中です: ${FS}（${FS_STATUS}）"
      continue
    fi
    DELETED=""
    # 書き出し待ちのデータ（まだバケットに書き出していない変更）が残っていると、削除は既定で失敗する
    # （ConflictException の「has data pending export to S3」）。
    # 2026 年 11 月の検証では、手順 8 の後に約 2 分待ってから実行しても、5 分以上この状態が続き、
    # 再試行では削除できなかった。そのため、再試行は 30 秒おきに 4 回（約 2 分）にとどめ、早めに --force-delete に移る。
    for ATTEMPT in $(seq 1 4); do
      if DELETE_ERR=$(aws s3files delete-file-system --region "${REGION}" --file-system-id "${FS}" 2>&1 >/dev/null); then
        DELETED="yes"
        break
      fi
      if [[ "${DELETE_ERR}" == *"pending export"* ]]; then
        echo "    書き出し待ちのデータがあるため、削除できませんでした。書き出しを待って再試行します（${ATTEMPT}/4）..."
      else
        echo "    削除できませんでした。再試行します（${ATTEMPT}/4）..."
      fi
      sleep 30
    done
    if [[ -z "${DELETED}" ]]; then
      # --force-delete は、書き出し待ちのデータ（バケットにまだ書き出していない変更）を失う。
      # このハンズオンのデータは、この後バケットごと削除するため、ここでは使う。
      echo "  書き出し待ちのデータは失われますが、このハンズオンのデータはこの後バケットごと削除するため、"
      echo "  --force-delete で削除します: ${FS}"
      if aws s3files delete-file-system --region "${REGION}" --file-system-id "${FS}" --force-delete >/dev/null 2>&1; then
        DELETED="yes"
      fi
    fi
    if [[ -n "${DELETED}" ]]; then
      echo "  削除を依頼: ${FS}"
    else
      echo "  ⚠️  削除を依頼できませんでした: ${FS}" >&2
    fi
  done
  echo "  ファイルシステムの削除の完了を待機（最長 10 分）..."
  for _ in $(seq 1 40); do
    REMAINING=0
    for FS in ${FS_IDS}; do
      # 見つからない（ResourceNotFoundException）場合は、削除済みとして扱う
      STATUS=$(aws s3files get-file-system --region "${REGION}" --file-system-id "${FS}" \
        --query status --output text 2>/dev/null || echo "deleted")
      [[ "${STATUS}" == "deleted" ]] || REMAINING=$((REMAINING + 1))
    done
    [[ "${REMAINING}" -eq 0 ]] && break
    echo "    $(date +%H:%M:%S) 残り ${REMAINING} 個"
    sleep 15
  done
  echo "  完了"
fi
echo ""

# ─── [5/9] EventBridge のルールの確認 ───────────────────────────
echo "[5/9] S3 Files が管理する EventBridge のルールを確認（削除はしません）..."
# 他のファイルシステムが使っているルールを消さないため、このスクリプトでは削除しない。
RULES=$(aws events list-rules --region "${REGION}" --name-prefix DO-NOT-DELETE-S3-Files \
  --query 'Rules[].Name' --output text 2>/dev/null || true)
if [[ -z "${RULES}" || "${RULES}" == "None" ]]; then
  echo "  名前が DO-NOT-DELETE-S3-Files で始まるルールはありません"
else
  aws events list-rules --region "${REGION}" --name-prefix DO-NOT-DELETE-S3-Files \
    --query 'Rules[].[Name, ManagedBy, State]' --output table
  echo "  S3 Files が管理するルールです。30 分ほどたっても残る場合は、"
  echo "  README のトラブルシューティングの「EventBridge のルールが残る場合」を確認してください。"
fi
echo ""

# ─── [6/9] CloudWatch Logs ─────────────────────────────────────
echo "[6/9] マウントヘルパーとプロキシのログを削除..."
if [[ -z "${INSTANCE_ID}" || -z "${EFS_UTILS_LOG_GROUP_EXISTED:-}" ]]; then
  echo "  EC2 を起動していないため、ロググループには触れません"
else
  # 名前にこの EC2 のインスタンス ID を含むログストリームだけを削除する
  # （マウントヘルパーの mount.log と、プロキシの 2 本）。
  # setup.sh の後に、同じアカウントとリージョンの別のクライアントがログを書き始めている場合もあるため、
  # 他のログストリームには触れない。
  STREAMS=$(aws logs describe-log-streams --region "${REGION}" --log-group-name "${EFS_UTILS_LOG_GROUP}" \
    --query "logStreams[?contains(logStreamName, '${INSTANCE_ID}')].logStreamName" --output json 2>/dev/null || echo "[]")
  COUNT=0
  while IFS= read -r STREAM; do
    [[ -z "${STREAM}" ]] && continue
    if aws logs delete-log-stream --region "${REGION}" --log-group-name "${EFS_UTILS_LOG_GROUP}" \
         --log-stream-name "${STREAM}" 2>/dev/null; then
      echo "  削除: ${STREAM}"
      COUNT=$((COUNT + 1))
    fi
  done < <(echo "${STREAMS}" | python3 -c 'import json, sys; [print(s) for s in (json.load(sys.stdin) or [])]')
  [[ "${COUNT}" -eq 0 ]] && echo "  削除するログストリームはありません"
  # ロググループがもとから無かった場合に限り、ログストリームが 1 本も残っていなければ、ロググループも削除する
  if [[ "${EFS_UTILS_LOG_GROUP_EXISTED}" == "false" ]]; then
    OTHER_STREAMS=$(aws logs describe-log-streams --region "${REGION}" --log-group-name "${EFS_UTILS_LOG_GROUP}" \
      --query 'length(logStreams)' --output text 2>/dev/null || echo "none")
    if [[ "${OTHER_STREAMS}" == "0" ]]; then
      if aws logs delete-log-group --region "${REGION}" --log-group-name "${EFS_UTILS_LOG_GROUP}" 2>/dev/null; then
        echo "  削除: ${EFS_UTILS_LOG_GROUP}（このハンズオンのマウントで作成されたロググループ）"
      fi
    elif [[ "${OTHER_STREAMS}" =~ ^[0-9]+$ ]]; then
      echo "  ${EFS_UTILS_LOG_GROUP} には、このハンズオンの外のログストリームが ${OTHER_STREAMS} 本あるため、ロググループは残します"
    else
      echo "  ${EFS_UTILS_LOG_GROUP} はありません"
    fi
  fi
fi
echo ""

# ─── [7/9] IAM ─────────────────────────────────────────────────
echo "[7/9] IAM のロールとインスタンスプロファイルを削除..."
if [[ -n "${INSTANCE_PROFILE_NAME:-}" ]]; then
  aws iam remove-role-from-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --role-name "${EC2_ROLE_NAME:-}" 2>/dev/null || true
  if aws iam delete-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" 2>/dev/null; then
    echo "  削除: ${INSTANCE_PROFILE_NAME}"
  fi
fi
if [[ -n "${EC2_ROLE_NAME:-}" ]]; then
  for POLICY_ARN in arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore arn:aws:iam::aws:policy/AmazonElasticFileSystemsUtils; do
    aws iam detach-role-policy --role-name "${EC2_ROLE_NAME}" --policy-arn "${POLICY_ARN}" 2>/dev/null || true
  done
  aws iam delete-role-policy --role-name "${EC2_ROLE_NAME}" \
    --policy-name "${EC2_POLICY_NAME:-aws-deepcuts-s3files-client}" 2>/dev/null || true
  if aws iam delete-role --role-name "${EC2_ROLE_NAME}" 2>/dev/null; then
    echo "  削除: ${EC2_ROLE_NAME}"
  fi
fi
if [[ -n "${SYNC_ROLE_NAME:-}" ]]; then
  for POLICY in s3-access eventbridge-access; do
    aws iam delete-role-policy --role-name "${SYNC_ROLE_NAME}" --policy-name "${POLICY}" 2>/dev/null || true
  done
  if aws iam delete-role --role-name "${SYNC_ROLE_NAME}" 2>/dev/null; then
    echo "  削除: ${SYNC_ROLE_NAME}"
  fi
fi
echo ""

# ─── [8/9] セキュリティグループ ─────────────────────────────────
echo "[8/9] セキュリティグループを削除..."
# マウントターゲット用はクライアント用を参照しているため、マウントターゲット用から削除する。
# ネットワークインターフェイスが解放されるまで削除できないため、15 秒おきに最長 5 分再試行する。
for SG in "${MT_SG_ID:-}" "${CLIENT_SG_ID:-}"; do
  [[ -z "${SG}" ]] && continue
  SG_DELETED=""
  for _ in $(seq 1 20); do
    if aws ec2 delete-security-group --region "${REGION}" --group-id "${SG}" >/dev/null 2>&1; then
      SG_DELETED="yes"
      break
    fi
    if ! aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SG}" >/dev/null 2>&1; then
      SG_DELETED="yes"
      break
    fi
    sleep 15
  done
  if [[ -n "${SG_DELETED}" ]]; then
    echo "  削除: ${SG}"
  else
    echo "  ⚠️  削除できませんでした: ${SG}" >&2
  fi
done
echo ""

# ─── [9/9] S3 バケット ─────────────────────────────────────────
echo "[9/9] S3 バケットのすべての版と削除マーカーを削除し、バケットを削除..."
if [[ -n "${BUCKET_NAME}" ]] && aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  DELETE_FILE=$(mktemp)
  TOTAL=0
  # delete-objects は 1 回に最大 1,000 件を削除できる。1,000 件ずつ取得して削除し、空になるまで繰り返す。
  # AWS CLI は list-object-versions のページ送りを自動で行うため、--no-paginate で 1 回の呼び出しだけにする
  while true; do
    # shellcheck disable=SC2016  # バッククォートは JMESPath のリテラルで、シェルでは展開しない
    aws s3api list-object-versions --bucket "${BUCKET_NAME}" --region "${REGION}" --no-paginate --max-keys 1000 \
      --query '{Objects: [(Versions || `[]`)[].{Key: Key, VersionId: VersionId}, (DeleteMarkers || `[]`)[].{Key: Key, VersionId: VersionId}][], Quiet: `true`}' \
      --output json > "${DELETE_FILE}"
    N=$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1])).get("Objects") or []))' "${DELETE_FILE}")
    [[ "${N}" -eq 0 ]] && break
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --region "${REGION}" \
      --delete "file://${DELETE_FILE}" >/dev/null
    TOTAL=$((TOTAL + N))
  done
  rm -f "${DELETE_FILE}"
  echo "  削除した版と削除マーカー: ${TOTAL} 件"
  if aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
    echo "  削除: s3://${BUCKET_NAME}"
  fi
else
  echo "  対象なし"
fi
# 手順 8 で CloudShell に取り出した作業用のファイル
rm -rf /tmp/demo-repo /tmp/sales.db
echo ""

# ─── 残っているリソースの確認 ───────────────────────────────────
echo "残っているリソースを確認..."
LEFT=0
if [[ -n "${BUCKET_ARN}" ]]; then
  # バケットを削除した後も、バケットの ARN でファイルシステムを問い合わせられる
  FS_LEFT=$(aws s3files list-file-systems --region "${REGION}" --bucket "${BUCKET_ARN}" \
    --query "length(fileSystems[?status!='deleted'])" --output text 2>/dev/null || echo "?")
  if [[ "${FS_LEFT}" != "0" ]]; then
    echo "  ⚠️  ファイルシステムが残っています（${FS_LEFT} 個）"; LEFT=1
  fi
fi
for FS in ${FS_IDS}; do
  MT_LEFT=$(aws s3files list-mount-targets --region "${REGION}" --file-system-id "${FS}" \
    --query "length(mountTargets[?status!='deleted'])" --output text 2>/dev/null || echo "0")
  if [[ "${MT_LEFT}" =~ ^[1-9] ]]; then
    echo "  ⚠️  マウントターゲットが残っています: ${FS} に ${MT_LEFT} 個"; LEFT=1
  fi
done
if [[ -n "${INSTANCE_ID}" ]]; then
  STATE=$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
  if [[ "${STATE}" != "terminated" ]]; then
    echo "  ⚠️  EC2 インスタンスが残っています: ${INSTANCE_ID}（${STATE}）"; LEFT=1
  fi
fi
for ROLE in "${SYNC_ROLE_NAME:-}" "${EC2_ROLE_NAME:-}"; do
  if [[ -n "${ROLE}" ]] && aws iam get-role --role-name "${ROLE}" >/dev/null 2>&1; then
    echo "  ⚠️  IAM ロールが残っています: ${ROLE}"; LEFT=1
  fi
done
if [[ -n "${INSTANCE_PROFILE_NAME:-}" ]] && aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  echo "  ⚠️  インスタンスプロファイルが残っています: ${INSTANCE_PROFILE_NAME}"; LEFT=1
fi
for SG in "${MT_SG_ID:-}" "${CLIENT_SG_ID:-}"; do
  if [[ -n "${SG}" ]] && aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SG}" >/dev/null 2>&1; then
    echo "  ⚠️  セキュリティグループが残っています: ${SG}"; LEFT=1
  fi
done
if [[ -n "${BUCKET_NAME}" ]] && aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "  ⚠️  S3 バケットが残っています: ${BUCKET_NAME}"; LEFT=1
fi
if [[ -n "${INSTANCE_ID}" && -n "${EFS_UTILS_LOG_GROUP_EXISTED:-}" ]]; then
  STREAM_LEFT=$(aws logs describe-log-streams --region "${REGION}" --log-group-name "${EFS_UTILS_LOG_GROUP}" \
    --query "length(logStreams[?contains(logStreamName, '${INSTANCE_ID}')])" --output text 2>/dev/null || echo "0")
  if [[ "${STREAM_LEFT}" =~ ^[1-9] ]]; then
    echo "  ⚠️  ログストリームが残っています: ${STREAM_LEFT} 本"; LEFT=1
  fi
  # もとから無かったロググループが、空のまま残っていないか
  if [[ "${EFS_UTILS_LOG_GROUP_EXISTED}" == "false" ]]; then
    ALL_STREAMS=$(aws logs describe-log-streams --region "${REGION}" --log-group-name "${EFS_UTILS_LOG_GROUP}" \
      --query 'length(logStreams)' --output text 2>/dev/null || echo "none")
    if [[ "${ALL_STREAMS}" == "0" ]]; then
      echo "  ⚠️  空のロググループが残っています: ${EFS_UTILS_LOG_GROUP}"; LEFT=1
    fi
  fi
fi
if [[ "${LEFT}" == "1" ]]; then
  echo ""
  echo "❌ 削除できなかったリソースがあります。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
echo "  なし"
rm -f "${RESOURCE_FILE}"
echo ""
echo "CloudWatch のメトリクスは削除できませんが、EC2 の終了でプロキシが止まり、メトリクスの送信も止まります。"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
