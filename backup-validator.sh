#!/usr/bin/env bash
#===============================================================================
#  backup-validator.sh  —  备份文件完整性校验
#
#  用途：对比源目录与备份目录，校验文件数量、大小、MD5/SHA256 校验和，
#        生成差异报告。用于灾备演练或每日备份验证。
#
#  用法：./backup-validator.sh [OPTIONS]
#  示例：./backup-validator.sh --source /data --backup /backup/data --checksum sha256
#
#  作者：吴申
#  版本：1.0.0
#  许可：MIT License
#===============================================================================

set -euo pipefail

# ---- 配置默认值 ---------------------------------------------------------------
SOURCE_DIR=""
BACKUP_DIR=""
CHECKSUM_METHOD="md5"   # md5 | sha256
REPORT_FILE=""
VERBOSE=false

# ---- 颜色定义 -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 临时文件 -----------------------------------------------------------------
TMP_DIR=$(mktemp -d -t backup-validator.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

SOURCE_LIST="$TMP_DIR/source_files.txt"
BACKUP_LIST="$TMP_DIR/backup_files.txt"
SOURCE_CHECKSUM="$TMP_DIR/source_checksums.txt"
BACKUP_CHECKSUM="$TMP_DIR/backup_checksums.txt"

# ---- 函数：使用说明 -----------------------------------------------------------
show_help() {
    cat << EOF
用法: $(basename "$0") [OPTIONS]

对比源目录与备份目录，校验文件完整性并生成差异报告。

OPTIONS:
  --source DIR       源目录路径（必填）
  --backup DIR       备份目录路径（必填）
  --checksum METHOD  校验方式：md5 或 sha256（默认：md5）
  --report FILE      将报告写入指定文件
  --verbose          详细模式，显示每个文件的校验结果
  --help             显示此帮助信息

示例:
  $(basename "$0") --source /data/app --backup /backup/data/app
  $(basename "$0") --source /opt --backup /mnt/backup/opt --checksum sha256 --report report.txt
  $(basename "$0") --source /var/www --backup /backup/www --verbose

退出码:
  0  备份完全一致
  1  存在差异（缺失文件 / 大小不同 / 校验和不匹配）
  2  运行错误
EOF
    exit 0
}

# ---- 函数：解析参数 ------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)     SOURCE_DIR="$2";    shift 2 ;;
            --backup)     BACKUP_DIR="$2";    shift 2 ;;
            --checksum)   CHECKSUM_METHOD="$2"; shift 2 ;;
            --report)     REPORT_FILE="$2";   shift 2 ;;
            --verbose)    VERBOSE=true;       shift ;;
            --help)       show_help ;;
            *)
                echo -e "${RED}错误: 未知选项 $1${NC}"
                echo "使用 --help 查看帮助"
                exit 2 ;;
        esac
    done

    if [[ -z "$SOURCE_DIR" ]]; then
        echo -e "${RED}错误: 必须指定 --source 源目录${NC}"
        exit 2
    fi
    if [[ -z "$BACKUP_DIR" ]]; then
        echo -e "${RED}错误: 必须指定 --backup 备份目录${NC}"
        exit 2
    fi
    if [[ ! -d "$SOURCE_DIR" ]]; then
        echo -e "${RED}错误: 源目录不存在: $SOURCE_DIR${NC}"
        exit 2
    fi
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo -e "${RED}错误: 备份目录不存在: $BACKUP_DIR${NC}"
        exit 2
    fi

    # 选择校验命令
    case "$CHECKSUM_METHOD" in
        md5)    CHECKSUM_CMD="md5sum" ;;
        sha256) CHECKSUM_CMD="sha256sum" ;;
        *)
            echo -e "${RED}错误: 不支持的校验方式: $CHECKSUM_METHOD (支持 md5/sha256)${NC}"
            exit 2 ;;
    esac

    if ! command -v "$CHECKSUM_CMD" &>/dev/null; then
        echo -e "${RED}错误: 找不到校验命令: $CHECKSUM_CMD${NC}"
        exit 2
    fi
}

# ---- 函数：构建文件清单（相对路径 + 大小）-----------------------------------------
build_file_list() {
    local dir="$1" output="$2" label="$3"

    echo -e "${CYAN}正在扫描 ${label}: ${dir}${NC}"
    (
        cd "$dir" || exit 1
        find . -type f -printf '%p\t%s\n' 2>/dev/null | sort
    ) > "$output"

    local count
    count=$(wc -l < "$output")
    echo -e "${GREEN}${label}: 发现 ${count} 个文件${NC}"
}

# ---- 函数：计算校验和 ----------------------------------------------------------
compute_checksums() {
    local dir="$1" file_list="$2" output="$3" label="$4"

    echo -e "${CYAN}正在计算 ${label} 校验和 (${CHECKSUM_METHOD})...${NC}"

    > "$output"  # 清空输出文件
    local count=0
    local total
    total=$(wc -l < "$file_list")

    while IFS=$'\t' read -r relpath size; do
        local fullpath="${dir}/${relpath#./}"
        if [[ -f "$fullpath" ]]; then
            local hash
            hash=$($CHECKSUM_CMD "$fullpath" 2>/dev/null | awk '{print $1}') || hash="ERROR"
            printf '%s\t%s\t%s\n' "$relpath" "$size" "$hash" >> "$output"

            if [[ "$VERBOSE" == true ]]; then
                printf '  [%d/%d] %s  %s\n' "$((++count))" "$total" "$hash" "$relpath"
            fi
        fi
        ((count++)) || true
    done < "$file_list"

    echo -e "${GREEN}${label} 校验和计算完成${NC}"
}

