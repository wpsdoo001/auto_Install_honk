#!/usr/bin/env bash
# Honk (daeuniverse/honk) Docker 一键部署、更新与卸载管理脚本（修复拉取与网络容错版）

set -e

# 确保使用 Bash 运行
if [ -z "${BASH_VERSION:-}" ]; then
    echo "请使用 bash 运行此脚本：bash $0"
    exit 1
fi

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PLAIN="\033[0m"

# 全局常量与可覆盖环境变量
CONTAINER_NAME="honk"
IMAGE_REPO="${HONK_IMAGE:-ghcr.io/daeuniverse/honk}"
DEFAULT_FALLBACK_VER="${HONK_VERSION:-0.1.0-beta.7}"
CONFIG_DIR="/etc/honk"
WEB_BIND="0.0.0.0:9527"
GITHUB_API="https://api.github.com/repos/daeuniverse/honk/releases"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTED_IFACE=""

# 检查 Root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 请使用 root 权限或 sudo 运行此脚本！${PLAIN}"
        exit 1
    fi
}

# 检查依赖环境
check_deps() {
    for cmd in docker curl ip sysctl iptables; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}[错误] 缺少必要组件: $cmd，请先安装。${PLAIN}"
            exit 1
        fi
    done

    if ! systemctl is-active --quiet docker; then
        echo -e "${YELLOW}[提示] Docker 服务未启动，正在尝试启动...${PLAIN}"
        if ! systemctl start docker; then
            echo -e "${RED}[错误] Docker 服务启动失败，请检查 systemctl status docker。${PLAIN}"
            exit 1
        fi
    fi
}

# 清理指定网卡的 iptables FORWARD 放行规则
clean_iptables_rules() {
    local iface="${1:-}"
    [[ -z "$iface" ]] && return 0

    while iptables -C FORWARD -i "$iface" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -i "$iface" -j ACCEPT 2>/dev/null || break
    done
    while iptables -C FORWARD -o "$iface" -j ACCEPT 2>/dev/null; do
        iptables -D FORWARD -o "$iface" -j ACCEPT 2>/dev/null || break
    done
}

# 修复 Docker 容器环境下直连流量被丢弃的问题
fix_direct_traffic() {
    echo -e "${CYAN}[网络修复] 正在配置宿主机内核参数与防火墙规则，彻底消除直连丢包...${PLAIN}"

    cat > /etc/sysctl.d/99-honk.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv6.conf.all.accept_dad = 0
EOF
    if [[ -n "$SELECTED_IFACE" ]]; then
        echo "net.ipv4.conf.${SELECTED_IFACE}.rp_filter = 0" >> /etc/sysctl.d/99-honk.conf
    fi
    sysctl -p /etc/sysctl.d/99-honk.conf >/dev/null 2>&1 || true

    if [[ -n "$SELECTED_IFACE" ]]; then
        iptables -C FORWARD -i "$SELECTED_IFACE" -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD 1 -i "$SELECTED_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -o "$SELECTED_IFACE" -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD 1 -o "$SELECTED_IFACE" -j ACCEPT 2>/dev/null || true
    fi

    if ! mount | grep -q "/sys/fs/bpf"; then
        mount -t bpf bpffs /sys/fs/bpf 2>/dev/null || true
    fi

    echo -e "${GREEN}[网络修复] 内核参数与转发规则配置完成。${PLAIN}"
}

# 清理网络修复规则（sysctl + iptables）
clean_network_rules() {
    local iface="${1:-}"

    if [[ -z "$iface" && -f "${CONFIG_DIR}/.iface" ]]; then
        iface=$(cat "${CONFIG_DIR}/.iface" 2>/dev/null || true)
    fi
    [[ -z "$iface" ]] && iface="$SELECTED_IFACE"

    clean_iptables_rules "$iface"

    rm -f /etc/sysctl.d/99-honk.conf
    sysctl --system >/dev/null 2>&1 || true

    echo -e "${GREEN}[清理] 已移除临时内核调优配置文件与 iptables 放行规则。${PLAIN}"
}

