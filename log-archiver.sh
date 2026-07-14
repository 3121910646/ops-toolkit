#!/usr/bin/env bash
#===============================================================================
#  log-archiver.sh  —  日志自动归档与过期清理
#
#  用途：按天数或大小自动归档日志文件，压缩打包到指定目录，
#        自动清理超过保留期限的归档，支持模拟运行模式。
#
#  用法：./log-archiver.sh [OPTIONS]
#  示例：./log-archiver.sh --source-dir /var/log --retention 30 --dry-run
#
#  作者：吴申
#  版本：1.0.0
#  许可：MIT License
#===============================================================================

set -euo pipefail

# ---- 配置默认值 ---------------------------------------------------------------
SOURCE_DIR="/var/log"
ARCHIVE_DIR="/backup/logs"
RETENTION_DAYS=30
MAX_SIZE_MB=1024
DRY_RUN=false
ARCHIVE_FORMAT="gz"   # gz | bz2 | xz

# ---- 颜色定义 -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 函数：打印带时间戳的日志 ---------------------------------------------------
log() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        INFO)  echo -e "${GREEN}[$timestamp INFO]${NC}  $*" ;;
        WARN)  echo -e "${YELLOW}[$timestamp WARN]${NC}  $*" ;;
        ERROR) echo -e "${RED}[$timestamp ERROR]${NC} $*" >&2 ;;
        DRY)   echo -e "${CYAN}[$timestamp DRY-RUN]${NC} $*" ;;
    esac
}

# ---- 函数：使用说明 -----------------------------------------------------------
show_help() {
    cat << EOF
用法: $(basename "$0") [OPTIONS]

按天数或大小自动归档日志文件，压缩打包并清理过期归档。

OPTIONS:
  --source-dir DIR      要归档的日志目录（默认：/var/log）
  --archive-dir DIR     归档存放目录（默认：/backup/logs）
  --retention N         归档保留天数（默认：30）
  --max-size N          单文件超过此大小(MB)则强制归档（默认：1024）
  --compress FORMAT     压缩格式：gz / bz2 / xz（默认：gz）
  --dry-run             模拟运行，不实际操作
  --help                显示此帮助信息

示例:
  $(basename "$0") --source-dir /var/log/nginx --retention 60
  $(basename "$0") --source-dir /opt/app/logs --max-size 512 --dry-run
  $(basename "$0") --source-dir /var/log --archive-dir /data/archives --compress xz

退出码:
  0  归档成功完成
  1  部分操作有警告
  2  发生错误
EOF
    exit 0
}

# ---- 函数：解析参数 ------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source-dir)   SOURCE_DIR="$2";   shift 2 ;;
            --archive-dir)  ARCHIVE_DIR="$2";  shift 2 ;;
            --retention)    RETENTION_DAYS="$2"; shift 2 ;;
            --max-size)     MAX_SIZE_MB="$2";   shift 2 ;;
            --compress)     ARCHIVE_FORMAT="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=true;       shift ;;
            --help)         show_help ;;
            *)
                log ERROR "未知选项: $1"
                echo "使用 --help 查看帮助"
                exit 2 ;;
        esac
    done

    # 验证源目录存在
    if [[ ! -d "$SOURCE_DIR" ]]; then
        log ERROR "源目录不存在: $SOURCE_DIR"
        exit 2
    fi

    # 验证压缩格式
    case "$ARCHIVE_FORMAT" in
        gz)  TAR_FLAG="z" ;;
        bz2) TAR_FLAG="j" ;;
        xz)  TAR_FLAG="J" ;;
        *)
            log ERROR "不支持的压缩格式: $ARCHIVE_FORMAT (支持 gz/bz2/xz)"
            exit 2 ;;
    esac
}

# ---- 函数：创建归档目录 ---------------------------------------------------------
prepare_dir() {
    if [[ "$DRY_RUN" == true ]]; then
        log DRY "模拟创建目录: $ARCHIVE_DIR"
        return
    fi
    mkdir -p "$ARCHIVE_DIR"
}

