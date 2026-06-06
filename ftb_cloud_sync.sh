#!/usr/bin/env bash
# ftb_cloud_sync.sh — 將本地備份資料夾持續 sync 到 Cloudflare R2
#
# 用法:
#   ./ftb_cloud_sync.sh [選項]
#
# 選項:
#   -l, --local-dir    <path>    本地備份資料夾（建議用絕對路徑）    (必填)
#   -r, --remote       <remote>  備份同步目的地（主要儲存路徑）        (必填, 例: r2:bucket/ftbbackup)
#   -b, --backup-dir   <remote>  刪除檔案的保留區（不可與 --remote 相同）(必填, 例: r2:bucket/ftbbackup-deleted)
#   -m, --max-size     <GB>      遠端容量上限 GB                     (預設: 8)
#   -i, --interval     <秒>      每次 sync 間隔秒數                  (預設: 1800)
#   -M, --max-missing  <數量>    遠端比本地多幾個檔案才觸發 abort     (預設: 3)
#   -d, --dry-run                模擬執行，不實際操作
#   -h, --help                   顯示說明

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# 日誌
# ══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; RESET='\033[0m'
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { echo -e "${CYAN}[$(_ts)] [INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[$(_ts)] [OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[$(_ts)] [WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[$(_ts)] [ERROR]${RESET} $*"; }

# ══════════════════════════════════════════════════════════════════════════════
# 參數解析
# ══════════════════════════════════════════════════════════════════════════════

LOCAL_DIR=""
REMOTE=""
BACKUP_DIR=""
MAX_SIZE_GB=8
INTERVAL_SEC=1800
MAX_MISSING=3
DRY_RUN=false

usage() {
  local name
  name=$(basename "$0")
  awk '/^#!/{next} /^# ═/{exit} /^#/{sub(/^# ?/,""); print}' "$0" \
    | sed "s|ftb_cloud_sync\.sh|${name}|g"
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l|--local-dir)   LOCAL_DIR="$2";    shift 2 ;;
      -r|--remote)      REMOTE="$2";       shift 2 ;;
      -b|--backup-dir)  BACKUP_DIR="$2";   shift 2 ;;
      -m|--max-size)    MAX_SIZE_GB="$2";  shift 2 ;;
      -i|--interval)    INTERVAL_SEC="$2"; shift 2 ;;
      -M|--max-missing) MAX_MISSING="$2";  shift 2 ;;
      -d|--dry-run)     DRY_RUN=true;      shift   ;;
      -h|--help)        usage ;;
      *) log_error "未知參數: $1"; echo ""; usage ;;
    esac
  done
}