# 自动识别 LAN 网卡接口
select_interface() {
    echo -e "${CYAN}[网卡检测] 正在智能扫描系统 LAN 网卡接口...${PLAIN}"

    mapfile -t IFACES < <(ip -o link show up | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -vE '^(lo|docker|veth|br-|virbr|tun|tap|podman|flico|cali)')
    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1 || true)

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        mapfile -t IFACES < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -v '^lo$')
    fi

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        echo -e "${RED}[错误] 未检测到可用网络接口，请检查系统网络。${PLAIN}"
        exit 1
    fi

    echo -e "检测到的可用网络接口："
    for i in "${!IFACES[@]}"; do
        IP_ADDR=$(ip -4 addr show "${IFACES[$i]}" 2>/dev/null | awk '/inet / {print $2}' | head -n1 || true)
        TAG=""
        [[ "${IFACES[$i]}" == "$DEFAULT_IFACE" ]] && TAG="${GREEN}[默认 LAN 推荐]${PLAIN}"
        echo -e "  ${CYAN}$((i+1)).${PLAIN} ${IFACES[$i]} (${IP_ADDR:-无IPv4地址}) $TAG"
    done

    while true; do
        if ! read -rp "请选择 Honk 绑定的 LAN 网卡编号 [默认回车选择推荐网卡]: " choice; then
            echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
            exit 1
        fi

        if [[ -z "$choice" && -n "$DEFAULT_IFACE" ]]; then
            SELECTED_IFACE="$DEFAULT_IFACE"
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#IFACES[@]} )); then
            SELECTED_IFACE="${IFACES[$((choice-1))]}"
            break
        else
            echo -e "${RED}输入无效，请输入列表中的数字编号。${PLAIN}"
        fi
    done
    echo -e "${GREEN}[已选择] 绑定 LAN 网卡接口: ${SELECTED_IFACE}${PLAIN}"
}

# 配置文件处理
handle_config() {
    mkdir -p "$CONFIG_DIR"

    if [[ -f "${SCRIPT_DIR}/config.dae" ]]; then
        echo -e "${GREEN}[配置] 检测到脚本同级目录下存在 config.dae，正在复制到 ${CONFIG_DIR}/ ...${PLAIN}"
        cp -f "${SCRIPT_DIR}/config.dae" "${CONFIG_DIR}/config.dae"
    else
        echo -e "${YELLOW}[提示] 未在同级目录发现 config.dae，正在按照 dae 官方 config.min.dae 标准生成初始配置文件...${PLAIN}"
        cat > "${CONFIG_DIR}/config.dae" <<EOF
# dae config.min.dae 示例配置文件 (由 Honk 一键脚本自动生成)
global {
    lan_interface: ["${SELECTED_IFACE}"]
    wan_interface: auto
    auto_config_kernel_parameter: true
    log_level: info
    dial_mode: domain
    sniffing_timeout: 50ms
    tls_implementation: utls
    utls_imitate: chrome_auto
    allow_insecure: false
    bootstrap_resolver: '223.5.5.5:53'
    fallback_resolver: '8.8.8.8:53'
    data_dir: '/etc/honk'
}

dns {
    upstream {
        remote: 'https://8.8.8.8/dns-query' ->Final
        local: 'https://dns.alidns.com/dns-query'
    }

    routing {

        request {
            qname(geosite:category-ads-all) -> reject
            qtype(https, svcb) -> reject
            qname(suffix: googleapis.cn, suffix: xn--ngstr-lra8j.com) -> remote
            qname(geosite:cn, geosite:microsoft@cn, geosite:apple@cn, geosite:private) -> local
            qname(geosite:geolocation-!cn) -> remote
            fallback: remote
        }

        response {
            upstream(remote) && ip(geoip:cn) -> local
            fallback: accept
        }
    }
}

group{
        Final {
        filter: !name(regex: '官网|剩余|流量|套餐|免费|订阅|到期|过期|重置|公告|通知|群|测试订阅')
        policy: score
        interrupt_connections: true
    }
}

routing {
    domain(geosite:cn) -> direct
    domain(geosite:private) -> direct
    dip(geoip:cn) -> direct
    domain(geosite:geolocation-!cn) -> Final
    fallback -> Final
}

 experimental {
     native_api {
         enabled: true
         listen: '0.0.0.0:9527'
         password_auth: true
         config_write: true
         ui: embedded
     }
     cache_file {
         enabled: true
         store_dns: true
     }
 }
EOF
        echo -e "${GREEN}[配置] 已成功在 ${CONFIG_DIR}/config.dae 生成最小可用配置模板。${PLAIN}"
    fi

    chmod 644 "${CONFIG_DIR}/config.dae" 2>/dev/null || true
    chown -R root:root "$CONFIG_DIR" 2>/dev/null || true
    echo "$SELECTED_IFACE" > "${CONFIG_DIR}/.iface"
}

