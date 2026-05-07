#!/bin/sh
set -eu

# PostToolUse hook: Write ツールで report/ 直下に .md を書いたとき Discord 通知を送る
# stdin: Claude Code hook JSON

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE_PATH" ] && exit 0

FILENAME=$(basename "$FILE_PATH")

# report/ 直下の yyyy-mm-dd_*.md のみ通知 (attachment/ 等は除外)
case "$FILENAME" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*.md) ;;
  *) exit 0 ;;
esac

# ディレクトリも確認 (report/ 直下であること)
DIR=$(dirname "$FILE_PATH")
case "$DIR" in
  */report) ;;
  *) exit 0 ;;
esac

# .env 読み込み
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
ENV_FILE="$PROJECT_DIR/.env"
[ -f "$ENV_FILE" ] || exit 0

DISCORD_WEBHOOK_URL=""
REPORT_BASE_URL=""
while IFS='=' read -r key value; do
  case "$key" in
    DISCORD_WEBHOOK_URL) DISCORD_WEBHOOK_URL="$value" ;;
    REPORT_BASE_URL) REPORT_BASE_URL="$value" ;;
  esac
done < "$ENV_FILE"

[ -z "$DISCORD_WEBHOOK_URL" ] && exit 0

# レポートタイトル抽出 (先頭の # 行)
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
TITLE=$(printf '%s' "$CONTENT" | head -1 | sed 's/^# *//')
[ -z "$TITLE" ] && TITLE="$FILENAME"

# claude -p で要約生成 (haiku, --tools "" で tool 無効化して再帰防止)
# --bare は OAuth/keychain を読まないため (ANTHROPIC_API_KEY 必須)、ここでは使わず
# tool 無効化のみで要約用途に絞る。認証失敗時 claude は stdout にエラー文を出して exit 1 で終わるため、
# 終了コード + 既知エラーパターンの両方をチェックして異常時はタイトルにフォールバックする
SUMMARY="$TITLE"
if command -v claude >/dev/null 2>&1; then
  GENERATED=$(printf '%s' "$CONTENT" | timeout 60 claude -p \
    --model haiku \
    --tools "" \
    --exclude-dynamic-system-prompt-sections \
    --dangerously-skip-permissions \
    "以下のレポートの結論がわかる簡潔な要約を150字程度の日本語で生成してください。要約のみを出力し、前置きや説明は不要です。" \
    2>/dev/null) && RC=0 || RC=$?
  if [ "$RC" -eq 0 ] && [ -n "$GENERATED" ] \
     && ! printf '%s' "$GENERATED" | grep -qE 'Not logged in|Please run /login|Invalid API key|Usage limit'; then
    SUMMARY="$GENERATED"
  fi
fi

# レポート URL
REPORT_URL=""
if [ -n "$REPORT_BASE_URL" ]; then
  REPORT_URL="$REPORT_BASE_URL/$FILENAME"
fi

# Discord embed 送信
PAYLOAD=$(jq -n \
  --arg title "$TITLE" \
  --arg summary "$SUMMARY" \
  --arg url "$REPORT_URL" \
  '{
    embeds: [{
      title: $title,
      url: (if $url != "" then $url else null end),
      description: $summary,
      color: 5814783
    }]
  }')

curl -s -o /dev/null -X POST "$DISCORD_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" || true

exit 0
