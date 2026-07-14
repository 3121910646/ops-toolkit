#!/usr/bin/env bash
#===============================================================================
#  server-health-check.sh  —  服务器一键健康巡检
#
#  用途：自动收集 CPU、内存、磁盘、网络、进程等关键指标，
#        输出彩色巡检报告，支持 JSON 格式对接监控系统。
#
#  用法：./server-health-check.sh [OPTIONS]
#  示例：./server-health-check.sh --cpu-threshold 90 --json
#
#  作者：吴申
#  版本：1.0.0
#  许可：MIT License
#===============================================================================

set -euo pipefail

# ---- 配置默认值 ---------------------------------------------------------------
CPU_THRESHOLD=80
MEM_THRESHOLD=85
DISK_THRESHOLD=80
LOAD_THRESHOLD_WARN=1.0
LOAD_THRESHOLD_CRIT=2.0
OUTPUT_FORMAT="text"   # text | json

# ---- 颜色定义 -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

# ---- 状态图标 ----------------------------------------------------------------
ICON_OK="✅"
ICON_WARN="⚠️"
ICON_CRIT="🔴"

# ---- 函数：使用说明 -----------------------------------------------------------
show_help() {
    cat << EOF
用法: $(basename "$0") [OPTIONS]

一键式服务器健康巡检，收集 CPU、内存、磁盘、网络、进程等关键指标，
输出带颜色标记的巡检报告。

OPTIONS:
  --cpu-threshold N    CPU 告警阈值，百分比（默认：80）
  --mem-threshold N    内存告警阈值，百分比（默认：85）
  --disk-threshold N   磁盘告警阈值，百分比（默认：80）
  --json               以 JSON 格式输出结果
  --help               显示此帮助信息

示例:
  $(basename "$0")                           # 使用默认阈值，文本输出
  $(basename "$0") --cpu-threshold 90        # 自定义CPU告警阈值
  $(basename "$0") --json                    # JSON格式输出

退出码:
  0  所有指标正常
  1  存在警告项
  2  存在严重告警
EOF
    exit 0
}

# ---- 函数：解析命令行参数 -------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cpu-threshold)
                CPU_THRESHOLD="$2"
                shift 2 ;;
            --mem-threshold)
                MEM_THRESHOLD="$2"
                shift 2 ;;
            --disk-threshold)
                DISK_THRESHOLD="$2"
                shift 2 ;;
            --json)
                OUTPUT_FORMAT="json"
                shift ;;
            --help)
                show_help ;;
            *)
                echo "错误: 未知选项 $1，使用 --help 查看帮助"
                exit 1 ;;
        esac
    done
}

# ---- 函数：获取状态色 ----------------------------------------------------------
get_status() {
    # $1=当前值  $2=警告阈值  $3=严重阈值(可选)
    local val="${1%.*}" warn="${2%.*}" crit="${3:-$((warn + 15))}"
    crit="${crit%.*}"

    if [[ "$val" -ge "$crit" ]]; then
        echo "CRIT"
    elif [[ "$val" -ge "$warn" ]]; then
        echo "WARN"
    else
        echo "OK"
    fi
}

colorize() {
    local status="$1" text="$2"
    case "$status" in
        OK)   echo -e "${GREEN}${text}${NC}" ;;
        WARN) echo -e "${YELLOW}${text}${NC}" ;;
        CRIT) echo -e "${RED}${text}${NC}" ;;
        *)    echo "$text" ;;
    esac
}

# ---- 函数：采集CPU ------------------------------------------------------------
check_cpu() {
    local usage
    usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    usage=$(printf "%.1f" "$usage")
    local status
    status=$(get_status "$usage" "$CPU_THRESHOLD" "$((CPU_THRESHOLD + 10))")

    CPU_USAGE="$usage"
    CPU_STATUS="$status"
}

# ---- 函数：采集内存 ------------------------------------------------------------
check_memory() {
    local total used avail usage_pct
    read -r total used avail <<< "$(free -m | awk 'NR==2 {print $2, $3, $7}')"
    usage_pct=$(awk "BEGIN {printf \"%.1f\", ($used/$total)*100}")
    local status
    status=$(get_status "$usage_pct" "$MEM_THRESHOLD" "$((MEM_THRESHOLD + 10))")

    MEM_TOTAL="$total"
    MEM_USED="$used"
    MEM_AVAIL="$avail"
    MEM_USAGE="$usage_pct"
    MEM_STATUS="$status"
}