# 获取远程最新版本号（包含 prerelease 回退到已知可用版本）
get_latest_version() {
    if [[ -n "${HONK_VERSION:-}" ]]; then
        LATEST_VER="${HONK_VERSION#v}"
        echo -e "${CYAN}[版本] 使用指定版本标签: ${LATEST_VER}${PLAIN}"
        return 0
    fi

    LATEST_VER=""
    local resp=""
    # 先查 releases 列表首条（含 beta/pre-release），再查 latest
    resp=$(curl -fsSL --connect-timeout 8 --max-time 15 "${GITHUB_API}?per_page=1" 2>/dev/null || true)
    if [[ -n "$resp" ]]; then
        LATEST_VER=$(printf '%s\n' "$resp" | grep -m1 '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' || true)
    fi

    if [[ -z "$LATEST_VER" ]]; then
        echo -e "${YELLOW}[提示] 无法通过 GitHub API 获取版本列表，回退使用版本标签: ${DEFAULT_FALLBACK_VER}${PLAIN}"
        LATEST_VER="$DEFAULT_FALLBACK_VER"
    else
        echo -e "${GREEN}[版本] 检测到远程最新版本标签: ${LATEST_VER}${PLAIN}"
    fi
}

# 获取当前运行版本
get_current_version() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        CURRENT_VER=$(docker inspect --format '{{.Config.Labels.version}}' "$CONTAINER_NAME" 2>/dev/null || true)
        [[ -z "$CURRENT_VER" || "$CURRENT_VER" == "<no value>" ]] && CURRENT_VER="已运行"
    else
        CURRENT_VER="未安装"
    fi
}

# 诊断并尝试拉取镜像
pull_image_with_diagnostics() {
    local target_image="${IMAGE_REPO}:${1}"
    echo -e "${CYAN}[部署] 正在拉取镜像 ${target_image} ...${PLAIN}"

    if docker pull "$target_image"; then
        return 0
    fi

    # 若非默认回退版本且拉取失败，尝试回退版本一次
    if [[ "$1" != "$DEFAULT_FALLBACK_VER" ]]; then
        local fallback_image="${IMAGE_REPO}:${DEFAULT_FALLBACK_VER}"
        echo -e "${YELLOW}[重试] 标签 ${1} 拉取失败，尝试回退标签 ${fallback_image} ...${PLAIN}"
        if docker pull "$fallback_image"; then
            LATEST_VER="$DEFAULT_FALLBACK_VER"
            return 0
        fi
    fi

    echo -e "${RED}[失败] 镜像拉取失败（当前仓库: ${IMAGE_REPO}）。${PLAIN}"
    echo -e "${YELLOW}[排查建议]${PLAIN}"
    echo -e "  1. 测试宿主机到 ghcr.io 的连通性：curl -I --connect-timeout 8 https://ghcr.io"
    echo -e "  2. 检查 Docker 守护进程代理或镜像加速配置（注意终端代理变量不会自动传给 dockerd）"
    echo -e "  3. 指定可用镜像代理或版本号重跑："
    echo -e "     HONK_IMAGE=你的镜像代理/daeuniverse/honk HONK_VERSION=${DEFAULT_FALLBACK_VER} bash $0"
    echo -e "  4. 若当前环境无法直连外网，可在有网机器执行 docker pull ${target_image} 后 docker save/load 导入"
    return 1
}

