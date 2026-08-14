#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# JETRO 政府公共調達データベース（都道府県・政令指定都市等）収集
#  - view_interface.php の JSON API を叩いて全ページ取得
#  - 既知案件（data/seen.json）との差分を抽出
#  - data/latest.json に出力（Claudeスケジュールタスクが読む）
# ============================================================

# ===== 設定 =====
WINDOW_DAYS=30                       # 何日前まで遡って取得するか
BLOCK_LOCAL=33686978                 # 都道府県・政令市等のブロックID
BASE_ARTICLE='https://www.jetro.go.jp/gov_procurement/local/articles/'
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
# ================

mkdir -p data tmp
rm -f tmp/*.json

TO_JST=$(TZ=Asia/Tokyo date +%Y/%m/%d)
FROM_JST=$(TZ=Asia/Tokyo date -d "${WINDOW_DAYS} days ago" +%Y/%m/%d)

enc() { printf '%s' "$1" | sed 's|/|%2F|g'; }
F=$(enc "$FROM_JST")
T=$(enc "$TO_JST")

QS="local_from=${F}&local_to=${T}&local_area=&local_entity=&local_keyword=&local_classification1=&local_classification2=&local_classification3=&local_deadline=1"

echo "=== JETRO collect ==="
echo "window: ${FROM_JST} - ${TO_JST}"

# ------------------------------------------------------------
# 1ページ取得。HTTPステータスとJSON妥当性の両方を検証する。
#   $1 = ページ番号 / $2 = 出力先ファイル
# ------------------------------------------------------------
hit() {
  local page="$1" out="$2" code

  code=$(curl -sS -o "$out" -w '%{http_code}' \
    --compressed --retry 3 --retry-delay 5 --max-time 60 \
    -A "$UA" \
    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
    -H 'Accept-Language: ja,en-US;q=0.9,en;q=0.8' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H 'Referer: https://www.jetro.go.jp/gov_procurement/local/list.html' \
    -H 'Sec-Fetch-Dest: empty' \
    -H 'Sec-Fetch-Mode: cors' \
    -H 'Sec-Fetch-Site: same-origin' \
    "https://www.jetro.go.jp/view_interface.php?blockId=${BLOCK_LOCAL}&${QS}&_page=${page}")

  if [ "$code" != "200" ]; then
    echo "ERROR: page=${page} HTTP ${code}" >&2
    echo "--- 応答の先頭500文字 ---" >&2
    head -c 500 "$out" >&2; echo >&2
    return 1
  fi

  if ! jq -e . "$out" > /dev/null 2>&1; then
    echo "ERROR: page=${page} HTTP 200 だが JSON ではない。WAFによるブロックの可能性。" >&2
    echo "--- 応答の先頭500文字 ---" >&2
    head -c 500 "$out" >&2; echo >&2
    return 1
  fi

  echo "  page ${page}: ok ($(wc -c < "$out") bytes)"
}

# ------------------------------------------------------------
# 1ページ目で総件数を確認し、必要なページ数を算出
# ------------------------------------------------------------
hit 1 tmp/p1.json

TOTAL=$(jq -r '.pagination.total // empty' tmp/p1.json)
PER=$(jq -r '.pagination.perPage // empty' tmp/p1.json)

if [ -z "$TOTAL" ] || [ -z "$PER" ]; then
  echo "ERROR: pagination が取得できません。応答形式が変わった可能性があります。" >&2
  head -c 500 tmp/p1.json >&2; echo >&2
  exit 1
fi

PAGES=$(( (TOTAL + PER - 1) / PER ))
echo "total=${TOTAL} perPage=${PER} pages=${PAGES}"

for p in $(seq 2 "$PAGES"); do
  sleep 1
  hit "$p" "tmp/p${p}.json"
done

# ------------------------------------------------------------
# 全ページを結合し、詳細ページURLを付与
# ------------------------------------------------------------
jq -s --arg base "$BASE_ARTICLE" \
  '[ .[].items[] ] | map(. + {url: ($base + .aid + ".html")}) | unique_by(.aid)' \
  tmp/p*.json > tmp/items.json

GOT=$(jq 'length' tmp/items.json)
echo "collected=${GOT}"

MATCH=true
if [ "$GOT" -ne "$TOTAL" ]; then
  echo "WARN: 件数不一致 server_total=${TOTAL} collected=${GOT}" >&2
  MATCH=false
fi

# ------------------------------------------------------------
# 既知案件との差分抽出
# ------------------------------------------------------------
[ -f data/seen.json ] || echo '[]' > data/seen.json

jq -s '.[0] as $seen | .[1] | map(select(([$seen[]] | index(.aid)) == null))' \
  data/seen.json tmp/items.json > tmp/new.json

NEW=$(jq 'length' tmp/new.json)
echo "new=${NEW}"

# ------------------------------------------------------------
# 出力
# ------------------------------------------------------------
jq -n \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg from "$FROM_JST" \
  --arg to "$TO_JST" \
  --argjson total "$TOTAL" \
  --argjson collected "$GOT" \
  --argjson match "$MATCH" \
  --argjson new_count "$NEW" \
  --slurpfile items tmp/items.json \
  --slurpfile newi tmp/new.json \
  '{
     collected_at: $at,
     window: { from: $from, to: $to },
     server_total: $total,
     collected: $collected,
     count_match: $match,
     new_count: $new_count,
     new_items: $newi[0],
     items: $items[0]
   }' > data/latest.json

# 既知リストを更新
jq -s '(.[0] + (.[1] | map(.aid))) | unique' data/seen.json tmp/items.json > tmp/seen.json
mv tmp/seen.json data/seen.json

# 日次アーカイブ
cp data/latest.json "data/history-$(TZ=Asia/Tokyo date +%Y%m%d).json"

echo "=== done ==="
