#!/usr/bin/env bash
# NVIDIA Orin Nano Developer Kit / Ubuntu 20.04.6 / JetPack R35 / Linux 5.10.120-tegra
# n2n 3.1.1 installer for the N2N Universal Web Installer.
# Public-distribution safe: no embedded n2n encryption key.
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION="1.0.0"
N2N_VERSION="3.1.1"
N2N_COMMIT="ce998b986c633bc563835d8a3cc8f72a017b53d1"
ID_PREFIX="1712350000"
SUPER="43.137.14.161:7799"
BUILD_PARENT="/data"
N2N_SRC="${BUILD_PARENT}/n2n-3.1.1"
EDGE_CONF="/etc/n2n/edge.conf"
SUP_CONF="/etc/supervisor/conf.d/n2n-edge.conf"
SELF_INSTALL="/usr/local/sbin/jetson-orin-nano-devkit-n2n-setup"
LOG_FILE="/var/log/jetson-orin-nano-devkit-n2n-setup.log"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
warn() { log "WARN: $*" >&2; }

usage() {
  cat <<'EOF'
NVIDIA Orin Nano Developer Kit n2n 安装脚本 v1.0.0

首次安装：
  sudo bash jetson-orin-nano-devkit-n2n-setup.sh 083
  sudo bash jetson-orin-nano-devkit-n2n-setup.sh 083 --key-file /root/n2n.key

维护：
  sudo jetson-orin-nano-devkit-n2n-setup --set-id 084
  sudo jetson-orin-nano-devkit-n2n-setup --set-key
  sudo jetson-orin-nano-devkit-n2n-setup --status

设备编号必须为三位数字，例如 001、083、999。
此脚本仅适用于 NVIDIA Orin Nano Developer Kit / Ubuntu 20.04 / Linux 5.10.120-tegra。
不会编译或安装 RK3576 专用 tun.ko。
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail '请使用 sudo 执行'
}

# /data is a working directory, not a required pre-existing mount point.
# Create it only when absent; preserve permissions on an existing directory.
ensure_build_parent() {
  if [[ -L "$BUILD_PARENT" ]]; then
    [[ -d "$BUILD_PARENT" ]] || fail "$BUILD_PARENT 是失效符号链接或不是目录，拒绝继续"
    log "工作目录已存在（符号链接目标为目录）：$BUILD_PARENT"
  elif [[ -e "$BUILD_PARENT" ]]; then
    [[ -d "$BUILD_PARENT" ]] || fail "$BUILD_PARENT 已存在但不是目录，拒绝继续"
    log "工作目录已存在，保留原有权限：$BUILD_PARENT"
  else
    install -d -o root -g root -m 755 "$BUILD_PARENT"
    [[ -d "$BUILD_PARENT" ]] || fail "创建工作目录失败：$BUILD_PARENT"
    log "检测到 $BUILD_PARENT 不存在，已自动创建（root:root，权限 755）"
  fi
  [[ -w "$BUILD_PARENT" && -x "$BUILD_PARENT" ]] || \
    fail "工作目录不可写或不可进入：$BUILD_PARENT"
}