# 启动容器
run_container() {
    local TAG="$1"

    if ! pull_image_with_diagnostics "$TAG"; then
        exit 1
    fi

    TAG="$LATEST_VER"

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    echo -e "${CYAN}[部署] 正在启动 Honk 容器...${PLAIN}"
    if ! docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --network host \
        --privileged \
        --label "version=${TAG}" \
        -v "${CONFIG_DIR}:/etc/honk" \
        -v "/sys/fs/bpf:/sys/fs/bpf" \
        "${IMAGE_REPO}:${TAG}" run -c /etc/honk/config.dae >/dev/null; then
        echo -e "${RED}[失败] 容器启动异常，请检查以下日志：${PLAIN}"
        docker logs "$CONTAINER_NAME" 2>/dev/null || true
        exit 1
    fi

    sleep 2

    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        INSTALLED_VER=$(docker exec "$CONTAINER_NAME" honk --version 2>/dev/null || echo "$TAG")
        echo -e "=================================================="
        echo -e "${GREEN}[成功] Honk 已成功部署并运行！${PLAIN}"
        echo -e "  当前安装版本 : ${CYAN}${INSTALLED_VER}${PLAIN}"
        echo -e "  使用镜像仓库 : ${CYAN}${IMAGE_REPO}:${TAG}${PLAIN}"
        echo -e "  绑定 LAN 网卡: ${CYAN}${SELECTED_IFACE}${PLAIN}"
        echo -e "  Web 管理地址 : ${CYAN}http://${WEB_BIND}${PLAIN}"
        echo -e "  配置文件路径 : ${CYAN}${CONFIG_DIR}/config.dae${PLAIN}"
        echo -e "=================================================="
        echo -e "${YELLOW}[容器启动日志]：${PLAIN}"
        docker logs --tail 15 "$CONTAINER_NAME" 2>/dev/null || true
    else
        echo -e "${RED}[失败] 容器启动后未保持运行，请检查以下日志：${PLAIN}"
        docker logs "$CONTAINER_NAME" 2>/dev/null || true
        exit 1
    fi
}

# 1. 安装
install_honk() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}[提示] 检测到 Honk 容器已存在！如需升级请使用“更新”功能。${PLAIN}"
        if ! read -rp "是否覆盖重新安装？(y/N): " confirm; then
            echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
            exit 1
        fi
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    fi

    select_interface
    fix_direct_traffic
    handle_config
    get_latest_version
    run_container "$LATEST_VER"
}

# 2. 更新
update_honk() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${RED}[错误] 尚未安装 Honk，请先执行安装操作。${PLAIN}"
        return 0
    fi

    get_current_version
    get_latest_version
    echo -e "  当前版本 : ${YELLOW}${CURRENT_VER}${PLAIN}"
    echo -e "  目标版本 : ${GREEN}${LATEST_VER}${PLAIN}"

    if ! read -rp "是否开始更新 Honk 镜像？(Y/n): " do_up; then
        echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
        exit 1
    fi
    [[ "$do_up" =~ ^[Nn]$ ]] && return 0

    if [[ -f "${CONFIG_DIR}/.iface" ]]; then
        SELECTED_IFACE=$(cat "${CONFIG_DIR}/.iface" 2>/dev/null || true)
    fi

    if [[ -z "$SELECTED_IFACE" ]]; then
        select_interface
    fi

    fix_direct_traffic
    run_container "$LATEST_VER"
}

