#!/usr/bin/env bash
#===============================================================================
#  nginx-log-analyzer.sh  —  Nginx 访问日志深度分析
#
#  用途：分析 Nginx access.log，统计 PV/UV、状态码分布、TOP IP/URL、
#        响应时间分布、异常请求检测。适合日常流量分析和故障排查。
#
#  用法：./nginx-log-analyzer.sh [OPTIONS]
#  示例：./nginx-log-analyzer.sh --log-file /var/log/nginx/access.log --top-ip 20
#
#  作者：吴申
#  版本：1.0.0
#  许可：MIT License
#
#  注意：支持 Combined Log Format（Nginx 默认格式）
#===============================================================================

set -euo pipefail

# ---- 配置默认值 ---------------------------------------------------------------
LOG_FILE="/var/log/nginx/access.log"
TOP_N=20
SINCE=""
UNTIL=""
FILTER_4XX=false
FILTER_5XX=false
FILTER_SLOW_S=0
OUTPUT_FORMAT="text"

# ---- 颜色定义 -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 函数：使用说明 -----------------------------------------------------------
show_help() {
    cat << EOF
用法: $(basename "$0") [OPTIONS]

分析 Nginx 访问日志，输出流量统计、状态码分布、TOP IP/URL、响应时间等。

OPTIONS:
  --log-file FILE      日志文件路径（默认：/var/log/nginx/access.log）
  --top-ip N           显示 TOP N 的 IP 地址（默认：20）
  --since "DATE"       分析起始日期，如 "2024-06-01 00:00"
  --until "DATE"       分析截止日期，如 "2024-06-30 23:59"
  --status-4xx         仅显示 4xx 状态码的请求
  --status-5xx         仅显示 5xx 状态码的请求
  --slow N             仅显示响应时间超过 N 秒的请求
  --help               显示此帮助信息

示例:
  $(basename "$0") --log-file /var/log/nginx/access.log
  $(basename "$0") --log-file access.log --top-ip 30 --slow 3
  $(basename "$0") --log-file access.log --since "2024-06-01" --status-5xx

Nginx 日志格式要求（Combined Log Format）:
  log_format combined '\$remote_addr - \$remote_user [\$time_local] '
                      '"\$request" \$status \$body_bytes_sent '
                      '"\$http_referer" "\$http_user_agent" \$request_time';
EOF
    exit 0
}

# ---- 函数：解析参数 ------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --log-file)   LOG_FILE="$2";   shift 2 ;;
            --top-ip)     TOP_N="$2";      shift 2 ;;
            --since)      SINCE="$2";      shift 2 ;;
            --until)      UNTIL="$2";      shift 2 ;;
            --status-4xx) FILTER_4XX=true; shift ;;
            --status-5xx) FILTER_5XX=true; shift ;;
            --slow)       FILTER_SLOW_S="$2"; shift 2 ;;
            --help)       show_help ;;
            *)
                echo -e "${RED}错误: 未知选项 $1${NC}"
                echo "使用 --help 查看帮助"
                exit 1 ;;
        esac
    done

    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${RED}错误: 日志文件不存在: $LOG_FILE${NC}"
        exit 1
    fi
}

# ---- 函数：过滤日志内容 ---------------------------------------------------------
filter_log() {
    local awk_script=''

    # 如果有日期过滤，构造 awk 规则
    if [[ -n "$SINCE" || -n "$UNILT" || "$FILTER_4XX" == true || "$FILTER_5XX" == true || "$FILTER_SLOW_S" -gt 0 ]]; then
        awk_script=''
        [[ -n "$SINCE" ]] && awk_script+="\$4 >= \"[$SINCE\" && "
        [[ -n "$UNILT" ]]  && awk_script+="\$4 <= \"[$UNTIL\" && "
        [[ "$FILTER_4XX" == true ]] && awk_script+='$9 ~ /^4[0-9]{2}$/ && '
        [[ "$FILTER_5XX" == true ]] && awk_script+='$9 ~ /^5[0-9]{2}$/ && '
        [[ "$FILTER_SLOW_S" -gt 0 ]] && awk_script+="\$NF > $FILTER_SLOW_S && "
        awk_script="${awk_script% && }"  # 去掉末尾的 " && "

        # 如果没有任何过滤条件，awk 脚本就是 {print}
        [[ -z "$awk_script" ]] && awk_script='1'
    fi

    if [[ -n "$awk_script" ]]; then
        awk "$awk_script {print}" "$LOG_FILE"
    else
        cat "$LOG_FILE"
    fi
}

