#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# GPU 自动监测与任务启动模板
#
# 默认运行位置：75
# 功能：
#   1. 检查本机和远程节点指定 GPU
#   2. 检测 CUDA compute process、显存、利用率
#   3. 所有节点连续空闲后启动任务
#   4. 使用 flock 和 marker 防止重复启动
#   5. 不使用 sudo、不杀进程、不修改系统环境
#
# 远程节点不需要安装本脚本：
# watcher 每次通过 SSH 将自身以 stdin 方式传给远端执行 --probe。
# ============================================================


# ------------------------------------------------------------
# 通用字符串清理函数
# ------------------------------------------------------------
trim() {
    local s="${1-}"

    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"

    printf '%s' "$s"
}


# ------------------------------------------------------------
# 单节点 GPU 探测函数
#
# 返回值：
#   0：指定 GPU 全部空闲
#   1：至少一张 GPU 正在使用
#   2：检测出错
# ------------------------------------------------------------
probe_main() {
    local gpu_csv="${1:?missing GPU list}"
    local memory_limit_mib="${2:?missing memory limit}"
    local util_limit_percent="${3:?missing utilization limit}"

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "host=$(hostname -s) node_state=ERROR reason=nvidia-smi_not_found"
        return 2
    fi

    local gpu_rows
    local app_rows

    if ! gpu_rows=$(
        nvidia-smi \
            --query-gpu=index,uuid,memory.used,utilization.gpu \
            --format=csv,noheader,nounits 2>&1
    ); then
        echo "host=$(hostname -s) node_state=ERROR reason=nvidia-smi_query_failed"
        printf '%s\n' "$gpu_rows"
        return 2
    fi

    # 查询 CUDA compute process。
    # 查询不到进程时可能返回空，因此这里不把空结果视为错误。
    app_rows=$(
        nvidia-smi \
            --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
            --format=csv,noheader,nounits 2>/dev/null ||
            true
    )

    declare -A wanted=()
    declare -A found=()
    declare -A process_by_uuid=()

    local -a requested=()
    local item

    IFS=',' read -r -a requested <<< "$gpu_csv"

    for item in "${requested[@]}"; do
        item=$(trim "$item")

        if [[ -n "$item" ]]; then
            wanted["$item"]=1
        fi
    done

    # 按 GPU UUID 保存 compute process 信息。
    local uuid
    local pid
    local process_name
    local process_mem

    while IFS=',' read -r uuid pid process_name process_mem; do
        uuid=$(trim "$uuid")
        pid=$(trim "$pid")
        process_name=$(trim "$process_name")

        [[ -z "$uuid" || -z "$pid" ]] && continue

        if [[ -n "${process_by_uuid[$uuid]-}" ]]; then
            process_by_uuid["$uuid"]+=";"
        fi

        process_by_uuid["$uuid"]+="${pid}:${process_name}"
    done <<< "$app_rows"

    local any_busy=0
    local any_error=0

    local index
    local memory_used
    local util_used
    local reason
    local state

    echo "host=$(hostname -s) memory_limit_mib=$memory_limit_mib util_limit_percent=$util_limit_percent"

    while IFS=',' read -r index uuid memory_used util_used; do
        index=$(trim "$index")
        uuid=$(trim "$uuid")
        memory_used=$(trim "$memory_used")
        util_used=$(trim "$util_used")

        # 跳过不在监测列表中的 GPU。
        [[ -z "${wanted[$index]+x}" ]] && continue

        found["$index"]=1
        reason=""
        state="FREE"

        if ! [[ "$memory_used" =~ ^[0-9]+$ &&
                "$util_used" =~ ^[0-9]+$ ]]; then
            state="ERROR"
            reason="unparseable_gpu_metrics"
            any_error=1
        else
            # 只要存在 CUDA compute process，就直接判为 BUSY。
            if [[ -n "${process_by_uuid[$uuid]-}" ]]; then
                state="BUSY"
                reason="compute_process"
            fi

            # 显存高于阈值也判为 BUSY。
            if (( memory_used > memory_limit_mib )); then
                state="BUSY"
                reason="${reason:+$reason+}memory"
            fi

            # GPU 利用率高于阈值也判为 BUSY。
            if (( util_used > util_limit_percent )); then
                state="BUSY"
                reason="${reason:+$reason+}utilization"
            fi

            if [[ "$state" == "BUSY" ]]; then
                any_busy=1
            elif [[ "$state" == "FREE" ]]; then
                reason="none"
            fi
        fi

        printf \
            'gpu=%s mem_used_mib=%s util_percent=%s state=%s reason=%s' \
            "$index" \
            "$memory_used" \
            "$util_used" \
            "$state" \
            "$reason"

        if [[ -n "${process_by_uuid[$uuid]-}" ]]; then
            printf ' processes=%s' "${process_by_uuid[$uuid]}"
        fi

        printf '\n'
    done <<< "$gpu_rows"

    # 检查配置中的 GPU 编号是否真实存在。
    for item in "${!wanted[@]}"; do
        if [[ -z "${found[$item]+x}" ]]; then
            echo "gpu=$item state=ERROR reason=gpu_index_not_found"
            any_error=1
        fi
    done

    if (( any_error )); then
        echo "node_state=ERROR"
        return 2
    fi

    if (( any_busy )); then
        echo "node_state=BUSY"
        return 1
    fi

    echo "node_state=FREE"
    return 0
}


