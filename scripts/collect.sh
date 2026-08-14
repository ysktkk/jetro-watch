#!/usr/bin/env bash
set -euo pipefail

# ===== 設定 =====
WINDOW_DAYS=30   # 何日前まで遡って取得するか
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
BLOCK_LOCAL=33686978
BASE_ARTICLE='https://www.jetro.go.jp/gov_procurement/local/articles/'
# ================

mkdir -p data tmp
rm -f tmp/*.json

TO_JST=$(TZ=Asia/Tokyo date +%Y/%m/%d)
FROM_JST=$(TZ=Asia/Tokyo date -d "${WINDOW_DAYS} days ago" +%Y/%m/%d)
enc() { printf '%s' "$1" | sed 's|/|%2F|g'; }
F=$(enc "$FROM_JST"); T=$(enc "$TO_JST")

QS="local_from=${F}&local_to=${T}&local_area=&local_entity=&local_keyword=&local_classification1=&local_classification2=&local_classification3=&local_deadline=1"

hit() {
  curl -sS --fail --compressed --retry 3 --retry-delay 5 \
    -A "$UA" \
    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H 'Referer: https://www.jetro.go.jp/gov_procurement/' \
    "https://www.jetro.go.jp/view_interface.php?blockId=${BLOCK_LOCAL}&${QS}&_page=$1"
}

# 1ページ目で総件数を確認
hit 1 > tmp/p1.json
TOTAL=$(jq -r '.pagination.total' tmp/p1.json)
PER=$(jq -r '.pagination.perPage' tmp/p1.json)
PAGES=$(( (TOTAL + PER - 1) / PER ))
echo "total=${TOTAL} perPage=${PER} pages=${PAGES}"

for p in $(seq 2 "$PAGES"); do
  sleep 1
  hit "$p" > "tmp/p${p}.json"
done

# 全ページを結合し、詳細URLを付与
jq -s --arg base "$BASE_ARTICLE" \
  '[ .[].items[] ] | map(. + {url: ($base + .aid + ".html")}) | unique_by(.aid)' \
  tmp/p*.json > tmp/items.json

GOT=$(jq 'length' tmp/items.json)
echo "collected=${GOT}"
if [ "$GOT" -ne "$TOTAL" ]; then
  echo "WARN: 件数不一致 total=${TOTAL} collected=${GOT}"
fi

# 差分抽出
[ -f data/seen.json ] || echo '[]' > data/seen.json
jq -s '.[0] as $seen | .[1] | map(select(([$seen[]] | index(.aid)) == null))' \
  data/seen.json tmp/items.json > tmp/new.json
NEW=$(jq 'length' tmp/new.json)
echo "new=${NEW}"

# 出力
jq -n \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg from "$FROM_JST" --arg to "$TO_JST" \
  --argjson total "$TOTAL" --argjson collected "$GOT" --argjson new_count "$NEW" \
  --slurpfile items tmp/items.json \
  --slurpfile newi  tmp/new.json \
  '{collected_at:$at, window:{from:$from,to:$to},
    server_total:$total, collected:$collected, count_match:($total==$collected),
    new_count:$new_count, new_items:$newi[0], items:$items[0]}' \
  > data/latest.json

# 既知リストを更新
jq -s '(.[0] + (.[1] | map(.aid))) | unique' data/seen.json tmp/items.json > tmp/seen.json
mv tmp/seen.json data/seen.json

# 日次アーカイブ
cp data/latest.json "data/history-$(TZ=Asia/Tokyo date +%Y%m%d).json"