# ---- 函数：分析并输出报告 -------------------------------------------------------
analyze() {
    local data
    data=$(filter_log)
    local total_lines
    total_lines=$(echo "$data" | wc -l)

    if [[ "$total_lines" -eq 0 ]]; then
        echo -e "${YELLOW}没有匹配条件的日志记录${NC}"
        exit 0
    fi

    echo
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║     📊  Nginx 访问日志分析报告               ║${NC}"
    echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  日志文件 : ${LOG_FILE}"
    echo -e "${BOLD}${BLUE}║${NC}  匹配行数 : ${total_lines}"
    [[ -n "$SINCE" ]] && echo -e "${BOLD}${BLUE}║${NC}  时间范围 : ${SINCE} ~ ${UNTIL:-至今}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo

    # ---- 1. 总体统计 ----
    echo -e "${BOLD}${CYAN}━━━ 总体统计 ━━━${NC}"

    # PV (按天)
    echo -e "\n${BOLD}日均 PV:${NC}"
    echo "$data" | awk '{print $4}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -10 | \
        awk '{printf "  %s  %s 次\n", $2, $1}'

    # UV（按 IP）
    local uv
    uv=$(echo "$data" | awk '{print $1}' | sort -u | wc -l)
    local pv="$total_lines"
    echo -e "\n${BOLD}总 PV:${NC} ${pv}  ${BOLD}总 UV:${NC} ${uv}  ${BOLD}人均 PV:${NC} $(awk "BEGIN {printf \"%.1f\", $pv/$uv}")"

    # ---- 2. 状态码分布 ----
    echo -e "\n${BOLD}${CYAN}━━━ 状态码分布 ━━━${NC}"
    echo "$data" | awk '{print $9}' | sort | uniq -c | sort -rn | \
        awk -v RED="$RED" -v YELLOW="$YELLOW" -v GREEN="$GREEN" -v NC="$NC" '{
            total += $1
            if ($2 ~ /^2/) code_color=GREEN
            else if ($2 ~ /^3/) code_color=YELLOW
            else if ($2 ~ /^4/) code_color=YELLOW
            else if ($2 ~ /^5/) code_color=RED
            else code_color=NC
            printf "  %s%s%s  %s 次  (%.1f%%)\n", code_color, $2, NC, $1, 0
        }'
    echo "$data" | awk '{print $9}' | sort | uniq -c | sort -rn | \
        awk -v total="$total_lines" '{
            if ($2 ~ /^2/) icon="✅"
            else if ($2 ~ /^3/) icon="↪️ "
            else if ($2 ~ /^4/) icon="⚠️ "
            else if ($2 ~ /^5/) icon="🔴"
            else icon="  "
            printf "  %s  %s  %8s 次  (%5.1f%%)\n", icon, $2, $1, ($1/total)*100
        }'

    # ---- 3. TOP IP ----
    echo -e "\n${BOLD}${CYAN}━━━ TOP ${TOP_N} IP 地址 ━━━${NC}"
    echo "$data" | awk '{print $1}' | sort | uniq -c | sort -rn | head -"$TOP_N" | \
        awk '{printf "  %-18s %s 次\n", $2, $1}'

    # ---- 4. TOP URL ----
    echo -e "\n${BOLD}${CYAN}━━━ TOP ${TOP_N} 请求 URL ━━━${NC}"
    echo "$data" | awk '{print $7}' | sort | uniq -c | sort -rn | head -"$TOP_N" | \
        awk '{
            url = $2
            if (length(url) > 60) url = substr(url, 1, 57) "..."
            printf "  %-62s %s 次\n", url, $1
        }'

    # ---- 5. 响应时间分布 ----
    echo -e "\n${BOLD}${CYAN}━━━ 响应时间分布 ━━━${NC}"
    echo "$data" | awk '{
        t = $NF + 0
        if (t < 0.1) fast++
        else if (t < 0.5) normal++
        else if (t < 1) moderate++
        else if (t < 3) slow++
        else very_slow++
        total++
    }
    END {
        printf "  < 0.1s  (极快) : %6d  (%5.1f%%)\n", fast+0, (fast+0)/total*100
        printf "  0.1-0.5s(正常) : %6d  (%5.1f%%)\n", normal+0, (normal+0)/total*100
        printf "  0.5-1s  (一般) : %6d  (%5.1f%%)\n", moderate+0, (moderate+0)/total*100
        printf "  1-3s    (慢)   : %6d  (%5.1f%%)\n", slow+0, (slow+0)/total*100
        printf "  > 3s    (极慢) : %6d  (%5.1f%%)\n", very_slow+0, (very_slow+0)/total*100
    }'

    # ---- 6. 异常请求 ----
    echo -e "\n${BOLD}${CYAN}━━━ 异常请求检测 ━━━${NC}"

    # 4xx 占比
    local count_4xx
    count_4xx=$(echo "$data" | awk '$9 ~ /^4/{print $9}' | wc -l)
    # 5xx 占比
    local count_5xx
    count_5xx=$(echo "$data" | awk '$9 ~ /^5/{print $9}' | wc -l)

    echo -e "  4xx 错误: ${count_4xx} 次 ($(awk "BEGIN {printf \"%.2f\", $count_4xx/$total_lines*100}")%)"
    echo -e "  5xx 错误: ${count_5xx} 次 ($(awk "BEGIN {printf \"%.2f\", $count_5xx/$total_lines*100}")%)"

    # 慢请求 TOP 10
    echo -e "\n  ${BOLD}最慢的 10 个请求:${NC}"
    echo "$data" | awk '{
        url = $7
        time = $NF + 0
        print time, $1, url, $9
    }' | sort -rn | head -10 | \
        awk -v RED="$RED" -v YELLOW="$YELLOW" -v NC="$NC" '{
            color = $1 > 3 ? RED : ($1 > 1 ? YELLOW : "")
            printf "  %s%5.2fs%s  %-16s  %s  %s\n", color, $1, NC, $2, $3, $4
        }'

    echo
}

# ---- 主流程 -------------------------------------------------------------------
main() {
    parse_args "$@"
    analyze
}

main "$@"