# ---- 函数：采集磁盘 ------------------------------------------------------------
check_disk() {
    local worst_status="OK"
    DISK_INFO=""
    DISK_JSON=""

    while IFS= read -r line; do
        local fs use_pct mount
        fs=$(echo "$line" | awk '{print $1}')
        use_pct=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        mount=$(echo "$line" | awk '{print $6}')

        local status
        status=$(get_status "$use_pct" "$DISK_THRESHOLD" "$((DISK_THRESHOLD + 10))")

        DISK_INFO+="  $(printf '%-15s %-20s %s%%  %s' "$fs" "$mount" "$use_pct" "$(colorize "$status" "$status")")\n"

        if [[ "$status" == "CRIT" ]]; then worst_status="CRIT"; fi
        if [[ "$status" == "WARN" && "$worst_status" != "CRIT" ]]; then worst_status="WARN"; fi
    done < <(df -h | grep '^/dev/' | grep -vE 'boot|tmpfs')

    DISK_STATUS="$worst_status"
}

# ---- 函数：采集系统负载 ---------------------------------------------------------
check_load() {
    local load1 load5
    read -r load1 load5 _ < /proc/loadavg
    local cores
    cores=$(nproc)
    local normalized
    normalized=$(awk "BEGIN {printf \"%.2f\", $load1/$cores}")

    local status
    if awk "BEGIN {exit !($load1 > $cores * $LOAD_THRESHOLD_CRIT)}"; then
        status="CRIT"
    elif awk "BEGIN {exit !($load1 > $cores * $LOAD_THRESHOLD_WARN)}"; then
        status="WARN"
    else
        status="OK"
    fi

    LOAD1="$load1"
    LOAD5="$load5"
    LOAD_CORES="$cores"
    LOAD_NORMALIZED="$normalized"
    LOAD_STATUS="$status"
}

