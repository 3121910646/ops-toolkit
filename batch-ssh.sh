#!/usr/bin/env bash
#===============================================================================
#  batch-ssh.sh  —  批量 SSH 远程执行命令
#
#  用途：从主机列表文件读取 IP，并行 SSH 执行命令，聚合返回结果。
#        适合集群巡检、批量配置下发、多机信息收集等场景。
#
#  用法：./batch-ssh.sh [OPTIONS]
#  示例：./batch-ssh.sh --hosts hosts.txt --cmd "df -h /"
#
#  作者：吴申
#  版本：1.0.0
#  许可：MIT License
#===============================================================================

set -euo pipefail

# ---- 配置默认值 ---------------------------------------------------------------
HOSTS_FILE=""
CMD=""
SSH_USER="${SSH_USER:-root}"
SSH_PORT=22
SSH_TIMEOUT=10
PARALLEL=10
CMD_TIMEOUT=30
OUTPUT_DIR=""

# ---- 颜色定义 -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 临时目录 -----------------------------------------------------------------
TMP_DIR=$(mktemp -d -t batch-ssh.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---- 函数：使用说明 -----------------------------------------------------------
show_help() {
    cat << EOF
用法: $(basename "$0") [OPTIONS]

批量 SSH 远程执行命令，支持并行执行和结果聚合。

OPTIONS:
  --hosts FILE      主机列表文件，每行一个 IP 或 hostname（必填）
  --cmd "COMMAND"   要远程执行的命令（必填）
  --user USER       SSH 用户名（默认：root，也可设环境变量 SSH_USER）
  --port PORT       SSH 端口（默认：22）
  --parallel N      最大并发数（默认：10）
  --timeout N       单台主机命令超时秒数（默认：30）
  --output DIR      将每台主机的输出保存到指定目录
  --help            显示此帮助信息

主机列表文件格式（支持 # 注释）:
  192.168.1.10
  192.168.1.11    # web-server-01
  192.168.1.12

示例:
  $(basename "$0") --hosts servers.txt --cmd "uptime"
  $(basename "$0") --hosts cluster.txt --cmd "docker ps" --user ops --parallel 20
  $(basename "$0") --hosts all.txt --cmd "df -h /" --output ./batch_output
  SSH_USER=ops $(basename "$0") --hosts hosts.txt --cmd "free -m"

安全提示:
  建议配置 SSH 密钥认证，避免在命令行暴露密码。
  如必须使用密码，请配合 sshpass: SSHPASS=xxx $(basename "$0") ...
EOF
    exit 0
}

# ---- 函数：解析参数 ------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hosts)    HOSTS_FILE="$2";   shift 2 ;;
            --cmd)      CMD="$2";          shift 2 ;;
            --user)     SSH_USER="$2";     shift 2 ;;
            --port)     SSH_PORT="$2";     shift 2 ;;
            --parallel) PARALLEL="$2";     shift 2 ;;
            --timeout)  CMD_TIMEOUT="$2";  shift 2 ;;
            --output)   OUTPUT_DIR="$2";   shift 2 ;;
            --help)     show_help ;;
            *)
                echo -e "${RED}错误: 未知选项 $1${NC}"
                echo "使用 --help 查看帮助"
                exit 1 ;;
        esac
    done

    if [[ -z "$HOSTS_FILE" ]]; then
        echo -e "${RED}错误: 必须指定 --hosts 主机列表文件${NC}"
        exit 1
    fi
    if [[ -z "$CMD" ]]; then
        echo -e "${RED}错误: 必须指定 --cmd 要执行的命令${NC}"
        exit 1
    fi
    if [[ ! -f "$HOSTS_FILE" ]]; then
        echo -e "${RED}错误: 主机列表文件不存在: $HOSTS_FILE${NC}"
        exit 1
    fi

    # 准备输出目录
    if [[ -n "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
    fi
}

# ---- 函数：解析主机列表 ---------------------------------------------------------
load_hosts() {
    local hosts=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去除行首行尾空白
        line=$(echo "$line" | xargs)
        # 跳过空行和注释行
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        # 取第一个字段（IP/主机名）
        local host
        host=$(echo "$line" | awk '{print $1}')
        hosts+=("$host")
    done < "$HOSTS_FILE"

    if [[ ${#hosts[@]} -eq 0 ]]; then
        echo -e "${RED}错误: 主机列表为空${NC}"
        exit 1
    fi

    printf '%s\n' "${hosts[@]}"
}

# ---- 函数：对单台主机执行命令 ---------------------------------------------------
ssh_exec() {
    local host="$1"
    local id="$2"
    local output_file="${TMP_DIR}/${id}.output"
    local status_file="${TMP_DIR}/${id}.status"
    local start_time end_time duration

    start_time=$(date +%s%N)

    # SSH 执行
    if ssh \
        -o "ConnectTimeout=${SSH_TIMEOUT}" \
        -o "StrictHostKeyChecking=no" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "BatchMode=yes" \
        -o "LogLevel=ERROR" \
        -p "$SSH_PORT" \
        "${SSH_USER}@${host}" \
        "timeout ${CMD_TIMEOUT} bash -s" 2>&1 <<< "$CMD"
    then
        # 成功
        end_time=$(date +%s%N)
        duration=$(( (end_time - start_time) / 1000000 ))  # 毫秒
        echo "SUCCESS" > "$status_file"
        printf '[%s] host=%s status=SUCCESS time=%dms\n' "$(date '+%H:%M:%S')" "$host" "$duration"
    else
        # 失败
        end_time=$(date +%s%N)
        duration=$(( (end_time - start_time) / 1000000 ))
        echo "FAILED" > "$status_file"
        printf '[%s] host=%s status=FAILED time=%dms\n' "$(date '+%H:%M:%S')" "$host" "$duration"
    fi > "$output_file"
}

# ---- 函数：并行执行 ------------------------------------------------------------
run_parallel() {
    local hosts=("$@")
    local total=${#hosts[@]}
    local running=0
    local i=0
    local pids=()

    echo -e "${BOLD}目标主机: ${total} 台  |  并发数: ${PARALLEL}  |  命令: ${CMD}${NC}"
    echo

    for host in "${hosts[@]}"; do
        # 等待直到有可用槽位
        while [[ "$running" -ge "$PARALLEL" ]]; do
            # 收割已完成的后台任务
            for j in "${!pids[@]}"; do
                if ! kill -0 "${pids[$j]}" 2>/dev/null; then
                    wait "${pids[$j]}" 2>/dev/null || true
                    unset "pids[$j]"
                    ((running--))
                fi
            done
            sleep 0.1
        done

        ssh_exec "$host" "$i" &
        pids+=($!)
        ((running++))
        ((i++))
    done

    # 等待所有任务完成
    echo -e "${CYAN}等待所有任务完成...${NC}"
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    echo
}

# ---- 函数：汇总结果 ------------------------------------------------------------
summarize() {
    local total="$1"
    local success=0 failed=0

    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║     📋  批量 SSH 执行结果                    ║${NC}"
    echo -e "${BOLD}${BLUE}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  总主机数 : ${total}"
    echo -e "${BOLD}${BLUE}║${NC}  执行命令 : ${CMD}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo

    # 读取每台主机的执行结果
    for i in $(seq 0 $((total - 1))); do
        local output_file="${TMP_DIR}/${i}.output"
        local status_file="${TMP_DIR}/${i}.status"

        if [[ -f "$status_file" ]]; then
            local status
            status=$(cat "$status_file")
            if [[ "$status" == "SUCCESS" ]]; then
                ((success++))
            else
                ((failed++))
            fi
        else
            status="UNKNOWN"
            ((failed++))
        fi

        if [[ -f "$output_file" ]]; then
            cat "$output_file"
        fi

        # 单独保存到输出目录
        if [[ -n "$OUTPUT_DIR" && -f "$output_file" ]]; then
            # 从输出第一行提取 host
            local host_line
            host_line=$(head -1 "$output_file")
            local hostname
            hostname=$(echo "$host_line" | grep -oP 'host=\K\S+')
            if [[ -n "$hostname" ]]; then
                cp "$output_file" "${OUTPUT_DIR}/${hostname}.log"
            fi
        fi
    done

    # 汇总
    echo
    echo -e "${BOLD}${BLUE}━━━ 执行汇总 ━━━${NC}"
    echo -e "  成功: ${GREEN}${success}${NC}"
    echo -e "  失败: ${RED}${failed}${NC}"
    echo -e "  成功率: $(awk "BEGIN {printf \"%.1f\", $success/$total*100}")%"

    if [[ -n "$OUTPUT_DIR" ]]; then
        echo -e "\n  详细输出已保存至: ${OUTPUT_DIR}/"
    fi
    echo

    if [[ "$failed" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✅  所有主机执行成功！${NC}"
        return 0
    else
        echo -e "${RED}${BOLD}⚠️   ${failed} 台主机执行失败，请检查！${NC}"
        return 1
    fi
}

# ---- 主流程 -------------------------------------------------------------------
main() {
    parse_args "$@"

    echo
    echo -e "${BOLD}${BLUE}═══ 批量 SSH 执行开始 ═══${NC}"
    echo

    # 加载主机列表
    local hosts
    mapfile -t hosts < <(load_hosts)
    local total=${#hosts[@]}

    if [[ "$total" -eq 0 ]]; then
        echo -e "${RED}没有有效的主机${NC}"
        exit 1
    fi

    # 并行执行
    run_parallel "${hosts[@]}"

    # 汇总结果
    summarize "$total"
}

main "$@"
