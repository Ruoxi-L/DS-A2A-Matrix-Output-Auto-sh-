#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="${GPU_WATCH_BASE_DIR:-$HOME/gpu_watch}"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$LOG_DIR"

TASK_LOG="$LOG_DIR/task_$(date '+%Y%m%d_%H%M%S').log"

exec > >(tee -a "$TASK_LOG") 2>&1

echo "============================================================"
echo "Task launcher started"
echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
echo "host=$(hostname -s)"
echo "user=$(id -un)"
echo "pid=$$"
echo "log=$TASK_LOG"
echo "============================================================"


# ============================================================
# 用户修改区
# ============================================================
#
# 把下面两个变量替换成已经人工验证可以正常运行的任务命令。
#
# 跨机任务通常应在这里完成：
#   1. 启动远程 worker
#   2. 检查远程 worker 是否成功
#   3. 启动本地 head
#   4. 保存两个节点的日志和 PID
#
# 不要在这里：
#   - 使用 sudo
#   - kill 不确定归属的进程
#   - 清理其他用户的容器或文件
# ============================================================

WORKDIR="$HOME/REPLACE_WITH_PROJECT_DIRECTORY"

TASK_COMMAND=(
    bash
    run.sh
)

# ============================================================
# 用户修改区结束
# ============================================================


if [[ "$WORKDIR" == *"REPLACE_WITH_PROJECT_DIRECTORY"* ]]; then
    echo "ERROR: WORKDIR has not been configured"
    exit 2
fi

if [[ ! -d "$WORKDIR" ]]; then
    echo "ERROR: work directory does not exist: $WORKDIR"
    exit 2
fi

cd "$WORKDIR"

echo "workdir=$PWD"
printf 'command='
printf '%q ' "${TASK_COMMAND[@]}"
printf '\n'

"${TASK_COMMAND[@]}"

task_rc=$?

echo "task_exit_code=$task_rc"
echo "task_end_time=$(date '+%Y-%m-%d %H:%M:%S')"

exit "$task_rc"