validate_id() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]{3}$ ]] || fail "设备编号必须为三位数字，当前为 '${id}'"
  local identity="${ID_PREFIX}${id}"
  local community="${identity}_${id}"
  ((${#community} <= 19)) || fail 'n2n 社区名称超长'
}

validate_key() {
  [[ "$1" =~ ^[A-Za-z0-9._@%+=:/-]{8,128}$ ]] || \
    fail '密钥格式不合规：需要 8-128 位 ASCII，允许字母、数字及 . _ @ % + = : / -'
}

ensure_log() {
  install -d -m 700 /var/log
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

acquire_lock() {
  command -v flock >/dev/null 2>&1 || fail 'flock 不存在，无法保证单实例安装'
  exec 9>/run/lock/jetson-orin-nano-devkit-n2n-setup.lock
  flock -n 9 || fail '另一安装/维护进程正在运行'
}

require_platform() {
  local arch release distro model compatible
  arch="$(uname -m)"
  release="$(uname -r)"
  distro="$(
    . /etc/os-release
    printf '%s:%s' "${ID:-unknown}" "${VERSION_ID:-unknown}"
  )"
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  compatible="$(tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null || true)"

  [[ "$arch" == "aarch64" ]] || fail "架构为 ${arch}，仅支持 aarch64"
  grep -qi 'orin nano' <<<"$model" || \
    fail "设备型号不是 NVIDIA Orin Nano：${model:-unknown}"
  grep -qi 'developer kit' <<<"$model" || \
    fail "设备不是 NVIDIA Orin Nano Developer Kit：${model:-unknown}"
  grep -q 'nvidia,tegra234' <<<"$compatible" || \
    fail '设备树未识别为 NVIDIA Tegra234，拒绝执行 Jetson 安装'
  [[ "$distro" == "ubuntu:20.04" ]] || \
    fail "系统为 ${distro}，当前版本仅验证 Ubuntu 20.04"
  [[ "$release" == "5.10.120-tegra" ]] || \
    fail "内核为 ${release}，当前版本仅验证 5.10.120-tegra"

  log "平台检查通过：${model} / Ubuntu 20.04 / Kernel ${release} / ${arch}"
}

package_installed_or_available() {
  local pkg="$1" binary="${2:-}"
  if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)" == 'installed' ]]; then
    return 0
  fi
  [[ -n "$binary" ]] && command -v "$binary" >/dev/null 2>&1
}

install_packages_if_missing() {
  local missing=()
  package_installed_or_available git git || missing+=(git)
  package_installed_or_available ca-certificates || \
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if ! command -v gcc >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    missing+=(build-essential)
  fi
  package_installed_or_available autoconf autoreconf || missing+=(autoconf)
  package_installed_or_available automake automake || missing+=(automake)
  package_installed_or_available libtool libtoolize || missing+=(libtool)
  package_installed_or_available pkg-config pkg-config || missing+=(pkg-config)
  package_installed_or_available iproute2 ip || missing+=(iproute2)
  package_installed_or_available kmod modprobe || missing+=(kmod)
  package_installed_or_available supervisor supervisorctl || missing+=(supervisor)

  if ((${#missing[@]} == 0)); then
    log 'n2n 所需依赖已具备，跳过 APT 更新与安装'
    return 0
  fi

  log "仅安装缺少的依赖：${missing[*]}"
  apt-get update
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
    warn 'APT 安装失败；不会执行 full-upgrade、不会批量解除 hold，也不会卸载厂商软件包'
    apt-cache policy "${missing[@]}" >&2 || true
    apt-mark showhold >&2 || true
    fail '请先检查 APT 软件源和依赖状态，再重新执行安装'
  fi
}

n2n_is_311() {
  [[ -x /usr/sbin/edge ]] || return 1
  local info
  info="$(/usr/sbin/edge -h 2>&1 || true)"
  [[ "$info" == *'n2n v.3.1.1'* ]]
}

install_n2n() {
  if n2n_is_311; then
    log 'n2n 3.1.1 已安装，跳过编译'
    return 0
  fi
  if [[ -e /usr/sbin/edge ]]; then
    fail '/usr/sbin/edge 已存在，但不是预期的 n2n 3.1.1；为避免覆盖，停止安装'
  fi

  if [[ ! -d "$N2N_SRC/.git" ]]; then
    [[ ! -e "$N2N_SRC" ]] || fail "源码目录 ${N2N_SRC} 已存在但不是 Git 仓库"
    log '下载官方 n2n 3.1.1 源码'
    git clone --branch "$N2N_VERSION" --depth 1 \
      https://github.com/ntop/n2n.git "$N2N_SRC"
  fi

  [[ "$(stat -c '%u' "$N2N_SRC")" == "0" ]] || \
    fail "源码目录 ${N2N_SRC} 非 root 所有，拒绝以 root 编译"
  local src_mode
  src_mode="$(stat -c '%a' "$N2N_SRC")"
  (( (8#$src_mode & 022) == 0 )) || \
    fail "源码目录 ${N2N_SRC} 可被非 root 写入，拒绝以 root 编译"

  local commit
  commit="$(git -C "$N2N_SRC" rev-parse HEAD)"
  [[ "$commit" == "$N2N_COMMIT" ]] || \
    fail "n2n 源码提交不匹配，期望 ${N2N_COMMIT}，实际 ${commit}"

  log '编译 n2n（make -j2）'
  (
    cd "$N2N_SRC"
    ./autogen.sh
    ./configure
    make -j2
    make install
  )
  ldconfig
  n2n_is_311 || fail 'n2n 安装后版本验证失败'
  log 'n2n 3.1.1 安装成功'
}

tap_probe() {
  [[ -c /dev/net/tun ]] || return 1
  local iface="n2nprobe$$"
  if ! ip tuntap add dev "$iface" mode tap >/dev/null 2>&1; then
    return 1
  fi
  ip link delete dev "$iface" >/dev/null 2>&1 || true
  return 0
}

tun_enabled_in_kernel_config() {
  if [[ -r /proc/config.gz ]] && command -v zcat >/dev/null 2>&1; then
    zcat /proc/config.gz 2>/dev/null | grep -Eq '^CONFIG_TUN=(y|m)$' && return 0
  fi
  local config="/boot/config-$(uname -r)"
  [[ -r "$config" ]] && grep -Eq '^CONFIG_TUN=(y|m)$' "$config"
}

ensure_tun_device_node() {
  if [[ -e /dev/net/tun && ! -c /dev/net/tun ]]; then
    fail '/dev/net/tun 已存在但不是字符设备，拒绝覆盖'
  fi
  if [[ ! -c /dev/net/tun ]]; then
    [[ -d /sys/module/tun ]] || tun_enabled_in_kernel_config || \
      fail '内核未检测到 TUN 支持；请检查 Jetson BSP 内核配置'
    install -d -m 755 /dev/net
    mknod /dev/net/tun c 10 200
  fi
  local device_number
  device_number="$(stat -c '%t:%T' /dev/net/tun)"
  [[ "$device_number" == 'a:c8' ]] || fail "/dev/net/tun 设备号异常：${device_number}"
  chmod 666 /dev/net/tun
}

install_tun_persistence() {
  install -d -m 755 /etc/tmpfiles.d
  cat >/etc/tmpfiles.d/n2n-tun.conf <<'EOF'
c /dev/net/tun 0666 root root -
EOF
  chmod 644 /etc/tmpfiles.d/n2n-tun.conf
  command -v systemd-tmpfiles >/dev/null 2>&1 || fail 'systemd-tmpfiles 不存在，无法保证 /dev/net/tun 开机重建'
  systemd-tmpfiles --create /etc/tmpfiles.d/n2n-tun.conf || \
    fail 'systemd-tmpfiles 创建 TUN 设备节点失败，拒绝继续安装'

  local module_path=''
  module_path="$(modinfo -n tun 2>/dev/null || true)"
  if [[ -n "$module_path" && "$module_path" != '(builtin)' && "$module_path" != 'builtin' ]]; then
    install -d -m 755 /etc/modules-load.d
    printf 'tun\n' >/etc/modules-load.d/n2n-tun.conf
    chmod 644 /etc/modules-load.d/n2n-tun.conf
    log '已配置 tun 模块开机加载'
  else
    rm -f /etc/modules-load.d/n2n-tun.conf
    log 'TUN 由当前 Developer Kit 内核内置或以非模块方式提供，不创建模块加载配置'
  fi
}

ensure_tun() {
  if ! tap_probe; then
    log '尝试加载 Developer Kit 内核提供的 TUN 模块'
    modprobe tun >/dev/null 2>&1 || true
    ensure_tun_device_node
  fi

  tap_probe || fail 'Developer Kit 内核 TUN/TAP 不可用；本脚本不会编译 RK3576 专用 tun.c，也不会安装不匹配的内核模块'
  install_tun_persistence
  ensure_tun_device_node
  tap_probe || fail 'TUN/TAP 持久化后复测失败'
  log 'Jetson TUN/TAP 可用，创建和删除临时 TAP 接口测试通过'
}

extract_key_from_file() {
  local path="$1" line="" found=""
  [[ -f "$path" && ! -L "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^-k=(.+)$ ]]; then
      found="${BASH_REMATCH[1]}"
      break
    fi
    if [[ "$line" =~ (^|[[:space:]])-k[[:space:]]+([^[:space:]]+) ]]; then
      found="${BASH_REMATCH[2]}"
      break
    fi
  done <"$path"
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}

get_secret() {
  local key_file="${1:-}" secret=""
  if [[ -n "$key_file" ]]; then
    [[ -f "$key_file" && ! -L "$key_file" ]] || fail '密钥文件不存在或是符号链接'
    [[ "$(stat -c '%u' "$key_file")" == "0" ]] || fail '密钥文件必须归 root 所有'
    local perms
    perms="$(stat -c '%a' "$key_file")"
    (( (8#$perms & 077) == 0 )) || fail '密钥文件必须禁止组/其他用户访问（建议 chmod 600）'
    secret="$(cat "$key_file")"
  elif secret="$(extract_key_from_file "$EDGE_CONF")"; then
    log '复用现有 /etc/n2n/edge.conf 中的共享密钥' >&2
  elif secret="$(extract_key_from_file "$SUP_CONF")"; then
    log '检测到旧 Supervisor 配置中的密钥，迁移到 root-only 配置' >&2
  else
    [[ -r /dev/tty ]] || fail '没有可交互终端输入密钥；请通过网页提供共享密钥'
    printf '首次安装请输入 n2n 共享密钥（输入不显示）：' >/dev/tty
    IFS= read -r -s secret </dev/tty || fail '读取共享密钥失败'
    printf '\n' >/dev/tty
  fi
  validate_key "$secret"
  printf '%s' "$secret"
}

make_config() {
  local id="$1" secret="$2" path="$3"
  local identity="${ID_PREFIX}${id}"
  cat >"$path" <<EOF
# managed-by: jetson-orin-nano-devkit-n2n-setup v${VERSION}
# device-id: ${id}
-f
-k=${secret}
-c=${identity}_${id}
-I=${identity}
-A5
-l=${SUPER}
EOF
  chmod 600 "$path"
}

make_supervisor_config() {
  local path="$1"
  cat >"$path" <<'EOF'
[program:n2n-edge]
command=/usr/sbin/edge /etc/n2n/edge.conf
user=root
autostart=true
autorestart=true
startsecs=5
startretries=3000
stopsignal=TERM
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/n2n-edge.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=2
environment=PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
  chmod 644 "$path"
}

service_run() {
  systemctl enable --now supervisor >/dev/null
  local existed=0 state="" i
  if supervisorctl status n2n-edge >/dev/null 2>&1; then existed=1; fi
  supervisorctl reread
  supervisorctl update
  state="$(supervisorctl status n2n-edge 2>&1 || true)"
  if (( existed )); then
    if grep -Eq '[[:space:]](RUNNING|STARTING)[[:space:]]' <<<"$state"; then
      supervisorctl stop n2n-edge >/dev/null || warn '停止旧 edge 进程失败，尝试继续启动'
    fi
    supervisorctl start n2n-edge >/dev/null || return 1
  else
    if ! grep -Eq '[[:space:]](RUNNING|STARTING)[[:space:]]' <<<"$state"; then
      supervisorctl start n2n-edge >/dev/null || return 1
    fi
  fi
  for i in {1..20}; do
    state="$(supervisorctl status n2n-edge 2>&1 || true)"
    if grep -Eq '[[:space:]]RUNNING[[:space:]]' <<<"$state"; then
      log "Supervisor：$state"
      return 0
    fi
    if grep -Eq '[[:space:]]FATAL[[:space:]]' <<<"$state"; then
      warn "edge 进入 FATAL：$state"
      return 1
    fi
    sleep 1
  done
  warn "edge 未进入 RUNNING：${state:-unknown}"
  return 1
}

apply_config() {
  local id="$1" secret="$2" backup_dir cfg_tmp sup_tmp
  install -d -m 700 /etc/n2n /etc/supervisor/conf.d
  backup_dir="$(mktemp -d /etc/n2n/.jetson-orin-nano-devkit-n2n-backup.XXXXXXXX)"
  chmod 700 "$backup_dir"
  [[ ! -f "$EDGE_CONF" ]] || cp -p "$EDGE_CONF" "$backup_dir/edge.conf"
  [[ ! -f "$SUP_CONF" ]] || cp -p "$SUP_CONF" "$backup_dir/n2n-edge.conf"
  cfg_tmp="$(mktemp /etc/n2n/.edge.conf.XXXXXXXX)"
  sup_tmp="$(mktemp /etc/supervisor/conf.d/.n2n-edge.conf.XXXXXXXX)"
  make_config "$id" "$secret" "$cfg_tmp"
  make_supervisor_config "$sup_tmp"
  mv -f "$cfg_tmp" "$EDGE_CONF"
  mv -f "$sup_tmp" "$SUP_CONF"

  if ! service_run; then
    warn 'edge 启动验证失败，正在回滚原配置'
    if [[ -f "$backup_dir/edge.conf" ]]; then
      cp -p "$backup_dir/edge.conf" "$EDGE_CONF"
    else
      rm -f "$EDGE_CONF"
    fi
    if [[ -f "$backup_dir/n2n-edge.conf" ]]; then
      cp -p "$backup_dir/n2n-edge.conf" "$SUP_CONF"
    else
      rm -f "$SUP_CONF"
    fi
    supervisorctl reread || true
    supervisorctl update || true
    if [[ -f "$backup_dir/n2n-edge.conf" ]]; then
      supervisorctl restart n2n-edge || true
    fi
    fail "edge 启动失败，已尽可能恢复原配置。备份目录：${backup_dir}"
  fi

  log "设备编号：${id}"
  log "Identity：${ID_PREFIX}${id}"
  log "Community：${ID_PREFIX}${id}_${id}"
  log "旧配置 root-only 备份：${backup_dir}"
  log 'Supervisor RUNNING 不代表 Supernode 注册和对端通信成功，仍需实测组网'
}

read_current_id() {
  [[ -f "$EDGE_CONF" && ! -L "$EDGE_CONF" ]] || fail 'n2n edge 配置不存在'
  grep -q '^# managed-by: jetson-orin-nano-devkit-n2n-setup' "$EDGE_CONF" || \
    fail 'edge.conf 不由当前 Developer Kit 安装脚本管理，拒绝直接修改'
  local community identity id
  community="$(sed -n 's/^-c=//p' "$EDGE_CONF")"
  identity="$(sed -n 's/^-I=//p' "$EDGE_CONF")"
  [[ "$community" =~ ^${ID_PREFIX}([0-9]{3})_([0-9]{3})$ ]] || \
    fail '现有社区名称格式异常'
  id="${BASH_REMATCH[1]}"
  [[ "$id" == "${BASH_REMATCH[2]}" && "$identity" == "${ID_PREFIX}${id}" ]] || \
    fail '现有 -c 与 -I 不一致，请先检查配置'
  printf '%s' "$id"
}

read_new_key_twice() {
  local first="" second=""
  [[ -r /dev/tty && -w /dev/tty ]] || fail '--set-key 必须在本机终端或交互 SSH 中执行'
  printf '请输入新的 n2n 共享密钥（不回显）：' >/dev/tty
  IFS= read -r -s first </dev/tty || fail '读取新密钥失败，原配置未更改'
  printf '\n请再次输入以确认（不回显）：' >/dev/tty
  IFS= read -r -s second </dev/tty || fail '读取确认密钥失败，原配置未更改'
  printf '\n' >/dev/tty
  [[ "$first" == "$second" ]] || fail '两次输入的密钥不一致，原配置未更改'
  validate_key "$first"
  printf '%s' "$first"
  unset first second
}

apply_key_update() {
  local new_secret="$1" current_id="$2" backup_dir tmp line="" count=0
  install -d -m 700 /etc/n2n
  backup_dir="$(mktemp -d /etc/n2n/.jetson-orin-nano-devkit-n2n-key-backup.XXXXXXXX)"
  chmod 700 "$backup_dir"
  cp -p "$EDGE_CONF" "$backup_dir/edge.conf"
  chmod 600 "$backup_dir/edge.conf"
  tmp="$(mktemp /etc/n2n/.edge.conf.XXXXXXXX)"
  chmod 600 "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == -k=* ]]; then
      ((count+=1))
      printf '%s\n' "-k=${new_secret}"
    else
      printf '%s\n' "$line"
    fi
  done <"$EDGE_CONF" >"$tmp"
  if (( count != 1 )); then
    rm -f "$tmp"
    fail "现有配置的 -k= 条目数量异常：${count}；原配置未更改"
  fi
  mv -f "$tmp" "$EDGE_CONF"
  if ! service_run; then
    warn '新密钥应用失败，正在恢复原配置'
    cp -p "$backup_dir/edge.conf" "$EDGE_CONF"
    chmod 600 "$EDGE_CONF"
    supervisorctl restart n2n-edge >/dev/null 2>&1 || \
      warn '回滚后 edge 仍未成功重启，请检查日志'
    fail "密钥更新未完成，已恢复原配置；备份目录：${backup_dir}"
  fi
  log "已更新设备 ${current_id} 的共享密钥；-c、-I、-A5 和 Supernode 未改变"
  log "旧配置 root-only 备份：${backup_dir}/edge.conf"
  log '必须进一步验证实际组网通信'
}

show_status() {
  local model release community="not-configured" identity="not-configured"
  local id="not-configured" check="unknown"
  model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  release="$(uname -r)"
  if [[ -f "$EDGE_CONF" ]]; then
    community="$(sed -n 's/^-c=//p' "$EDGE_CONF" | head -n1)"
    identity="$(sed -n 's/^-I=//p' "$EDGE_CONF" | head -n1)"
    if [[ "$community" =~ ^${ID_PREFIX}([0-9]{3})_([0-9]{3})$ ]]; then
      id="${BASH_REMATCH[1]}"
      if [[ "$id" == "${BASH_REMATCH[2]}" && "$identity" == "${ID_PREFIX}${id}" ]]; then
        check="ok"
      else
        check="mismatch"
      fi
    fi
  fi
  printf 'Orin Nano Developer Kit setup version: %s\nModel: %s\nKernel: %s\n' "$VERSION" "$model" "$release"
  printf 'Device ID: %s\nCommunity: %s\nIdentity: %s\nConfig check: %s\n' "$id" "$community" "$identity" "$check"
  printf 'n2n version: '
  if n2n_is_311; then echo '3.1.1'; else echo 'unavailable/mismatch'; fi
  printf 'TUN device: '
  if [[ -c /dev/net/tun ]]; then echo present; else echo missing; fi
  printf 'Supervisor: '
  systemctl is-active supervisor 2>/dev/null || true
  supervisorctl status n2n-edge 2>/dev/null || true
  printf 'Overlay interfaces:\n'
  ip -br link 2>/dev/null | grep -E '^edge[0-9]*[[:space:]]' || true
  echo '(共享密钥不会在本命令中打印)'
}

install_self() {
  local script_path
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "$script_path" ]] || { warn '从标准输入执行，不能自动保存维护脚本'; return; }
  [[ "$script_path" == "$SELF_INSTALL" ]] && return
  install -D -m 755 "$script_path" "$SELF_INSTALL"
}

main() {
  local action="install" id="" key_file="" current_id="" old_secret="" new_secret=""
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    "")
      usage
      exit 2
      ;;
    --status)
      [[ $# -eq 1 ]] || fail '--status 不接受其他参数'
      require_root
      show_status
      exit 0
      ;;
    --set-id)
      [[ $# -eq 2 ]] || fail '用法：--set-id 084'
      action="set-id"
      id="$2"
      ;;
    --set-key)
      [[ $# -eq 1 ]] || fail '--set-key 不接受其他参数'
      action="set-key"
      ;;
    *)
      id="$1"
      shift
      if (($#)); then
        [[ $# -eq 2 && "$1" == "--key-file" ]] || \
          fail '仅支持 --key-file /root/n2n.key'
        key_file="$2"
      fi
      ;;
  esac

  [[ "$action" == "set-key" ]] || validate_id "$id"
  require_root
  acquire_lock
  ensure_log
  require_platform
  log "NVIDIA Orin Nano Developer Kit n2n setup ${VERSION}：操作=${action}${id:+；编号=${id}}"

  if [[ "$action" == "set-key" ]]; then
    current_id="$(read_current_id)"
    old_secret="$(extract_key_from_file "$EDGE_CONF")" || fail '旧配置中找不到共享密钥'
    new_secret="$(read_new_key_twice)"
    if [[ "$new_secret" == "$old_secret" ]]; then
      log '新旧密钥一致，不修改配置，也不重启 edge'
    else
      apply_key_update "$new_secret" "$current_id"
    fi
    unset old_secret new_secret
    install_self
    exit 0
  fi

  if [[ "$action" == "set-id" ]]; then
    current_id="$(read_current_id)"
    old_secret="$(extract_key_from_file "$EDGE_CONF")" || fail '现有配置中找不到共享密钥'
    validate_key "$old_secret"
    apply_config "$id" "$old_secret"
    unset old_secret
    install_self
    log '编号修改完成；没有重新编译 n2n'
    exit 0
  fi

  local edge_count current_status
  edge_count="$(pgrep -xc edge 2>/dev/null || true)"
  if [[ "$edge_count" =~ ^[0-9]+$ ]] && (( edge_count > 0 )); then
    current_status="$(supervisorctl status n2n-edge 2>/dev/null || true)"
    if (( edge_count != 1 )) || ! grep -Eq '[[:space:]](RUNNING|STARTING)[[:space:]]' <<<"$current_status"; then
      fail '检测到非当前 Supervisor 唯一管理的 edge 进程；为避免中断现有组网，拒绝接管，请先人工检查'
    fi
  fi

  ensure_build_parent
  install_packages_if_missing
  install_n2n
  ensure_tun
  local secret
  secret="$(get_secret "$key_file")"
  apply_config "$id" "$secret"
  unset secret
  install_self
  log "安装完成。修改编号：sudo ${SELF_INSTALL} --set-id 084"
  log "修改密钥：sudo ${SELF_INSTALL} --set-key"
  log "查看状态：sudo ${SELF_INSTALL} --status"
}

main "$@"