# ------------------------------------------------------------
# --probe 模式
#
# watcher 在远程服务器上通过以下形式调用：
#
# bash -s -- --probe GPU列表 显存阈值 利用率阈值
# ------------------------------------------------------------
if [[ "${1-}" == "--probe" ]]; then
    if (( $# != 4 )); then
        echo \
            "usage: bash gpu_watch.sh --probe GPU_CSV MEMORY_LIMIT_MIB UTIL_LIMIT_PERCENT" \
            >&2
        exit 2
    fi

    probe_main "$2" "$3" "$4"
    exit $?
fi


# ============================================================
# 用户配置区
# ============================================================

BASE_DIR="${GPU_WATCH_BASE_DIR:-$HOME/gpu_watch}"

# 每隔多少秒检测一次。
CHECK_INTERVAL_SECONDS=60

# 连续多少轮全部空闲后才尝试启动。
# 例如间隔 60 秒、连续 2 次，即至少稳定空闲约 1 分钟。
REQUIRED_CONSECUTIVE_FREE=2

# 最大等待时间，单位秒。
# 0 表示一直监测，不自动超时。
MAX_WAIT_SECONDS=0

# 1：任务成功启动一次后 watcher 退出。
# 0：任务执行完成后继续监测，并可能再次启动。
RUN_ONCE=1

# 显存阈值。
#
# 之前服务器上出现过每张卡约 531～605 MiB 的基础占用，
# 因此不再使用 64 MiB 这种过严阈值。
#
# 即便显存低于此阈值，只要存在 compute process，
# GPU 依然会判定为 BUSY。
MEMORY_LIMIT_MIB=1024

# GPU 利用率阈值。
UTIL_LIMIT_PERCENT=5


# 要监测的节点。
NODES=(
    "server 1" #这里需要更改服务器名称
    "server 2"
)


# local 表示 watcher 所在机器。
# ssh 表示通过 SSH 检查远程机器。
declare -A NODE_TYPE=(
    ["server 1"]="local"
    ["server 2"]="ssh"
)


# 远程 SSH 地址。
declare -A NODE_TARGET=(
    ["server 2"]="user@1.1.1.1"
)


# SSH 端口。
declare -A NODE_SSH_PORT=(
    ["server 2"]="1111"
)


# 每台机器需要空闲的 GPU。
#
# 这里默认要求两台机器各 8 张 GPU 全部空闲。
# 例如只需要 4+4，可以改成：
#
# ["server 1"]="0,1,2,3"
# ["server 2"]="0,1,2,3"
declare -A NODE_GPUS=(
    ["server 1"]="0,1,2,3,4,5,6,7"
    ["server 2"]="0,1,2,3,4,5,6,7"
)


# 两台机器全部满足条件后执行的启动脚本。
LAUNCH_SCRIPT="$BASE_DIR/launch_task.sh"

# ============================================================
# 用户配置区结束
# ============================================================


STATE_DIR="$BASE_DIR/state"
LOG_DIR="$BASE_DIR/logs"

WATCH_LOG="$LOG_DIR/watcher.log"

LOCK_FILE="$STATE_DIR/watcher.lock"
PID_FILE="$STATE_DIR/watcher.pid"

# 表示已经进入启动阶段。
LAUNCHING_MARKER="$STATE_DIR/launching.marker"

# 表示任务曾成功启动。
DONE_MARKER="$STATE_DIR/done.marker"

SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")

mkdir -p "$STATE_DIR" "$LOG_DIR"


timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}


log() {
    printf '[%s] %s\n' \
        "$(timestamp)" \
        "$*" |
        tee -a "$WATCH_LOG"
}


# ------------------------------------------------------------
# 防止重复启动多个 watcher
# ------------------------------------------------------------
if ! command -v flock >/dev/null 2>&1; then
    log "ERROR: flock not found; watcher cannot safely prevent duplicate instances"
    exit 2
fi

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "ERROR: another watcher instance is already running"
    exit 1
fi

printf '%s\n' "$$" > "$PID_FILE"

trap 'rm -f "$PID_FILE"' EXIT
trap 'log "watcher received termination signal"; exit 0' INT TERM


# ------------------------------------------------------------
# 启动前检查状态
# ------------------------------------------------------------
if [[ ! -f "$LAUNCH_SCRIPT" ]]; then
    log "ERROR: launch script not found: $LAUNCH_SCRIPT"
    exit 2
fi

if (( RUN_ONCE == 1 )) && [[ -f "$DONE_MARKER" ]]; then
    log "Task was already launched successfully"
    log "Remove $DONE_MARKER only when an intentional rerun is needed"
    exit 0
fi

# 如果 watcher 上次在启动过程中异常退出，不自动重新启动，
# 避免任务已经启动但 marker 尚未来得及更新时被重复执行。
if [[ -f "$LAUNCHING_MARKER" &&
      ! -f "$DONE_MARKER" ]]; then
    log "ERROR: an earlier launch may still be active or may have ended unexpectedly"
    log "Inspect task logs and processes before removing: $LAUNCHING_MARKER"
    exit 3
fi


# ------------------------------------------------------------
# 运行单节点探测
# ------------------------------------------------------------
run_probe() {
    local node="$1"

    local node_type="${NODE_TYPE[$node]-}"
    local gpus="${NODE_GPUS[$node]-}"

    if [[ -z "$node_type" || -z "$gpus" ]]; then
        echo "node_state=ERROR reason=incomplete_node_configuration"
        return 2
    fi

    case "$node_type" in
        local)
            bash "$SCRIPT_PATH" \
                --probe \
                "$gpus" \
                "$MEMORY_LIMIT_MIB" \
                "$UTIL_LIMIT_PERCENT"
            ;;

        ssh)
            local target="${NODE_TARGET[$node]-}"
            local port="${NODE_SSH_PORT[$node]-22}"

            if [[ -z "$target" ]]; then
                echo "node_state=ERROR reason=missing_ssh_target"
                return 2
            fi

            # BatchMode=yes：
            # 禁止 watcher 等待交互式密码输入。
            #
            # 远程服务器不需要提前保存 gpu_watch.sh，
            # 本地脚本通过 stdin 传给远程 bash。
            ssh \
                -o BatchMode=yes \
                -o ConnectTimeout=10 \
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=2 \
                -p "$port" \
                "$target" \
                bash -s -- \
                --probe \
                "$gpus" \
                "$MEMORY_LIMIT_MIB" \
                "$UTIL_LIMIT_PERCENT" \
                < "$SCRIPT_PATH"
            ;;

        *)
            echo "node_state=ERROR reason=unknown_node_type"
            return 2
            ;;
    esac
}


