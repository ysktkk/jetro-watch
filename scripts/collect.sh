#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "!!! FAILED at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ============================================================
# JETRO 政府公共調達データベース 収集（国・地方の両方）
#  ページングは current（0起点オフセット, 増分30）
#  差分は「初回観測日 == 今日」で判定（同日再実行でも結果が変わらない）
#
#  終了コードの意味（重要）
#   0 … 収集成功、または「上流（JETRO側）が利用できない」ため今回はスキップ
#   1 … スクリプト／データ側の不具合（人間の対応が必要）
#  どちらの場合も data/status.json に状態を書く。
#  上流が落ちている間は data/latest.json 等を一切上書きしないので、
#  collected_at は最後に成功した時刻のまま残る。
# ============================================================

WINDOW_DAYS=30
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36'
BLOCK_LOCAL=33686978
BLOCK_NATIONAL=33235812

# テスト時にモックへ差し替えられるようにしておく（本番では既定値のまま）
BASE_URL="${JETRO_BASE_URL:-https://www.jetro.go.jp}"
# 何回連続で上流停止が続いたらエスカレーション扱いにするか
ESCALATE_AFTER="${ESCALATE_AFTER:-3}"

STATUS_FILE=data/status.json

echo "### STAGE 0: 環境"
jq --version; curl --version | head -1

mkdir -p data tmp
rm -f tmp/*.json tmp/*.txt

TO_JST=$(TZ=Asia/Tokyo date +%Y/%m/%d)
FROM_JST=$(TZ=Asia/Tokyo date -d "${WINDOW_DAYS} days ago" +%Y/%m/%d)
TODAY_JST=$(TZ=Asia/Tokyo date +%Y-%m-%d)
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
enc() { printf '%s' "$1" | sed 's|/|%2F|g'; }
F=$(enc "$FROM_JST"); T=$(enc "$TO_JST")
echo "window: ${FROM_JST} - ${TO_JST} / today=${TODAY_JST}"

QS_LOCAL="local_from=${F}&local_to=${T}&local_area=&local_entity=&local_keyword=&local_classification1=&local_classification2=&local_classification3=&local_deadline=1"
QS_NATIONAL="type=&from=${F}&to=${T}&entity=&area=&keyword=&classification1=&classification2=&classification3=&deadline=1"

# ============================================================
# 状態ファイル（data/status.json）
# ============================================================
PREV_SUCCESS_AT=""; PREV_SUCCESS_DATE=""; PREV_FAILS=0; PREV_FAILING_SINCE=""
if [ -f "$STATUS_FILE" ] && jq -e 'type == "object"' "$STATUS_FILE" > /dev/null 2>&1; then
  PREV_SUCCESS_AT=$(jq -r '.last_success_at          // ""' "$STATUS_FILE")
  PREV_SUCCESS_DATE=$(jq -r '.last_success_date_jst  // ""' "$STATUS_FILE")
  PREV_FAILS=$(jq -r '.consecutive_failures          // 0'  "$STATUS_FILE")
  PREV_FAILING_SINCE=$(jq -r '.failing_since_date_jst // ""' "$STATUS_FILE")
fi
case "$PREV_FAILS" in ''|*[!0-9]*) PREV_FAILS=0 ;; esac

# 本文から HTML タグを除いて 200 字に切り詰める（生HTMLをコミットしないため）
snippet() { # $1=ファイル
  tr '\n\r\t' '   ' < "$1" \
    | sed -e 's/<[^>]*>/ /g' -e 's/  */ /g' -e 's/^ //' \
    | cut -c1-200
}

write_status() { # $1=state $2=http_status $3=detail
  local state="$1" http="${2:-}" detail="${3:-}"
  local fails since succ_at succ_date esc
  if [ "$state" = "ok" ]; then
    fails=0; since=""
    succ_at="$NOW_UTC"; succ_date="$TODAY_JST"
  else
    fails=$(( PREV_FAILS + 1 ))
    since="${PREV_FAILING_SINCE:-$TODAY_JST}"
    succ_at="$PREV_SUCCESS_AT"; succ_date="$PREV_SUCCESS_DATE"
  fi
  if [ "$fails" -ge "$ESCALATE_AFTER" ]; then esc=true; else esc=false; fi

  jq -n \
    --arg state "$state" --arg at "$NOW_UTC" --arg d "$TODAY_JST" \
    --arg http "$http" --arg detail "$detail" \
    --arg ep "${BASE_URL}/view_interface.php" \
    --arg sa "$succ_at" --arg sd "$succ_date" --arg since "$since" \
    --argjson fails "$fails" --argjson esc "$esc" --argjson thr "$ESCALATE_AFTER" \
    '{ state: $state,
       last_attempt_at: $at,
       last_attempt_date_jst: $d,
       http_status: (if $http   == "" then null else $http   end),
       detail:      (if $detail == "" then null else $detail end),
       endpoint: $ep,
       last_success_at:        (if $sa    == "" then null else $sa    end),
       last_success_date_jst:  (if $sd    == "" then null else $sd    end),
       consecutive_failures: $fails,
       failing_since_date_jst: (if $since == "" then null else $since end),
       escalate: $esc,
       escalate_after: $thr }' > tmp/status.json
  mv tmp/status.json "$STATUS_FILE"
  echo "### STATUS: state=${state} http=${http:-none} consecutive_failures=${fails} escalate=${esc}"
}

