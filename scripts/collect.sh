#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "!!! FAILED at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ============================================================
# JETRO 政府公共調達データベース 収集（国・地方の両方）
#  ページングは current（0起点オフセット, 増分30）
#  差分は「初回観測日 == 今日」で判定（同日再実行でも結果が変わらない）
# ============================================================

WINDOW_DAYS=30
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
BLOCK_LOCAL=33686978
BLOCK_NATIONAL=33235812

echo "### STAGE 0: 環境"
jq --version; curl --version | head -1

mkdir -p data tmp
rm -f tmp/*.json tmp/*.txt

TO_JST=$(TZ=Asia/Tokyo date +%Y/%m/%d)
FROM_JST=$(TZ=Asia/Tokyo date -d "${WINDOW_DAYS} days ago" +%Y/%m/%d)
TODAY_JST=$(TZ=Asia/Tokyo date +%Y-%m-%d)
enc() { printf '%s' "$1" | sed 's|/|%2F|g'; }
F=$(enc "$FROM_JST"); T=$(enc "$TO_JST")
echo "window: ${FROM_JST} - ${TO_JST} / today=${TODAY_JST}"

QS_LOCAL="local_from=${F}&local_to=${T}&local_area=&local_entity=&local_keyword=&local_classification1=&local_classification2=&local_classification3=&local_deadline=1"
QS_NATIONAL="type=&from=${F}&to=${T}&entity=&area=&keyword=&classification1=&classification2=&classification3=&deadline=1"

# --- 1ブロック取得 ---
hit() { # $1=blockId $2=qs $3=current $4=out
  local code
  code=$(curl -sS -o "$4" -w '%{http_code}' \
    --retry 3 --retry-delay 5 --max-time 60 \
    -A "$UA" \
    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H 'Referer: https://www.jetro.go.jp/gov_procurement/' \
    "https://www.jetro.go.jp/view_interface.php?blockId=$1&current=$3&$2") \
    || { echo "ERROR: curl exit=$?" >&2; return 1; }
  if [ "$code" != "200" ]; then
    echo "ERROR: HTTP ${code}" >&2; head -c 400 "$4" >&2; echo >&2; return 1
  fi
  if ! jq -e 'type == "object" and has("items")' "$4" > /dev/null 2>&1; then
    echo "ERROR: JSONではない応答（WAFの可能性）" >&2; head -c 400 "$4" >&2; echo >&2; return 1
  fi
}

# --- フィード単位で全件取得 ---
collect_feed() { # $1=feed名 $2=blockId $3=qs
  local feed="$1" block="$2" qs="$3" total per cur echoed got
  echo "### FEED: ${feed}"
  hit "$block" "$qs" 0 "tmp/${feed}_0.json"
  total=$(jq -r '.pagination.total // empty' "tmp/${feed}_0.json")
  per=$(jq -r '.pagination.perPage // empty' "tmp/${feed}_0.json")
  case "$total" in ''|*[!0-9]*) echo "ERROR: total不正" >&2; exit 1;; esac
  case "$per"   in ''|*[!0-9]*) echo "ERROR: perPage不正" >&2; exit 1;; esac
  [ "$per" -gt 0 ] || { echo "ERROR: perPage=0" >&2; exit 1; }
  echo "  total=${total} perPage=${per}"

  cur=$per
  while [ "$cur" -lt "$total" ]; do
    sleep 1
    hit "$block" "$qs" "$cur" "tmp/${feed}_${cur}.json"
    echoed=$(jq -r '.pagination.current' "tmp/${feed}_${cur}.json")
    if [ "$echoed" != "$cur" ]; then
      echo "ERROR: オフセット無視 要求=${cur} 応答=${echoed}" >&2; exit 1
    fi
    cur=$(( cur + per ))
  done

  jq -s --arg feed "$feed" '
    [ .[] | (.items // [])[] ]
    | map(. + {feed: $feed})
    | map(. + {url:
        (if $feed == "local"
         then "https://www.jetro.go.jp/gov_procurement/local/articles/" + (.aid|tostring) + ".html"
         else "https://www.jetro.go.jp/gov_procurement/national/articles/" + (.xid|tostring) + "/" + (.aid|tostring) + ".html"
         end)})
    | map(. + {key: ($feed + ":" + (.aid|tostring))})
    | unique_by(.key)
  ' tmp/${feed}_*.json > "tmp/items_${feed}.json"

  got=$(jq 'length' "tmp/items_${feed}.json")
  echo "  collected=${got} / total=${total}"
  echo "$total" > "tmp/total_${feed}.txt"
  echo "$got"   > "tmp/got_${feed}.txt"
}

collect_feed local    "$BLOCK_LOCAL"    "$QS_LOCAL"
collect_feed national "$BLOCK_NATIONAL" "$QS_NATIONAL"

echo "### STAGE 3: 統合"
jq -s 'add' tmp/items_local.json tmp/items_national.json > tmp/items.json
TOTAL_L=$(cat tmp/total_local.txt);    GOT_L=$(cat tmp/got_local.txt)
TOTAL_N=$(cat tmp/total_national.txt); GOT_N=$(cat tmp/got_national.txt)
TOTAL=$(( TOTAL_L + TOTAL_N )); GOT=$(( GOT_L + GOT_N ))
if [ "$GOT" -eq "$TOTAL" ]; then MATCH=true; else MATCH=false; echo "WARN: 件数不一致" >&2; fi
echo "合計 collected=${GOT} / total=${TOTAL}"

echo "### STAGE 4: 差分抽出（初回観測日ベース）"
[ -f data/seen.json ] || echo '{}' > data/seen.json
# 旧形式（aidの配列）からオブジェクト形式へ自動移行
if jq -e 'type == "array"' data/seen.json > /dev/null 2>&1; then
  echo "  seen.json を旧形式から移行"
  jq 'map({ ("local:" + .): "1970-01-01" }) | add // {}' data/seen.json > tmp/seen_mig.json
  mv tmp/seen_mig.json data/seen.json
fi
jq -e 'type == "object"' data/seen.json > /dev/null \
  || { echo "ERROR: seen.jsonが壊れています" >&2; exit 1; }

jq -s --arg d "$TODAY_JST" '
  .[0] as $seen | .[1] as $items
  | reduce $items[] as $it ($seen; if has($it.key) then . else .[$it.key] = $d end)
' data/seen.json tmp/items.json > tmp/seen_new.json

jq -s --arg d "$TODAY_JST" '
  .[0] as $seen | .[1] | map(select($seen[.key] == $d))
' tmp/seen_new.json tmp/items.json > tmp/new.json
NEW=$(jq 'length' tmp/new.json)
NEW_L=$(jq '[.[]|select(.feed=="local")]|length' tmp/new.json)
NEW_N=$(jq '[.[]|select(.feed=="national")]|length' tmp/new.json)
echo "new=${NEW} (local=${NEW_L} national=${NEW_N})"

echo "### STAGE 5: 出力"
jq -n \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg from "$FROM_JST" --arg to "$TO_JST" \
  --argjson total "$TOTAL" --argjson collected "$GOT" --argjson match "$MATCH" \
  --argjson tl "$TOTAL_L" --argjson tn "$TOTAL_N" \
  --argjson new_count "$NEW" --argjson nl "$NEW_L" --argjson nn "$NEW_N" \
  --slurpfile items tmp/items.json --slurpfile newi tmp/new.json \
  '{collected_at:$at, window:{from:$from,to:$to},
    server_total:$total, collected:$collected, count_match:$match,
    by_feed:{local:$tl, national:$tn},
    new_count:$new_count, new_by_feed:{local:$nl, national:$nn},
    new_items:$newi[0], items:$items[0]}' > data/latest.json

# 判定タスク用の軽量版（フィード別に分割）
mk_new() { # $1=出力先 $2="all"/"local"/"national"
  jq --arg mode "$2" '
    (if $mode == "all" then .new_items
     else (.new_items | map(select(.feed == $mode))) end) as $sel
    | {collected_at, window, server_total, collected, count_match,
       by_feed, new_by_feed,
       new_count: ($sel | length),
       new_items: ($sel | map({
         feed, date, agency, location, title, url,
         paKind: ((.paKind // "") | gsub("<[^>]*>"; " ") | gsub("\\s+"; " ")
                  | ltrimstr(" ") | rtrimstr(" "))
       }))}
  ' data/latest.json > "$1"
}

mk_new data/new.json          all
mk_new data/new_local.json    local
mk_new data/new_national.json national

echo "### STAGE 6: seen更新"
mv tmp/seen_new.json data/seen.json
cp data/latest.json "data/history-$(TZ=Asia/Tokyo date +%Y%m%d).json"

echo "### DONE total=${TOTAL} collected=${GOT} new=${NEW}"
