#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "!!! FAILED at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ============================================================
# JETRO 政府公共調達データベース（都道府県・政令指定都市等）収集
#  ページングは _page ではなく current（0起点オフセット, 増分30）
# ============================================================

WINDOW_DAYS=30
BLOCK_LOCAL=33686978
BASE_ARTICLE='https://www.jetro.go.jp/gov_procurement/local/articles/'
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'

echo "### STAGE 0: 環境"
jq --version
curl --version | head -1

mkdir -p data tmp
rm -f tmp/*.json

TO_JST=$(TZ=Asia/Tokyo date +%Y/%m/%d)
FROM_JST=$(TZ=Asia/Tokyo date -d "${WINDOW_DAYS} days ago" +%Y/%m/%d)
enc() { printf '%s' "$1" | sed 's|/|%2F|g'; }
F=$(enc "$FROM_JST"); T=$(enc "$TO_JST")

QS="local_from=${F}&local_to=${T}&local_area=&local_entity=&local_keyword=&local_classification1=&local_classification2=&local_classification3=&local_deadline=1"
echo "window: ${FROM_JST} - ${TO_JST}"

# ------------------------------------------------------------
# $1 = current（オフセット） / $2 = 出力先
# ------------------------------------------------------------
hit() {
  local cur="$1" out="$2" code
  code=$(curl -sS -o "$out" -w '%{http_code}' \
    --retry 3 --retry-delay 5 --max-time 60 \
    -A "$UA" \
    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H 'Referer: https://www.jetro.go.jp/gov_procurement/' \
    "https://www.jetro.go.jp/view_interface.php?blockId=${BLOCK_LOCAL}&current=${cur}&${QS}") \
    || { echo "ERROR: current=${cur} curl exit=$?" >&2; return 1; }

  if [ "$code" != "200" ]; then
    echo "ERROR: current=${cur} HTTP ${code}" >&2
    head -c 500 "$out" >&2; echo >&2
    return 1
  fi
  if ! jq -e 'type == "object" and has("items")' "$out" > /dev/null 2>&1; then
    echo "ERROR: current=${cur} 期待した形のJSONではありません" >&2
    head -c 500 "$out" >&2; echo >&2
    return 1
  fi
  echo "  current=${cur}: ok (items=$(jq '.items|length' "$out"), echo_current=$(jq -r '.pagination.current' "$out"))"
}

echo "### STAGE 1: 先頭ブロック"
hit 0 tmp/c0.json

TOTAL=$(jq -r '.pagination.total // empty' tmp/c0.json)
PER=$(jq -r '.pagination.perPage // empty' tmp/c0.json)
echo "TOTAL='${TOTAL}' PER='${PER}'"
case "$TOTAL" in ''|*[!0-9]*) echo "ERROR: TOTALが整数でない" >&2; exit 1;; esac
case "$PER"   in ''|*[!0-9]*) echo "ERROR: PERが整数でない"   >&2; exit 1;; esac
[ "$PER" -gt 0 ] || { echo "ERROR: PER=0" >&2; exit 1; }

echo "### STAGE 2: 残りのブロック"
cur=$PER
while [ "$cur" -lt "$TOTAL" ]; do
  sleep 1
  hit "$cur" "tmp/c${cur}.json"
  # 応答が要求したオフセットを反映しているか検証（無限ループ・重複取得の防止）
  echoed=$(jq -r '.pagination.current' "tmp/c${cur}.json")
  if [ "$echoed" != "$cur" ]; then
    echo "ERROR: オフセットが無視されました 要求=${cur} 応答=${echoed}" >&2
    exit 1
  fi
  cur=$(( cur + PER ))
done

echo "### STAGE 3: 結合"
ls -la tmp/
jq -s --arg base "$BASE_ARTICLE" \
  '[ .[] | (.items // [])[] ] | map(. + {url: ($base + (.aid|tostring) + ".html")}) | unique_by(.aid)' \
  tmp/c*.json > tmp/items.json
GOT=$(jq 'length' tmp/items.json)
echo "collected=${GOT} / server_total=${TOTAL}"

if [ "$GOT" -eq "$TOTAL" ]; then MATCH=true; else MATCH=false; echo "WARN: 件数不一致" >&2; fi

echo "### STAGE 4: 差分抽出"
[ -f data/seen.json ] || echo '[]' > data/seen.json
jq -e 'type == "array"' data/seen.json > /dev/null || { echo "ERROR: seen.jsonが壊れています" >&2; exit 1; }

# seen を集合（オブジェクト）に変換してから照合する。
# index() の引数内では . が配列自身を指すため、直接 .aid は書けない。
jq -s '
  ((.[0] // []) | map({ (.): true }) | add // {}) as $set
  | (.[1] // [])
  | map(select($set[.aid] // false | not))
' data/seen.json tmp/items.json > tmp/new.json
NEW=$(jq 'length' tmp/new.json)
echo "new=${NEW}"

echo "### STAGE 5: 出力"
jq -n \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg from "$FROM_JST" --arg to "$TO_JST" \
  --argjson total "$TOTAL" --argjson collected "$GOT" \
  --argjson match "$MATCH" --argjson new_count "$NEW" \
  --slurpfile items tmp/items.json \
  --slurpfile newi tmp/new.json \
  '{collected_at:$at, window:{from:$from,to:$to},
    server_total:$total, collected:$collected, count_match:$match,
    new_count:$new_count, new_items:$newi[0], items:$items[0]}' \
  > data/latest.json
jq -e '.collected_at' data/latest.json > /dev/null

echo "### STAGE 6: seen更新"
jq -s '((.[0] // []) + ((.[1] // []) | map(.aid))) | unique' data/seen.json tmp/items.json > tmp/seen.json
mv tmp/seen.json data/seen.json
cp data/latest.json "data/history-$(TZ=Asia/Tokyo date +%Y%m%d).json"

echo "### DONE  total=${TOTAL} collected=${GOT} new=${NEW}"