# スクリプト／データ側の不具合。ここだけが exit 1。
die_script() { # $1=メッセージ
  echo "ERROR: $1" >&2
  write_status script_error "${HIT_CODE:-}" "$1"
  exit 1
}

# 上流が利用できない。データを触らずに正常終了する。
bail_upstream() { # $1=どのフィードで起きたか
  echo "### 上流が利用できないため今回の収集をスキップします（feed=${1}）"
  echo "###   data/ 配下のデータは一切更新していません。collected_at は前回成功時のままです。"
  write_status "${HIT_CLASS:-upstream}" "${HIT_CODE:-}" "${HIT_DETAIL:-}"
  exit 0
}

# ============================================================
# 1ブロック取得
#  成功 → return 0
#  失敗 → return 1 し、HIT_CLASS / HIT_CODE / HIT_DETAIL に分類結果を入れる
#   HIT_CLASS: upstream      … 5xx/429/接続失敗。JETRO側の停止・輻輳
#               endpoint_gone … 404/410。エンドポイントが廃止された
#               blocked       … 401/403。遮断・要認証
#               bad_payload   … 200だがJSONでない。WAFの挟み込み or 仕様変更
# ============================================================
HIT_CLASS=""; HIT_CODE=""; HIT_DETAIL=""

hit() { # $1=blockId $2=qs $3=current $4=out
  local code curl_rc=0
  HIT_CLASS=""; HIT_CODE=""; HIT_DETAIL=""
  code=$(curl -sS -o "$4" -w '%{http_code}' \
    --retry 3 --retry-delay 5 --max-time 60 \
    -A "$UA" \
    -H 'Accept: application/json, text/javascript, */*; q=0.01' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -H "Referer: ${BASE_URL}/gov_procurement/" \
    "${BASE_URL}/view_interface.php?blockId=$1&current=$3&$2") || curl_rc=$?

  if [ "$curl_rc" -ne 0 ]; then
    HIT_CLASS=upstream; HIT_CODE="curl_exit_${curl_rc}"
    HIT_DETAIL="curlが接続に失敗しました（名前解決・TLS・タイムアウト等）"
    echo "ERROR: curl exit=${curl_rc}" >&2
    return 1
  fi

  HIT_CODE="$code"

  if [ "$code" != "200" ]; then
    HIT_DETAIL="$(snippet "$4")"
    case "$code" in
      500|502|503|504|429|408|000) HIT_CLASS=upstream ;;
      404|410)                     HIT_CLASS=endpoint_gone ;;
      401|403)                     HIT_CLASS=blocked ;;
      *)                           HIT_CLASS=upstream ;;
    esac
    echo "ERROR: HTTP ${code} → ${HIT_CLASS}" >&2
    echo "  本文: ${HIT_DETAIL}" >&2
    return 1
  fi

  if ! jq -e 'type == "object" and has("items")' "$4" > /dev/null 2>&1; then
    HIT_CLASS=bad_payload; HIT_DETAIL="$(snippet "$4")"
    echo "ERROR: HTTP 200だがJSONではない応答（WAF挟み込み／仕様変更の可能性）" >&2
    echo "  本文: ${HIT_DETAIL}" >&2
    return 1
  fi

  return 0
}

# ============================================================
# フィード単位で全件取得
#  上流由来の失敗 → return 1（呼び出し側で bail_upstream）
#  仕様・データ不整合 → die_script で exit 1
# ============================================================
collect_feed() { # $1=feed名 $2=blockId $3=qs
  local feed="$1" block="$2" qs="$3" total per cur echoed got
  echo "### FEED: ${feed}"
  hit "$block" "$qs" 0 "tmp/${feed}_0.json" || return 1

  total=$(jq -r '.pagination.total // empty' "tmp/${feed}_0.json")
  per=$(jq -r '.pagination.perPage // empty' "tmp/${feed}_0.json")
  case "$total" in ''|*[!0-9]*) die_script "total不正 (feed=${feed}, 値='${total}')";; esac
  case "$per"   in ''|*[!0-9]*) die_script "perPage不正 (feed=${feed}, 値='${per}')";; esac
  [ "$per" -gt 0 ] || die_script "perPage=0 (feed=${feed})"
  echo "  total=${total} perPage=${per}"

  cur=$per
  while [ "$cur" -lt "$total" ]; do
    sleep 1
    if ! hit "$block" "$qs" "$cur" "tmp/${feed}_${cur}.json"; then
      echo "ERROR: ページング途中で失敗 (feed=${feed}, current=${cur}/${total})" >&2
      echo "       部分データは出力しません" >&2
      return 1
    fi
    echoed=$(jq -r '.pagination.current' "tmp/${feed}_${cur}.json")
    if [ "$echoed" != "$cur" ]; then
      die_script "オフセット無視 要求=${cur} 応答=${echoed} (feed=${feed})"
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

collect_feed local    "$BLOCK_LOCAL"    "$QS_LOCAL"    || bail_upstream local
collect_feed national "$BLOCK_NATIONAL" "$QS_NATIONAL" || bail_upstream national

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
  || die_script "seen.jsonが壊れています"

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
  --arg at "$NOW_UTC" \
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

write_status ok "200" ""
echo "### DONE total=${TOTAL} collected=${GOT} new=${NEW}"