# 3. 卸载
uninstall_honk() {
    echo -e "${YELLOW}[警告] 即将卸载 Honk 服务并清理容器环境。${PLAIN}"
    if ! read -rp "确认继续卸载？(y/N): " confirm; then
        echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
        exit 1
    fi
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0

    local saved_iface=""
    if [[ -f "${CONFIG_DIR}/.iface" ]]; then
        saved_iface=$(cat "${CONFIG_DIR}/.iface" 2>/dev/null || true)
    fi

    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if [[ -d "$CONFIG_DIR" ]]; then
        if ! read -rp "是否需要备份配置文件目录 (${CONFIG_DIR})？(Y/n): " backup_choice; then
            echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
            exit 1
        fi

        if [[ ! "$backup_choice" =~ ^[Nn]$ ]]; then
            BACKUP_FILE="/root/honk_config_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
            if tar -czf "$BACKUP_FILE" -C "$(dirname "$CONFIG_DIR")" "$(basename "$CONFIG_DIR")" 2>/dev/null; then
                echo -e "${GREEN}[备份] 配置文件已成功备份至: ${BACKUP_FILE}${PLAIN}"
            else
                echo -e "${RED}[备份失败] 无法写入 ${BACKUP_FILE}，请检查磁盘空间与权限。${PLAIN}"
            fi
        fi

        if ! read -rp "是否彻底删除配置目录 (${CONFIG_DIR})？(y/N): " del_cfg; then
            echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
            exit 1
        fi
        if [[ "$del_cfg" =~ ^[Yy]$ ]]; then
            rm -rf "$CONFIG_DIR"
            echo -e "${GREEN}[清理] 已删除配置目录。${PLAIN}"
        fi
    fi

    if ! read -rp "是否同时删除本地 Honk Docker 镜像？(y/N): " del_img; then
        echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
        exit 1
    fi
    if [[ "$del_img" =~ ^[Yy]$ ]]; then
        docker images "${IMAGE_REPO}" -q 2>/dev/null | while read -r img; do
            [[ -n "$img" ]] && docker rmi -f "$img" >/dev/null 2>&1 || true
        done
    fi

    clean_network_rules "$saved_iface"
    echo -e "${GREEN}[完成] Honk 卸载与环境清理已全部完成！${PLAIN}"
}

# 主菜单
show_menu() {
    command -v clear >/dev/null 2>&1 && clear || true
    get_current_version
    echo -e "=================================================="
    echo -e "       ${CYAN}Honk (daeuniverse/honk) 增强管理脚本${PLAIN}"
    echo -e "=================================================="
    echo -e " 运行状态: ${GREEN}${CURRENT_VER}${PLAIN} | 管理面板: ${CYAN}0.0.0.0:9527${PLAIN}"
    echo -e " 镜像仓库: ${CYAN}${IMAGE_REPO}${PLAIN}"
    echo -e "--------------------------------------------------"
    echo -e "  ${GREEN}1.${PLAIN} 安装 Honk (优先复制同级 config.dae 或自动生成模板)"
    echo -e "  ${GREEN}2.${PLAIN} 更新 Honk (平滑升级最新镜像)"
    echo -e "  ${GREEN}3.${PLAIN} 卸载 Honk (停止服务 + 备份 + 完整清理)"
    echo -e "  ${GREEN}0.${PLAIN} 退出脚本"
    echo -e "=================================================="
    if ! read -rp "请输入操作编号 [0-3]: " num; then
        echo -e "${RED}[错误] 读取输入失败，退出。${PLAIN}"
        exit 1
    fi
    case "$num" in
        1) install_honk ;;
        2) update_honk ;;
        3) uninstall_honk ;;
        0) exit 0 ;;
        *) echo -e "${RED}请输入正确的数字 [0-3]${PLAIN}" ;;
    esac
}

check_root
check_deps
show_menu
