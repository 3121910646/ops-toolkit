# 🧰 ops-toolkit

> 一套面向运维工程师的 Shell 脚本工具箱 —— 覆盖服务器巡检、日志管理、Nginx 分析、备份校验、批量操作等日常运维场景。

[![ShellCheck](https://img.shields.io/badge/ShellCheck-passed-brightgreen)](https://www.shellcheck.net/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20CentOS-blue)](https://www.centos.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

---

## 📖 这是什么？

在实际运维工作中，我积累了大量的 Shell 脚本用于自动化日常操作。这个仓库将这些脚本**脱敏、规范化、加注释**后公开，分享给运维同行，同时也作为我技术能力的实际证明。

每个脚本都遵循：
- ✅ `set -euo pipefail` 严格错误处理
- ✅ 完整的 `--help` 使用说明
- ✅ 终端彩色输出，日志可读
- ✅ 通过 [ShellCheck](https://www.shellcheck.net/) 静态检查

---

## 📂 工具箱清单

| 脚本 | 用途 | 适用场景 |
|---|---|---|
| `server-health-check.sh` | 服务器一键健康巡检 | 每日巡检 / 上线前检查 |
| `log-archiver.sh` | 日志自动归档 + 过期清理 | 日志管理 / 磁盘空间告警 |
| `nginx-log-analyzer.sh` | Nginx 访问日志深度分析 | 流量分析 / 故障排查 |
| `backup-validator.sh` | 备份文件完整性校验 | 灾备演练 / 每日备份验证 |
| `batch-ssh.sh` | 批量 SSH 远程执行命令 | 集群操作 / 批量配置下发 |

---

## 🚀 快速开始

```bash
# 克隆仓库
git clone git@github.com:YOUR_USERNAME/ops-toolkit.git
cd ops-toolkit

# 赋予执行权限
chmod +x *.sh

# 查看任意脚本的帮助
./server-health-check.sh --help
```

---

## 📸 运行截图

> 建议在此放置 `asciinema` 或 `terminalizer` 录制的终端 GIF/截图

```
$ ./server-health-check.sh

  ╔════════════════════════════════════╗
  ║     🖥  服务器健康巡检报告          ║
  ╠════════════════════════════════════╣
  ║  主机名   : web-server-01          ║
  ║  CPU 使用 : 23.5%  ✅              ║
  ║  内存使用 : 67.2%  ⚠️  (偏高)      ║
  ║  磁盘使用 : /dev/sda1  45%  ✅     ║
  ║  系统负载 : 0.82   ✅              ║
  ║  运行时间 : 128 days 23 hours      ║
  ╚════════════════════════════════════╝
```

---

## 🛠 依赖环境

- **操作系统**：Linux（CentOS 7+ / Ubuntu 18.04+ 测试通过）
- **Shell**：Bash 4.0+
- **外部工具**：`awk`, `sed`, `grep`, `curl`（系统默认自带）

---

## 📋 脚本详细说明

### 1. server-health-check.sh

**一键式服务器健康巡检**，自动收集 CPU、内存、磁盘、网络、进程等关键指标，输出带颜色标记的报告。

```
用法: ./server-health-check.sh [OPTIONS]

选项:
  --cpu-threshold 80       CPU告警阈值（默认80%）
  --mem-threshold 85       内存告警阈值（默认85%）
  --disk-threshold 80      磁盘告警阈值（默认80%）
  --json                  以JSON格式输出（适合对接监控系统）
  --help                  显示此帮助信息
```

### 2. log-archiver.sh

**日志自动归档与清理**，支持按天数/大小两种策略，自动压缩打包，通过 `find` 清理过期文件。

```
用法: ./log-archiver.sh [OPTIONS]

选项:
  --source-dir /var/log   日志目录
  --archive-dir /backup   归档目录
  --retention 30          保留天数（默认30天）
  --max-size 1024         单日志文件最大M数，超过则强制归档
  --dry-run               模拟运行，不实际操作
  --help                  显示此帮助信息
```

### 3. nginx-log-analyzer.sh

**Nginx 访问日志分析器**，统计 PV/UV、状态码分布、TOP IP、响应时间分段、异常请求等。

```
用法: ./nginx-log-analyzer.sh [OPTIONS]

选项:
  --log-file /var/log/nginx/access.log   日志文件路径
  --top-ip 20                            显示TOP N的IP（默认20）
  --since "2024-06-01"                   分析起始日期
  --status-4xx                           仅显示4xx错误
  --help                                 显示此帮助信息
```

### 4. backup-validator.sh

**备份完整性校验**，对比源目录与备份目录的文件数量、大小、MD5 校验和，生成差异报告。

```
用法: ./backup-validator.sh [OPTIONS]

选项:
  --source /data           源目录
  --backup /backup/data    备份目录
  --checksum md5           校验方式：md5 / sha256
  --report report.txt      输出报告路径
  --help                  显示此帮助信息
```

### 5. batch-ssh.sh

**批量 SSH 操作**，从主机列表文件读取 IP，并行执行命令，聚合返回结果。

```
用法: ./batch-ssh.sh [OPTIONS]

选项:
  --hosts hosts.txt       主机列表文件（每行一个IP）
  --cmd "uptime"          要执行的命令
  --user root             SSH用户名
  --parallel 10           并发数（默认10）
  --timeout 30            单机超时秒数（默认30）
  --help                 显示此帮助信息
```

---

## 🤝 贡献

欢迎提 Issue 和 PR！如果你有常用的运维脚本，也欢迎贡献到这个工具箱。

---

## 📄 协议

MIT License © 2024 吴申

---

> 💡 **运维的核心不是修故障，而是让故障不发生。**