# ------------------------------------------------------------
# 检查所有节点
#
# 只有所有节点 probe 返回 0，函数才返回 0。
# BUSY 和 ERROR 都不会触发任务启动。
# ------------------------------------------------------------
check_all_nodes() {
    local node
    local output
    local rc
    local line

    local all_free=1

    for node in "${NODES[@]}"; do
        output=$(run_probe "$node" 2>&1)
        rc=$?

        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                log "[$node] $line"
            fi
        done <<< "$output"

        if (( rc != 0 )); then
            all_free=0
        fi
    done

    (( all_free == 1 ))
}


# ------------------------------------------------------------
# 主循环
# ------------------------------------------------------------
start_epoch=$(date +%s)
consecutive_free=0

log "watcher started"
log "nodes=${NODES[*]}"
log "interval=${CHECK_INTERVAL_SECONDS}s"
log "required_consecutive_free=${REQUIRED_CONSECUTIVE_FREE}"

while true; do
    if check_all_nodes; then
        ((consecutive_free += 1))

        log \
            "all nodes free: consecutive=$consecutive_free/$REQUIRED_CONSECUTIVE_FREE"
    else
        consecutive_free=0
        log "not all required GPUs are free"
    fi

    if (( consecutive_free >= REQUIRED_CONSECUTIVE_FREE )); then
        log "rechecking immediately before launch"

        # 在真正执行任务前再检查一次，减少监测间隔内状态变化造成的误启动。
        if check_all_nodes; then
            printf \
                'time=%s pid=%s\n' \
                "$(timestamp)" \
                "$$" \
                > "$LAUNCHING_MARKER"

            log "launching task with: $LAUNCH_SCRIPT"

            bash "$LAUNCH_SCRIPT"
            launch_rc=$?

            if (( launch_rc == 0 )); then
                printf \
                    'time=%s watcher_pid=%s\n' \
                    "$(timestamp)" \
                    "$$" \
                    > "$DONE_MARKER"

                rm -f "$LAUNCHING_MARKER"

                log "task launch completed successfully"

                if (( RUN_ONCE == 1 )); then
                    exit 0
                fi

                consecutive_free=0
            else
                rm -f "$LAUNCHING_MARKER"

                consecutive_free=0

                log \
                    "task launch failed: exit_code=$launch_rc; monitoring will continue"
            fi
        else
            consecutive_free=0
            log "GPU state changed during final recheck; launch cancelled"
        fi
    fi

    if (( MAX_WAIT_SECONDS > 0 )); then
        now_epoch=$(date +%s)

        if (( now_epoch - start_epoch >= MAX_WAIT_SECONDS )); then
            log "maximum wait time reached; watcher exiting without launch"
            exit 4
        fi
    fi

    sleep "$CHECK_INTERVAL_SECONDS"
done