# ---- 函数：压缩归档 ------------------------------------------------------------
archive_logs() {
    local date_label
    date_label=$(date '+%Y%m%d_%H%M%S')
    local dir_name
    dir_name=$(basename "$SOURCE_DIR")
    local archive_name="${date_label}_${dir_name}.tar.${ARCHIVE_FORMAT}"
    local archive_path="${ARCHIVE_DIR}/${archive_name}"

    # 找到需要归档的文件（超过指定天数未修改）
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$SOURCE_DIR" -type f -mtime +0 -print0 2>/dev/null || true)

    if [[ ${#files[@]} -eq 0 ]]; then
        log INFO "没有需要归档的文件（当天内修改过的文件不归档）"
        return 0
    fi

    log INFO "找到 ${#files[@]} 个待归档文件"

    if [[ "$DRY_RUN" == true ]]; then
        log DRY "模拟打包: tar -c${TAR_FLAG}f $archive_path -- ${#files[@]} 个文件"
        return
    fi

    # 压缩打包
    if tar -c"${TAR_FLAG}"f "$archive_path" -C "$(dirname "$SOURCE_DIR")" \
           --remove-files \
           "$(basename "$SOURCE_DIR")" 2>/dev/null; then
        local size
        size=$(du -sh "$archive_path" | awk '{print $1}')
        log INFO "归档成功: $archive_path ($size)"
    else
        log ERROR "归档打包失败"
        return 2
    fi
}

# ---- 函数：按大小强制归档 -------------------------------------------------------
archive_oversized() {
    local max_bytes=$((MAX_SIZE_MB * 1024 * 1024))
    local count=0

    while IFS= read -r -d '' f; do
        local fsize
        fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if [[ "$fsize" -gt "$max_bytes" ]]; then
            local date_label
            date_label=$(date '+%Y%m%d_%H%M%S')
            local fname
            fname=$(basename "$f")
            local archive_name="${date_label}_${fname}.tar.${ARCHIVE_FORMAT}"
            local archive_path="${ARCHIVE_DIR}/${archive_name}"

            log WARN "文件过大，强制归档: $f ($(( fsize / 1024 / 1024 ))MB)"

            if [[ "$DRY_RUN" == false ]]; then
                tar -c"${TAR_FLAG}"f "$archive_path" -C "$(dirname "$f")" "$fname" \
                    && rm -f "$f" \
                    && log INFO "  已归档至: $archive_path"
            else
                log DRY "模拟强制归档: $f -> $archive_path"
            fi
            ((count++))
        fi
    done < <(find "$SOURCE_DIR" -type f -print0 2>/dev/null || true)

    if [[ "$count" -eq 0 ]]; then
        log INFO "没有超过 ${MAX_SIZE_MB}MB 的大文件需要强制归档"
    fi
}

# ---- 函数：清理过期归档 ---------------------------------------------------------
cleanup_old_archives() {
    log INFO "清理超过 ${RETENTION_DAYS} 天的归档文件..."

    local old_files
    if [[ "$DRY_RUN" == true ]]; then
        while IFS= read -r -d '' f; do
            log DRY "模拟删除过期归档: $f ($(stat -c%y "$f" 2>/dev/null | cut -d. -f1))"
        done < <(find "$ARCHIVE_DIR" -type f -name "*.tar.${ARCHIVE_FORMAT}" -mtime "+${RETENTION_DAYS}" -print0 2>/dev/null || true)
        return
    fi

    local deleted=0
    while IFS= read -r -d '' f; do
        log WARN "删除过期归档: $f"
        rm -f "$f"
        ((deleted++))
    done < <(find "$ARCHIVE_DIR" -type f -name "*.tar.${ARCHIVE_FORMAT}" -mtime "+${RETENTION_DAYS}" -print0 2>/dev/null || true)

    if [[ "$deleted" -eq 0 ]]; then
        log INFO "没有过期的归档文件需要清理"
    else
        log INFO "已清理 ${deleted} 个过期归档文件"
    fi
}

# ---- 函数：打印统计 ------------------------------------------------------------
print_summary() {
    echo
    echo -e "${BOLD}${BLUE}═══ 归档操作摘要 ═══${NC}"
    echo -e "  源目录  : ${SOURCE_DIR}"
    echo -e "  归档目录: ${ARCHIVE_DIR}"
    echo -e "  压缩格式: ${ARCHIVE_FORMAT}"
    echo -e "  保留天数: ${RETENTION_DAYS}"
    echo -e "  大小阈值: ${MAX_SIZE_MB} MB"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}模式    : 模拟运行（未实际操作）${NC}"
    fi
    echo

    # 显示归档目录使用情况
    if [[ -d "$ARCHIVE_DIR" ]]; then
        local archive_count archive_size
        archive_count=$(find "$ARCHIVE_DIR" -type f -name "*.tar.${ARCHIVE_FORMAT}" | wc -l)
        archive_size=$(du -sh "$ARCHIVE_DIR" 2>/dev/null | awk '{print $1}')
        echo -e "  已归档文件数: ${archive_count}"
        echo -e "  归档占用空间: ${archive_size}"
    fi
    echo
}

# ---- 主流程 -------------------------------------------------------------------
main() {
    parse_args "$@"

    echo
    log INFO "开始日志归档任务..."
    log INFO "源目录: $SOURCE_DIR → 归档目录: $ARCHIVE_DIR"
    echo

    prepare_dir
    archive_logs
    archive_oversized
    cleanup_old_archives
    print_summary

    log INFO "归档任务完成"
}

main "$@"