validate_args() {
  local err=0
  [[ -z "$LOCAL_DIR"  ]] && { log_error "缺少 --local-dir";   err=1; }
  [[ -z "$REMOTE"     ]] && { log_error "缺少 --remote";      err=1; }
  [[ -z "$BACKUP_DIR" ]] && { log_error "缺少 --backup-dir";  err=1; }
  [[ "$MAX_SIZE_GB"  =~ ^[0-9]+([.][0-9]+)?$ ]] || { log_error "--max-size 必須是數字";   err=1; }
  [[ "$INTERVAL_SEC" =~ ^[0-9]+$ ]]              || { log_error "--interval 必須是整數";   err=1; }
  [[ "$MAX_MISSING"  =~ ^[0-9]+$ ]]              || { log_error "--max-missing 必須是整數"; err=1; }
  [[ "$REMOTE" != "$BACKUP_DIR" ]]               || { log_error "--remote 與 --backup-dir 不可相同"; err=1; }
  if (( err )); then echo ""; usage; fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 環境檢查
# ══════════════════════════════════════════════════════════════════════════════

check_env() {
  local err=0
  command -v rclone  &>/dev/null || { log_error "找不到 rclone，請先安裝: https://rclone.org/install/"; err=1; }
  command -v python3 &>/dev/null || { log_error "找不到 python3（用於解析 rclone JSON 輸出）";         err=1; }
  command -v bc      &>/dev/null || { log_error "找不到 bc（用於容量換算）";                            err=1; }
  [[ -d "$LOCAL_DIR" ]]          || { log_error "本地資料夾不存在: $LOCAL_DIR";                         err=1; }
  (( err )) && exit 1
  log_ok "環境檢查通過"
}

# ══════════════════════════════════════════════════════════════════════════════
# 遠端設定
# ══════════════════════════════════════════════════════════════════════════════

configure_rclone_remote() {
  local remote_name
  remote_name=$(echo "$REMOTE" | cut -d: -f1)
  log_info "套用 rclone 設定：停用 multipart upload（${remote_name}）..."
  if rclone config update "$remote_name" disable_multipart true &>/dev/null; then
    log_ok "已停用 multipart upload（解決 R2 相容性問題）"
  else
    log_warn "無法套用 disable_multipart，若 sync 失敗請手動執行: rclone config update ${remote_name} disable_multipart true"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 遠端連線驗證
# ══════════════════════════════════════════════════════════════════════════════

check_remote_conn() {
  log_info "驗證遠端連線..."
  local err=0
  rclone lsf --files-only "$REMOTE"     &>/dev/null || { log_error "無法連線到 $REMOTE，請確認 rclone 設定與 bucket 名稱";     err=1; }
  rclone lsf --files-only "$BACKUP_DIR" &>/dev/null || { log_error "無法連線到 $BACKUP_DIR，請確認 rclone 設定與 bucket 名稱"; err=1; }
  if (( err )); then exit 1; fi
  log_ok "遠端連線正常"
}

# ══════════════════════════════════════════════════════════════════════════════
# 遠端查詢
# ══════════════════════════════════════════════════════════════════════════════

remote_size_bytes() {
  local path=$1
  local result
  result=$(rclone size --json "$path" 2>/dev/null) || { echo "ERROR"; return 1; }
  echo "$result" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('bytes',0))" \
    2>/dev/null || { echo "ERROR"; return 1; }
}

remote_file_list() { rclone lsf --files-only "$REMOTE" 2>/dev/null | sort; }
local_file_list()  { find "$LOCAL_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort; }

format_bytes() {
  local b=$1
  (( b >= 1073741824 )) && { printf "%.2f GB" "$(echo "scale=2; $b/1073741824" | bc)"; return; }
  (( b >= 1048576    )) && { printf "%.2f MB" "$(echo "scale=2; $b/1048576"    | bc)"; return; }
  (( b >= 1024       )) && { printf "%.2f KB" "$(echo "scale=2; $b/1024"       | bc)"; return; }
  echo "${b} B"
}

# ══════════════════════════════════════════════════════════════════════════════
# 檢查：容量
# ══════════════════════════════════════════════════════════════════════════════

check_remote_size() {
  local max_bytes used_bytes used_fmt max_fmt
  local remote_bucket="${REMOTE%%/*}"
  local backup_bucket="${BACKUP_DIR%%/*}"
  max_bytes=$(echo "$MAX_SIZE_GB * 1073741824" | bc | cut -d. -f1)

  log_info "檢查遠端容量..."
  if [[ "$remote_bucket" == "$backup_bucket" ]]; then
    used_bytes=$(remote_size_bytes "$remote_bucket") || { log_error "無法查詢遠端容量（rclone 失敗），跳過本次 sync"; return 1; }
  else
    local main_bytes backup_bytes
    main_bytes=$(remote_size_bytes "$REMOTE")       || { log_error "無法查詢遠端容量（rclone 失敗），跳過本次 sync";     return 1; }
    backup_bytes=$(remote_size_bytes "$BACKUP_DIR") || { log_error "無法查詢備份目錄容量（rclone 失敗），跳過本次 sync"; return 1; }
    used_bytes=$(( main_bytes + backup_bytes ))
  fi
  used_fmt=$(format_bytes "$used_bytes")
  max_fmt=$(format_bytes "$max_bytes")

  if (( used_bytes >= max_bytes )); then
    log_warn "遠端已用 ${used_fmt} / 上限 ${max_fmt} — 超限，跳過本次 sync"
    log_warn "請手動清理 $REMOTE 或 $BACKUP_DIR，或調高 --max-size"
    return 1
  fi

  log_ok "遠端容量 ${used_fmt} / ${max_fmt} — 正常"
}

# ══════════════════════════════════════════════════════════════════════════════
# 檢查：檔案差異（防止本地誤刪後同步到遠端）
# ══════════════════════════════════════════════════════════════════════════════

check_missing_files() {
  log_info "比對本地與遠端檔案差異..."

  local only_on_remote count
  only_on_remote=$(comm -23 <(remote_file_list) <(local_file_list))
  count=$(echo "$only_on_remote" | grep -c '\S' || true)

  if (( count > MAX_MISSING )); then
    log_warn "遠端比本地多了 ${count} 個檔案（上限 ${MAX_MISSING}），疑似本地異常，abort sync"
    echo "$only_on_remote" | while IFS= read -r f; do
      [[ -n "$f" ]] && log_warn "  遠端獨有: $f"
    done
    return 1
  fi

  if (( count > 0 )); then
    log_info "遠端比本地多 ${count} 個檔案（在容許範圍內，視為正常 rotate）"
    echo "$only_on_remote" | while IFS= read -r f; do
      [[ -n "$f" ]] && log_info "  將移至 backup-dir: $f"
    done
  else
    log_ok "本地與遠端一致，無異常缺失"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Sync
# ══════════════════════════════════════════════════════════════════════════════

run_sync() {
  local round=$1
  log_info "─── 第 ${round} 次同步 ──────────────────────────────────────"

  check_remote_size   || return 1
  check_missing_files || return 1

  local cmd=(rclone sync "$LOCAL_DIR" "$REMOTE" --backup-dir "$BACKUP_DIR" --retries 5 --progress --log-level INFO)

  if $DRY_RUN; then
    log_info "[dry-run] ${cmd[*]}"
    log_ok   "[dry-run] 模擬完成"
    return 0
  fi

  local rc=0
  "${cmd[@]}" || rc=$?
  if (( rc == 0 )); then
    log_ok "sync 完成"
  else
    log_error "rclone sync 失敗 (exit code: ${rc})"
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# 主程式
# ══════════════════════════════════════════════════════════════════════════════

parse_args "$@"
validate_args
check_env
configure_rclone_remote
check_remote_conn

log_info "ftb_cloud_sync 啟動"
log_info "本地資料夾  : $LOCAL_DIR"
log_info "遠端路徑    : $REMOTE"
log_info "備份目錄    : $BACKUP_DIR"
log_info "容量上限    : ${MAX_SIZE_GB} GB"
log_info "同步間隔    : ${INTERVAL_SEC} 秒"
log_info "最大允許差異: ${MAX_MISSING} 個檔案"
$DRY_RUN && log_warn "dry-run 模式開啟，不會實際執行 rclone"
echo ""

round=1
while true; do
  run_sync "$round" || true
  log_info "等待 ${INTERVAL_SEC} 秒後進行下一次同步 (Ctrl+C 可停止)"
  echo ""
  sleep "$INTERVAL_SEC"
  (( round++ ))
done