# ---- 函数：采集进程/连接数 -----------------------------------------------------
check_processes() {
    PROC_TOTAL=$(ps aux | wc -l)
    PROC_ZOMBIE=$(ps aux | awk '{print $8}' | grep -c 'Z' || true)
    TCP_CONNS=$(ss -tan | grep -c ESTAB || true)
    OPEN_FILES=$(( $(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}') || echo 0 ))
}

# ---- 函数：采集网络 ------------------------------------------------------------
check_network() {
    local default_if
    default_if=$(ip route 2>/dev/null | grep '^default' | awk '{print $5}' | head -1)
    NET_IFACE="${default_if:-N/A}"

    # 检查关键端口
    local failed_ports=""
    for port in 22 80 443; do
        if ! ss -tln | grep -q ":$port "; then
            failed_ports+="$port "
        fi
    done
    NET_FAILED_PORTS="${failed_ports:-无}"
}

# ---- 函数：输出文本格式报告 -----------------------------------------------------
print_text_report() {
    local hostname
    hostname=$(hostname)
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null | sed 's/^up //' || echo "N/A")
    local datetime
    datetime=$(date '+%Y-%m-%d %H:%M:%S')

    echo
    echo -e "${BOLD}${BLUE}  ╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}  ║     🖥   服务器健康巡检报告               ║${NC}"
    echo -e "${BOLD}${BLUE}  ╠══════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${BLUE}  ║${NC}  主机名   : ${hostname}"
    echo -e "${BOLD}${BLUE}  ║${NC}  巡检时间 : ${datetime}"
    echo -e "${BOLD}${BLUE}  ║${NC}  运行时间 : ${uptime_str}"
    echo -e "${BOLD}${BLUE}  ╠══════════════════════════════════════════╣${NC}"

    # CPU
    local cpu_line="  ║  CPU 使用 : ${CPU_USAGE}%  $(colorize "$CPU_STATUS" "$CPU_STATUS")"
    printf "%b%-$(( 48 - $(echo -ne "$cpu_line" | wc -c) + ${#cpu_line}))s%b\n" "$cpu_line" "" "${BOLD}${BLUE}║${NC}"
    echo

    # 内存
    local mem_line="  ║  内存使用 : ${MEM_USAGE}% (已用${MEM_USED}M / 总计${MEM_TOTAL}M)  $(colorize "$MEM_STATUS" "$MEM_STATUS")"
    printf "%b%-$(( 48 - $(echo -ne "$mem_line" | wc -c) + ${#mem_line}))s%b\n" "$mem_line" "" "${BOLD}${BLUE}║${NC}"
    echo

    # 磁盘
    echo -e "${BOLD}${BLUE}  ║${NC}  磁盘使用 :"
    echo -e "$DISK_INFO" | while IFS= read -r dline; do
        [[ -z "$dline" ]] && continue
        echo -e "${BOLD}${BLUE}  ║${NC}$dline"
    done

    # 负载
    local load_line="  ║  系统负载 : ${LOAD1} (${LOAD_NORMALIZED}/核心) ${LOAD_CORES}核  $(colorize "$LOAD_STATUS" "$LOAD_STATUS")"
    printf "%b%-$(( 48 - $(echo -ne "$load_line" | wc -c) + ${#load_line}))s%b\n" "$load_line" "" "${BOLD}${BLUE}║${NC}"
    echo

    echo -e "${BOLD}${BLUE}  ╠══════════════════════════════════════════╣${NC}"
    local proc_line="  ║  进程总数 : ${PROC_TOTAL}  |  僵尸进程 : ${PROC_ZOMBIE}"
    printf "%b%-$(( 48 - $(echo -ne "$proc_line" | wc -c) + ${#proc_line}))s%b\n" "$proc_line" "" "${BOLD}${BLUE}║${NC}"
    echo
    local conn_line="  ║  TCP连接  : ${TCP_CONNS} (ESTABLISHED)  |  文件句柄: ${OPEN_FILES}"
    printf "%b%-$(( 48 - $(echo -ne "$conn_line" | wc -c) + ${#conn_line}))s%b\n" "$conn_line" "" "${BOLD}${BLUE}║${NC}"
    echo
    local net_line="  ║  网卡     : ${NET_IFACE}  |  端口异常 : ${NET_FAILED_PORTS}"
    printf "%b%-$(( 48 - $(echo -ne "$net_line" | wc -c) + ${#net_line}))s%b\n" "$net_line" "" "${BOLD}${BLUE}║${NC}"
    echo

    echo -e "${BOLD}${BLUE}  ╚══════════════════════════════════════════╝${NC}"
    echo

    # 汇总
    local worst="OK"
    for s in "$CPU_STATUS" "$MEM_STATUS" "$DISK_STATUS" "$LOAD_STATUS"; do
        [[ "$s" == "CRIT" ]] && { worst="CRIT"; break; }
        [[ "$s" == "WARN" && "$worst" != "CRIT" ]] && worst="WARN"
    done

    echo -n "  巡检结论: "
    case "$worst" in
        OK)   echo -e "${GREEN}所有指标正常 ✓${NC}" ;;
        WARN) echo -e "${YELLOW}存在告警项，建议关注 ⚠${NC}" ;;
        CRIT) echo -e "${RED}存在严重告警，请立即处理 🔴${NC}" ;;
    esac
    echo

    case "$worst" in
        OK)   return 0 ;;
        WARN) return 1 ;;
        CRIT) return 2 ;;
    esac
}

# ---- 函数：输出 JSON 格式报告 ---------------------------------------------------
print_json_report() {
    local datetime
    datetime=$(date -Iseconds)

    cat << EOF
{
  "hostname": "$(hostname)",
  "timestamp": "$datetime",
  "uptime": "$(uptime -p 2>/dev/null | sed 's/^up //' || echo 'N/A')",
  "cpu": {
    "usage_pct": $CPU_USAGE,
    "status": "$CPU_STATUS"
  },
  "memory": {
    "total_mb": $MEM_TOTAL,
    "used_mb": $MEM_USED,
    "available_mb": $MEM_AVAIL,
    "usage_pct": $MEM_USAGE,
    "status": "$MEM_STATUS"
  },
  "disk": {
    "status": "$DISK_STATUS"
  },
  "load": {
    "load1": $LOAD1,
    "load5": $LOAD5,
    "cores": $LOAD_CORES,
    "normalized": $LOAD_NORMALIZED,
    "status": "$LOAD_STATUS"
  },
  "processes": {
    "total": $PROC_TOTAL,
    "zombie": $PROC_ZOMBIE
  },
  "network": {
    "interface": "$NET_IFACE",
    "tcp_established": $TCP_CONNS,
    "failed_ports": "$NET_FAILED_PORTS"
  },
  "open_files": $OPEN_FILES
}
EOF
}

# ---- 主流程 -------------------------------------------------------------------
main() {
    parse_args "$@"

    check_cpu
    check_memory
    check_disk
    check_load
    check_processes
    check_network

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        print_json_report
    else
        print_text_report
    fi
}

main "$@"