# ---- 函数：对比差异 ------------------------------------------------------------
compare_results() {
    echo
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║     🔍  备份完整性校验报告                    ║${NC}"
    echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  源目录   : ${SOURCE_DIR}"
    echo -e "${BOLD}${BLUE}║${NC}  备份目录 : ${BACKUP_DIR}"
    echo -e "${BOLD}${BLUE}║${NC}  校验方式 : ${CHECKSUM_METHOD}"
    echo -e "${BOLD}${BLUE}║${NC}  校验时间 : $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo

    # 统计数据
    local src_count bak_count
    src_count=$(wc -l < "$SOURCE_LIST")
    bak_count=$(wc -l < "$BACKUP_LIST")

    echo -e "${BOLD}文件数量:${NC}"
    echo -e "  源目录 : ${src_count}"
    echo -e "  备份目录: ${bak_count}"
    echo

    # 缺失文件
    local missing=0 extra=0 size_diff=0 hash_diff=0 match_ok=0

    echo -e "${BOLD}${CYAN}━━━ 差异分析 ━━━${NC}"

    # 备份中缺失的文件（源有，备份没有）
    echo -e "\n${YELLOW}备份中缺失的文件:${NC}"
    while IFS=$'\t' read -r relpath _; do
        local bak_path="${BACKUP_DIR}/${relpath#./}"
        if [[ ! -f "$bak_path" ]]; then
            echo -e "  ${RED}✗${NC} $relpath"
            ((missing++))
        fi
    done < "$SOURCE_LIST"

    if [[ "$missing" -eq 0 ]]; then
        echo -e "  ${GREEN}无${NC}"
    fi

    # 多余的文件（备份有，源没有）
    echo -e "\n${YELLOW}备份中多余的文件（源中已删除）:${NC}"
    while IFS=$'\t' read -r relpath _; do
        local src_path="${SOURCE_DIR}/${relpath#./}"
        if [[ ! -f "$src_path" ]]; then
            echo -e "  ${CYAN}?${NC} $relpath"
            ((extra++))
        fi
    done < "$BACKUP_LIST"

    if [[ "$extra" -eq 0 ]]; then
        echo -e "  ${GREEN}无${NC}"
    fi

    # 对比共同文件的校验和
    echo -e "\n${YELLOW}校验和不匹配的文件:${NC}"
    while IFS=$'\t' read -r relpath src_size src_hash; do
        local bak_full="${BACKUP_DIR}/${relpath#./}"
        if [[ -f "$bak_full" ]]; then
            local bak_hash bak_size
            bak_hash=$($CHECKSUM_CMD "$bak_full" 2>/dev/null | awk '{print $1}') || bak_hash="ERROR"
            bak_size=$(stat -c%s "$bak_full" 2>/dev/null || echo 0)

            if [[ "$src_hash" != "$bak_hash" ]]; then
                if [[ "$src_size" != "$bak_size" ]]; then
                    echo -e "  ${RED}✗${NC} $relpath (大小: ${src_size} → ${bak_size})"
                    ((size_diff++))
                else
                    echo -e "  ${RED}✗${NC} $relpath (大小相同但校验和不符)"
                    ((hash_diff++))
                fi
            else
                ((match_ok++))
            fi
        fi
    done < "$SOURCE_CHECKSUM"

    if [[ "$size_diff" -eq 0 && "$hash_diff" -eq 0 ]]; then
        echo -e "  ${GREEN}无${NC}"
    fi

    # ---- 汇总 ----
    echo
    echo -e "${BOLD}${BLUE}━━━ 校验汇总 ━━━${NC}"
    echo -e "  一致文件  : ${GREEN}${match_ok}${NC}"
    echo -e "  缺失文件  : ${RED}${missing}${NC}"
    echo -e "  多余文件  : ${CYAN}${extra}${NC}"
    echo -e "  大小不一致: ${RED}${size_diff}${NC}"
    echo -e "  校验和不符: ${RED}${hash_diff}${NC}"

    # 健康度
    local total_issues=$((missing + size_diff + hash_diff))
    if [[ "$total_issues" -eq 0 ]]; then
        echo -e "\n  ${GREEN}${BOLD}✅  备份完全一致，数据安全！${NC}"
        echo
        return 0
    else
        echo -e "\n  ${RED}${BOLD}⚠️   发现 ${total_issues} 处差异，请检查备份！${NC}"
        echo
        return 1
    fi
}

# ---- 函数：输出报告文件 ---------------------------------------------------------
write_report() {
    if [[ -n "$REPORT_FILE" ]]; then
        {
            # 将屏幕输出重定向到报告文件
            compare_results
        } > "$REPORT_FILE" 2>&1
        echo -e "${GREEN}报告已保存至: $REPORT_FILE${NC}"
    fi
}

# ---- 主流程 -------------------------------------------------------------------
main() {
    parse_args "$@"

    echo
    echo -e "${BOLD}${BLUE}═══ 备份完整性校验开始 ═══${NC}"
    echo -e "  校验方式: ${CHECKSUM_METHOD}\n"

    # 步骤 1：扫描文件列表
    build_file_list "$SOURCE_DIR" "$SOURCE_LIST" "源目录"
    build_file_list "$BACKUP_DIR" "$BACKUP_LIST" "备份目录"

    # 步骤 2：计算校验和
    compute_checksums "$SOURCE_DIR" "$SOURCE_LIST" "$SOURCE_CHECKSUM" "源目录"
    compute_checksums "$BACKUP_DIR" "$BACKUP_LIST" "$BACKUP_CHECKSUM" "备份目录"

    # 步骤 3：对比
    local ret=0
    if [[ -n "$REPORT_FILE" ]]; then
        write_report
    fi

    compare_results
    ret=$?

    echo -e "${BLUE}临时文件已清理${NC}"
    return $ret
}

main "$@"
