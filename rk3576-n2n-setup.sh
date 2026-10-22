#!/usr/bin/env bash
# EAI-BOX1500 / RK3576 / Debian 12 / Linux 6.1.99
# n2n 3.1.1 bootstrap + TUN module + Supervisor
# Public-distribution safe: no embedded n2n encryption key.
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION="1.0.4"
N2N_VERSION="3.1.1"
N2N_COMMIT="ce998b986c633bc563835d8a3cc8f72a017b53d1"
KERNEL_REQUIRED="6.1.99"
N2N_SRC="/data/n2n-3.1.1"
TUN_SRC="/data/tun-module"
KDIR="/usr/src/linux-headers-6.1-rockchip"
TUN_URL="https://raw.githubusercontent.com/gregkh/linux/cac15753b8ceb505a3c646f83a86dccbab9e33a3/drivers/net/tun.c"
TUN_GIT_BLOB="4af1ba5d074c05abe37694fd22bf85b9c7654284"
SUPER="43.137.14.161:7799"
# 10-digit fixed root + exactly 3-digit site/device suffix.
# ID=083 -> identity=1712350000083, community=1712350000083_083
ID_PREFIX="1712350000"
EDGE_CONF="/etc/n2n/edge.conf"
SUP_CONF="/etc/supervisor/conf.d/n2n-edge.conf"
SELF_INSTALL="/usr/local/sbin/rk3576-n2n-setup"
LOG_FILE="/var/log/rk3576-n2n-setup.log"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
warn() { log "WARN: $*" >&2; }
usage() {
  cat <<'EOF'
用法：
  sudo bash rk3576-n2n-setup.sh 082              首次安装或更新编号
  sudo rk3576-n2n-setup --set-id 083            仅修改编号，不重装
  sudo rk3576-n2n-setup --set-key               重新输入共享密钥（两次确认），不重装
  sudo rk3576-n2n-setup --status                查看当前状态
  sudo bash rk3576-n2n-setup.sh 082 --key-file /root/n2n.key

编号必须恰好是 3 位数字（例如 001、082、999），保留前导零。
首次安装时，如果未发现原有密钥，将从本机终端隐藏输入一次。
--set-key 只更新已由本脚本生成的配置；终端隐藏输入新密钥两次。
若需完全无交互安装，请事先安全放置只有 root 可读的密钥文件，再加 --key-file 参数。
EOF
}
require_root() { [[ "${EUID}" -eq 0 ]] || fail '请使用 sudo 或 root 执行'; }
validate_id() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]{3}$ ]] || fail "编号 '${id}' 无效：只能输入三位数字，例如 082（82 不会自动补零）"
  local identity="${ID_PREFIX}${id}"
  local community="${identity}_${id}"
  ((${#community} <= 19)) || fail '社区名称超过 n2n 3.1.1 支持的 19 字节'
}
validate_key() {
  local secret="$1"
  [[ "$secret" =~ ^[A-Za-z0-9._@%+=:/-]{8,128}$ ]] || \
     fail '密钥格式不合规：需 8-128 个 ASCII 字符，仅允许字母、数字及 . _ @ % + = : / -'
}
ensure_log() {
  install -d -m 700 /var/log
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}
acquire_lock() {
  command -v flock >/dev/null || fail 'flock 不存在，无法保证单实例安装'
  exec 9>/run/lock/rk3576-n2n-setup.lock
  flock -n 9 || fail '另一安装/修改进程正在运行'
}
require_platform() {
  local soc="" release="" distro=""
  soc="$(tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null || :)"
  release="$(uname -r)"; distro="$(. /etc/os-release && echo "${ID}:${VERSION_ID}")"
  [[ "$(uname -m)" == 'aarch64' ]] || fail '只能在 aarch64 设备运行'
  grep -qx 'rockchip,rk3576' <<<"$soc" || fail '不是 RK3576，拒绝修改内核'
  [[ "$release" == "$KERNEL_REQUIRED" ]] || fail "内核为 $release，当前脚本只支持 $KERNEL_REQUIRED"
  [[ "$distro" == 'debian:12' ]] || fail "当前系统 $distro，脚本仅验证 Debian 12"
  log "平台通过：RK3576 / Debian 12 / Kernel ${release}"
}
package_installed_or_available() {
  local pkg="$1" binary="${2:-}"
  # Check the package's *actual* state, not the full dpkg "want/err/status"
  # string, which may vary across vendor images / held packages.
  if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)" == 'installed' ]]; then
    return 0
  fi
  # Vendor images may ship working binaries outside dpkg's package database.
  [[ -n "$binary" ]] && command -v "$binary" >/dev/null 2>&1
}
install_packages_if_missing() {
  local missing=()
  package_installed_or_available git git || missing+=(git)
  package_installed_or_available curl curl || missing+=(curl)
  if ! package_installed_or_available ca-certificates && [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    missing+=(ca-certificates)
  fi
  if ! package_installed_or_available build-essential &&
     { ! command -v gcc >/dev/null 2>&1 ||
       ! command -v g++ >/dev/null 2>&1 ||
       ! command -v make >/dev/null 2>&1; }; then
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
    log '所需依赖已具备，跳过 apt 更新与安装（避免触发无关的软件包升级）'
    return 0
  fi
  log "仅安装缺少的依赖：${missing[*]}"
  apt-get update
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
    warn 'APT 安装失败，可能存在软件源版本不一致或 hold；不会更改现有 curl/libcurl 版本'
    apt-cache policy curl libcurl4 >&2 || true
    apt-mark showhold >&2 || true
    fail '请先检查 APT 依赖，再重新执行脚本；当前还没有进入 n2n/服务配置阶段'
  fi
}

n2n_is_311() {
  [[ -x /usr/sbin/edge ]] || return 1
  local info
  info="$(/usr/sbin/edge -h 2>&1 || true)"
  [[ "$info" == *'n2n v.3.1.1'* ]]
}

install_n2n() {
  if n2n_is_311; then log 'n2n 3.1.1 已安装，跳过编译'; return 0; fi
  if [[ -e /usr/sbin/edge ]]; then
    fail '/usr/sbin/edge 已存在，但不是预期的 3.1.1；避免覆盖，需人工确认'
  fi
  mkdir -p /data
  if [[ ! -d "$N2N_SRC/.git" ]]; then
    [[ ! -e "$N2N_SRC" ]] || fail "源码目录 $N2N_SRC 已存在但不是 Git 仓库"
    log '下载 n2n 3.1.1 源码'
    git clone --branch "$N2N_VERSION" --depth 1 https://github.com/ntop/n2n.git "$N2N_SRC"
  fi
  # Avoid executing a pre-existing, user-writable source tree as root.
  [[ "$(stat -c '%u' "$N2N_SRC")" == 0 ]] || \
    fail "源目录 $N2N_SRC 非 root 所有，不能安全地作为 root 编译，请人工检查后重新准备"
  local src_mode
  src_mode="$(stat -c '%a' "$N2N_SRC")"
  (( (8#$src_mode & 022) == 0 )) || \
    fail "源目录 $N2N_SRC 可被非 root 写入，拒绝以 root 编译"
  local commit
  commit="$(git -C "$N2N_SRC" rev-parse HEAD)"
  [[ "$commit" == "$N2N_COMMIT" ]] || fail "n2n 源码提交不匹配，得到 $commit"
  log '编译 n2n（-j4，适合 2GB RAM）'
  ( cd "$N2N_SRC" && ./autogen.sh && ./configure && make -j4 && make install )
  ldconfig
  n2n_is_311 || fail 'n2n 安装后版本验证失败'
  log 'n2n 3.1.1 安装成功'
}

tap_probe() {
  [[ -c /dev/net/tun ]] || return 1
  local iface="ntest$$"
  if ! ip tuntap add dev "$iface" mode tap >/dev/null 2>&1; then return 1; fi
  ip link delete dev "$iface" >/dev/null 2>&1
}
ensure_tun_device_node() {
  if [[ ! -c /dev/net/tun && -d /sys/module/tun ]]; then
    install -d -m 755 /dev/net
    [[ ! -e /dev/net/tun ]] && mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
  fi
}
ensure_tun() {
  if tap_probe; then
    # A manually insmod'ed driver works now but may disappear on reboot.
    if [[ -f /proc/config.gz ]] && zcat /proc/config.gz | grep -x 'CONFIG_TUN=y' >/dev/null; then
      log 'TUN/TAP 已内置内核，跳过模块构建'
      return 0
    fi
    if modinfo -n tun >/dev/null 2>&1; then
      log 'TUN/TAP 可用且 tun.ko 可由 modprobe 找到，跳过模块构建'
      return 0
    fi
    if [[ -s "$TUN_SRC/tun.ko" ]]; then
      log 'TUN 已临时加载，但尚未永久安装，补装现有 tun.ko'
      local mod_dir="/lib/modules/$(uname -r)/extra"
      install -d -m 755 "$mod_dir"
      install -m 644 "$TUN_SRC/tun.ko" "$mod_dir/tun.ko"
      depmod -a || warn 'depmod 警告，请检查 modprobe'
      modinfo -n tun >/dev/null || fail '无法建立 tun.ko 模块索引'
      return 0
    fi
    fail 'TUN 已临时加载，但模块文件未安装且找不到构建产物，不能保证重启后恢复'
  fi
  log '尝试加载已有 TUN 模块'
  modprobe tun >/dev/null 2>&1 || true
  ensure_tun_device_node
  if tap_probe; then log '加载系统现有 TUN 模块成功'; return 0; fi

  log '系统没有可用的 TUN/TAP，准备构建与当前内核匹配的 tun.ko'
  [[ -d "$KDIR" ]] || fail "缺失 $KDIR，请向厂家获取正确 headers"
  [[ "$(make -s -C "$KDIR" kernelrelease)" == "$(uname -r)" ]] || fail 'headers release 与内核不匹配'
  for f in .config Module.symvers include/generated/autoconf.h include/generated/utsrelease.h; do
    [[ -s "$KDIR/$f" ]] || fail "headers 缺少 $f"
  done
  if [[ -f /proc/config.gz ]]; then
    zcat /proc/config.gz | grep -x 'CONFIG_MODULES=y' >/dev/null || fail '内核不支持动态模块'
  else
    fail '缺少 /proc/config.gz，无法安全确认内核选项'
  fi
  grep -qx '# CONFIG_TUN is not set' "$KDIR/.config" || \
    fail 'headers 的 CONFIG_TUN 与已验证方案不同，拒绝强制编译'
  if grep -qx 'CONFIG_MODVERSIONS=y' "$KDIR/.config"; then
    fail 'headers 开启了 CONFIG_MODVERSIONS，不属于本机验证过的模块构建路径'
  fi
  mkdir -p "$TUN_SRC"
  if [[ ! -s "$TUN_SRC/tun.c" ]]; then
    local bundled_tun="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/tun.c"
    if [[ -s "$bundled_tun" ]]; then
      log '从安装脚本同目录读取已打包的 Linux 6.1.99 tun.c（避开 GitHub Raw）'
      install -m 644 "$bundled_tun" "$TUN_SRC/tun.c"
    else
      log '安装包不含 tun.c，尝试从 GitHub Raw 下载内核源码'
      curl -fL --retry 3 --connect-timeout 10 --max-time 90 --proto '=https' --tlsv1.2 \
        "$TUN_URL" -o "$TUN_SRC/tun.c.tmp"
      mv "$TUN_SRC/tun.c.tmp" "$TUN_SRC/tun.c"
    fi
  fi
  [[ "$(git hash-object "$TUN_SRC/tun.c")" == "$TUN_GIT_BLOB" ]] || \
    fail 'tun.c 与固定 Linux stable 6.1.99 上游源码不一致，拒绝编译'
  cat > "$TUN_SRC/Makefile" <<'EOF'
obj-m += tun.o
ccflags-y += -DCONFIG_TUN_MODULE
EOF
  log '编译 tun.ko'
  make -C "$KDIR" M="$TUN_SRC" clean
  make -C "$KDIR" M="$TUN_SRC" modules
  [[ "$(modinfo -F vermagic "$TUN_SRC/tun.ko" | awk '{print $1}')" == "$(uname -r)" ]] || \
    fail 'tun.ko vermagic 与运行内核不匹配'
  local mod_dir="/lib/modules/$(uname -r)/extra"
  install -d -m 755 "$mod_dir"
  install -m 644 "$TUN_SRC/tun.ko" "$mod_dir/tun.ko"
  depmod -a || warn 'depmod 出现警告，继续验证加载'
  if ! modprobe tun; then
    fail 'modprobe tun 失败，请查看 dmesg；不会创建 Supervisor 服务'
  fi
  ensure_tun_device_node
  tap_probe || fail 'TUN 加载后 TAP 创建测试失败'
  log 'TUN/TAP 编译、加载和 TAP 实测成功'
}
install_tun_autoload() {
  install -d -m 755 /etc/modules-load.d
  printf 'tun\n' > /etc/modules-load.d/tun.conf
  chmod 644 /etc/modules-load.d/tun.conf
}
# Safe migration for pre-existing, locally configured n2n installs.
extract_key_from_old_file() {
  local line="" path="$1" found=""
  [[ -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^-k=(.+)$ ]]; then found="${BASH_REMATCH[1]}"; break; fi
    if [[ "$line" =~ (^|[[:space:]])-k[[:space:]]+([^[:space:]]+) ]]; then
      found="${BASH_REMATCH[2]}"; break
    fi
  done < "$path"
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}
get_secret() {
  local key_file="${1:-}" secret=''
  if [[ -n "$key_file" ]]; then
    [[ -f "$key_file" && ! -L "$key_file" ]] || fail '密钥文件不存在或是符号链接'
    [[ "$(stat -c '%u' "$key_file")" == 0 ]] || fail '密钥文件必须归 root 所有'
    local perms
    perms="$(stat -c '%a' "$key_file")"
    (( (8#$perms & 077) == 0 )) || fail '密钥文件必须禁止组/其他用户访问（建议 chmod 600）'
    secret="$(cat "$key_file")"
  elif secret="$(extract_key_from_old_file "$EDGE_CONF")"; then
    log '复用现有 /etc/n2n/edge.conf 中的密钥' >&2
  elif secret="$(extract_key_from_old_file "$SUP_CONF")"; then
    log '检测到旧 Supervisor 配置中的密钥，迁移到 root-only 配置' >&2
  else
    [[ -r /dev/tty ]] || fail '没有可交互终端输入密钥；请预置 root-only 密钥文件并使用 --key-file'
    printf '首次安装请输入 n2n 共享密钥（输入不显示）：' > /dev/tty
    IFS= read -r -s secret < /dev/tty || fail '读取共享密钥失败'
    printf '\n' > /dev/tty
  fi
  validate_key "$secret"
  printf '%s' "$secret"
}
make_config() {
  local id="$1" secret="$2" path="$3"
  local identity="${ID_PREFIX}${id}"
  cat > "$path" <<EOF
# managed-by: rk3576-n2n-setup v${VERSION}
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
  cat > "$path" <<'EOF'
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
  local existed=0 state='' i
  # supervisorctl update may automatically start new programs and leave them STARTING.
  if supervisorctl status n2n-edge >/dev/null 2>&1; then existed=1; fi
  supervisorctl reread
  supervisorctl update
  state="$(supervisorctl status n2n-edge 2>&1 || true)"
  if (( existed )); then
    # edge.conf changes are not visible to supervisord, so force a fresh process.
    # Stop first even if the program was STARTING; avoid restart/start races.
    if grep -Eq '[[:space:]](RUNNING|STARTING)[[:space:]]' <<<"$state"; then
      supervisorctl stop n2n-edge >/dev/null || warn '停止旧 edge 进程失败，尝试继续启动'
    fi
    supervisorctl start n2n-edge >/dev/null || return 1
  else
    # First install: update with autostart=true often starts the new program.
    # Never issue start while it is already STARTING.
    if ! grep -Eq '[[:space:]](RUNNING|STARTING)[[:space:]]' <<<"$state"; then
      supervisorctl start n2n-edge >/dev/null || return 1
    fi
  fi
  for i in {1..20}; do
    state="$(supervisorctl status n2n-edge 2>&1 || true)"
    if grep -Eq '[[:space:]]RUNNING[[:space:]]' <<<"$state"; then
      log "Supervisor: $state"
      return 0
    fi
    if grep -Eq '[[:space:]]FATAL[[:space:]]' <<<"$state"; then
      warn "进程进入 FATAL：$state"
      return 1
    fi
    sleep 1
  done
  warn "进程未进入 RUNNING：${state:-unknown}"
  return 1
}

# Backup/restore config if service cannot start, without destroying previous state.
apply_config() {
  local id="$1" secret="$2" backup_dir cfg_tmp sup_tmp
  install -d -m 700 /etc/n2n /etc/supervisor/conf.d
  backup_dir="$(mktemp -d /etc/n2n/.rk3576-backup.XXXXXXXX)"
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
    warn '启动验证失败，正在回滚原配置'
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
    fail "edge 进程启动失败，旧配置已尽可能恢复。备份目录：${backup_dir}；查看 /var/log/n2n-edge.log"
  fi
  log "已设置编号：$id；Identity：${ID_PREFIX}${id}；社区名称：${ID_PREFIX}${id}_${id}"
  log 'Supernode 注册与端到端连通性需要额外验证，RUNNING 不等于联网成功'
  log "旧配置备份：$backup_dir"
}
# Read and strictly validate the identity so --set-key cannot silently alter IDs.
read_current_id() {
  [[ -f "$EDGE_CONF" ]] || fail 'n2n edge 配置不存在：请先完成首次安装'
  grep -q '^# managed-by: rk3576-n2n-setup' "$EDGE_CONF" || \
    fail 'edge.conf 不由本脚本管理，拒绝直接修改密钥；请先完成迁移'
  local community identity id
  community="$(sed -n 's/^-c=//p' "$EDGE_CONF")"
  identity="$(sed -n 's/^-I=//p' "$EDGE_CONF")"
  [[ "$community" =~ ^${ID_PREFIX}([0-9]{3})_([0-9]{3})$ ]] || \
    fail '现有社区名称格式异常，拒绝修改；请先检查或使用 --set-id 修复'
  id="${BASH_REMATCH[1]}"
  [[ "$id" == "${BASH_REMATCH[2]}" && "$identity" == "${ID_PREFIX}${id}" ]] || \
    fail '现有 -c 与 -I 不一致，拒绝修改；请先使用 --set-id 修复'
  printf '%s' "$id"
}
# Secret must come from the terminal, never a shell argument or environment variable.
read_new_key_twice() {
  local first='' second=''
  [[ -r /dev/tty && -w /dev/tty ]] || \
    fail '未检测到可交互终端；--set-key 必须在工控机终端或交互 SSH 中运行'
  printf '请输入新的 n2n 共享密钥（不回显）：' > /dev/tty
  IFS= read -r -s first < /dev/tty || fail '新密钥读取失败，原配置未更改'
  printf '\n请再次输入以确认（不回显）：' > /dev/tty
  IFS= read -r -s second < /dev/tty || fail '确认密钥读取失败，原配置未更改'
  printf '\n' > /dev/tty
  [[ "$first" == "$second" ]] || fail '两次输入的密钥不一致，原配置未更改'
  validate_key "$first"
  printf '%s' "$first"
  unset first second
}
# Edit only the -k= line. All other configuration bytes and values remain unchanged.
# A protected backup permits rollback when Supervisor reports startup failure.
apply_key_update() {
  local new_secret="$1" current_id="$2" backup_dir tmp line='' count=0
  install -d -m 700 /etc/n2n
  backup_dir="$(mktemp -d /etc/n2n/.rk3576-key-backup.XXXXXXXX)"
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
  done < "$EDGE_CONF" > "$tmp"
  if (( count != 1 )); then
    rm -f "$tmp"
    fail "现有配置的 -k= 条目数量异常：${count}；原配置未更改"
  fi
  mv -f "$tmp" "$EDGE_CONF"
  if ! service_run; then
    warn '新密钥写入后 edge 启动失败，恢复上一个密钥并尝试重启'
    cp -p "$backup_dir/edge.conf" "$EDGE_CONF"
    chmod 600 "$EDGE_CONF"
    supervisorctl restart n2n-edge >/dev/null 2>&1 || \
      warn '回滚后 edge 仍未成功重启，请检查 Supervisor 状态和日志'
    fail "--set-key 未完成，已恢复原配置；备份目录：${backup_dir}"
  fi
  log "已更新设备 ${current_id} 的 n2n 共享密钥；-c、-I、-A5 与 Supernode 未改变"
  log "旧密钥的本地备份（root-only）：${backup_dir}/edge.conf"
  log '注意：edge 进程 RUNNING 不代表密钥正确或对端能通信，必须进一步验证组网'
}

show_status() {
  local community='not-configured' identity='not-configured' id='not-configured' parse_status='unknown'
  if [[ -f "$EDGE_CONF" ]]; then
    community="$(sed -n 's/^-c=//p' "$EDGE_CONF" | head -1)"
    identity="$(sed -n 's/^-I=//p' "$EDGE_CONF" | head -1)"
    if [[ "$community" =~ ^${ID_PREFIX}([0-9]{3})_([0-9]{3})$ ]]; then
      id="${BASH_REMATCH[1]}"
      if [[ "$id" == "${BASH_REMATCH[2]}" && "$identity" == "${ID_PREFIX}${id}" ]]; then
        parse_status='ok'
      else
        parse_status='mismatch: -c and -I do not agree (run --set-id NNN)'
      fi
    else
      parse_status='unexpected community format (run --set-id NNN)'
    fi
  fi
  printf 'Script: %s\n' "$VERSION"
  printf 'Kernel: %s\n' "$(uname -r)"
  printf 'Community: %s\nIdentity (-I): %s\nDevice ID: %s\nConfig check: %s\nSupernode: %s\n' \
    "$community" "$identity" "$id" "$parse_status" "$SUPER"
  printf 'n2n version: '
  if n2n_is_311; then echo '3.1.1'; else echo 'unavailable/mismatch'; fi
  printf 'TUN: '
  if [[ -c /dev/net/tun ]]; then echo 'device present'; else echo 'missing'; fi
  printf 'TUN autoload: '
  if [[ -f /etc/modules-load.d/tun.conf ]]; then cat /etc/modules-load.d/tun.conf; else echo 'not configured'; fi
  printf 'Supervisor: '
  systemctl is-active supervisor 2>/dev/null || true
  supervisorctl status n2n-edge 2>/dev/null || true
  printf 'Overlay links:\n'
  ip -br link 2>/dev/null | grep -E '^edge[0-9]*[[:space:]]' || true
  echo '(该命令不会输出 n2n 密钥)'
}
install_self() {
  local script_path
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "$script_path" ]] || { warn '当前使用标准输入启动，无法保存本地维护脚本'; return; }
  [[ "$script_path" == "$SELF_INSTALL" ]] && return
  install -m 755 "$script_path" "$SELF_INSTALL"
}
main() {
  local mode='install' id='' key_file=''
  case "${1:-}" in
    -h|--help|'') usage; [[ -n "${1:-}" ]] && exit 0 || exit 2 ;;
    --status) [[ $# -eq 1 ]] || fail '多余参数'; show_status; exit 0 ;;
    --set-id) mode='set-id'; [[ $# -eq 2 ]] || fail '用法：--set-id 083'; id="$2" ;;
    --set-key) mode='set-key'; [[ $# -eq 1 ]] || fail '用法：--set-key（交互输入新密钥）' ;;
    *) id="$1"; shift
       if [[ $# -gt 0 ]]; then
          [[ $# -eq 2 && "$1" == '--key-file' ]] || fail '仅支持可选的 --key-file /root/path'
          key_file="$2"
       fi ;;
  esac
  if [[ "$mode" != 'set-key' ]]; then validate_id "$id"; fi
  require_root
  acquire_lock
  ensure_log
  log "rk3576-n2n-setup $VERSION：操作=$mode${id:+；编号=$id}"
  if [[ "$mode" == 'set-key' ]]; then
    local current_id old_secret new_secret
    current_id="$(read_current_id)"
    old_secret="$(extract_key_from_old_file "$EDGE_CONF")" || fail '旧配置找不到 -k= 共享密钥'
    new_secret="$(read_new_key_twice)"
    if [[ "$new_secret" == "$old_secret" ]]; then
      log '新密钥与原密钥一致，未修改配置，也未重启 edge'
    else
      apply_key_update "$new_secret" "$current_id"
    fi
    unset old_secret new_secret
    install_self
    log '密钥设置操作完成；已更新本地维护脚本'
    exit 0
  fi
  if [[ "$mode" == 'set-id' ]]; then
    [[ -f "$EDGE_CONF" ]] || fail '尚未完成脚本部署，先运行：sudo bash 脚本.sh 082'
    grep -q '^# managed-by: rk3576-n2n-setup' "$EDGE_CONF" || fail '现有 edge.conf 不是本脚本生成的，避免误改；请先运行完整安装迁移'
    local secret
    secret="$(extract_key_from_old_file "$EDGE_CONF")" || fail '已有配置未找到密钥'
    validate_key "$secret"
    apply_config "$id" "$secret"
    unset secret
    install_self
    log '编号修改完成：没有重新编译 n2n / tun；已更新本地维护脚本'
    exit 0
  fi
  require_platform
  install_packages_if_missing
  install_n2n
  ensure_tun
  install_tun_autoload
  local secret
  secret="$(get_secret "$key_file")"
  apply_config "$id" "$secret"
  unset secret
  install_self
  log "部署完成。下次改编号：sudo $SELF_INSTALL --set-id 083"
  log "状态查看：sudo $SELF_INSTALL --status"
}
main "$@"
