#!/usr/bin/env bash
# NVIDIA Jetson Orin Nano / Jetson Orin (Tegra234) - n2n 3.1.1 installer
# Public repository safe: intentionally contains NO shared n2n key.
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION='1.0.0'
N2N_VERSION='3.1.1'
N2N_COMMIT='ce998b986c633bc563835d8a3cc8f72a017b53d1'
ID_PREFIX='1712350000'
SUPER='43.137.14.161:7799'
CONFIG_DIR='/etc/n2n'
EDGE_CONF="${CONFIG_DIR}/edge.conf"
SUP_CONF='/etc/supervisor/conf.d/n2n-edge.conf'
SELF_INSTALL='/usr/local/sbin/jetson-n2n-setup'
LOG_FILE='/var/log/jetson-n2n-setup.log'
BUILD_PARENT='/data'
N2N_SRC="${BUILD_PARENT}/n2n-3.1.1"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
warn() { log "WARN: $*" >&2; }
usage() {
  cat <<'EOF'
Jetson Orin Nano n2n 3.1.1 自动部署 v1.0.0
  sudo bash jetson-orin-n2n-setup.sh 083
  sudo jetson-n2n-setup --set-id 084
  sudo jetson-n2n-setup --set-key
  sudo jetson-n2n-setup --status
  sudo bash jetson-orin-n2n-setup.sh 083 --key-file /root/n2n.key

编号必须为三位十进制数字，如 001、082、999。首次配置在终端隐藏输入共享密钥。
--set-key 隐藏输入两次，修改密钥并重启 edge；不重装 n2n。
--set-id 同时更新 -c 和 -I；不重装 n2n。
EOF
}
require_root() { [[ "$EUID" == 0 ]] || fail '请使用 sudo 执行'; }
validate_id() {
  local id="${1:-}" community
  [[ "$id" =~ ^[0-9]{3}$ ]] || fail "设备编号必须是三位数字，当前为 '${id}'"
  community="${ID_PREFIX}${id}_${id}"
  ((${#community} <= 19)) || fail 'n2n 社区名超长'
}
validate_key() {
  [[ "$1" =~ ^[A-Za-z0-9._@%+=:/-]{8,128}$ ]] || fail '密钥格式不合规：需要 8-128 位 ASCII，允许字母、数字及 . _ @ % + = : / -'
}
acquire_lock() {
  command -v flock >/dev/null || fail '系统缺少 flock'
  install -d -m 755 /run/lock
  exec 9>/run/lock/jetson-n2n-setup.lock
  flock -n 9 || fail '另一个 Jetson n2n 安装或修改操作正在进行'
}
ensure_log() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}
require_platform() {
  local compatible='' model='' distro='' kernel=''
  [[ "$(uname -m)" == 'aarch64' ]] || fail '仅支持 ARM64/aarch64'
  [[ -r /etc/os-release ]] || fail '/etc/os-release 不存在'
  distro="$(. /etc/os-release; printf '%s:%s' "$ID" "$VERSION_ID")"
  [[ "$distro" =~ ^(ubuntu:(18\.04|20\.04|22\.04|24\.04)|debian:(11|12))$ ]] || \
    fail "不支持的操作系统：$distro，需人工确认"
  [[ -r /proc/device-tree/compatible ]] && compatible="$(tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null || true)"
  [[ -r /proc/device-tree/model ]] && model="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
  if ! grep -qiE '(^nvidia,tegra234$|tegra234|jetson.orin)' <<<"${compatible} ${model}"; then
    fail "未确认 NVIDIA Tegra234 / Jetson Orin 平台（model=${model:-unknown}），拒绝安装"
  fi
  kernel="$(uname -r)"
  log "平台检查通过：${model:-Tegra234} / ${distro} / kernel ${kernel}"
  log 'Jetson 版只使用内核原有 TUN/TAP 驱动，不编译 RK3576 tun.ko'
}
package_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == 'installed' ]]
}
package_or_bin() {
  package_installed "$1" || command -v "$2" >/dev/null 2>&1
}
install_dependencies() {
  local missing=()
  package_or_bin git git || missing+=(git)
  package_or_bin curl curl || missing+=(curl)
  if ! package_installed ca-certificates && [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    missing+=(ca-certificates)
  fi
  if ! package_installed build-essential && {
    ! command -v gcc >/dev/null || ! command -v g++ >/dev/null || ! command -v make >/dev/null; }; then
    missing+=(build-essential)
  fi
  package_or_bin autoconf autoreconf || missing+=(autoconf)
  package_or_bin automake automake || missing+=(automake)
  package_or_bin libtool libtoolize || missing+=(libtool)
  package_or_bin pkg-config pkg-config || missing+=(pkg-config)
  package_or_bin iproute2 ip || missing+=(iproute2)
  package_or_bin kmod modprobe || missing+=(kmod)
  package_or_bin supervisor supervisorctl || missing+=(supervisor)
  if ((${#missing[@]} == 0)); then
    log '所需依赖已具备，跳过 apt（避免影响厂商软件包）'
    return
  fi
  log "仅安装缺少的依赖：${missing[*]}"
  apt-get update
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"; then
    warn 'APT 安装失败；不会自动取消 hold 或升级系统所有软件包'
    apt-cache policy "${missing[@]}" >&2 || true
    fail '请先解决缺失依赖，再重新执行脚本'
  fi
}
n2n_is_311() {
  [[ -x /usr/sbin/edge ]] || return 1
  local output
  output="$(/usr/sbin/edge -h 2>&1 || true)"
  [[ "$output" == *'n2n v.3.1.1'* ]]
}
install_n2n() {
  if n2n_is_311; then
    log '已安装 n2n 3.1.1，跳过编译'
    return
  fi
  [[ ! -e /usr/sbin/edge ]] || fail '/usr/sbin/edge 已存在且不是预期 3.1.1，拒绝覆盖'
  install -d -m 755 "$BUILD_PARENT"
  # An existing source tree may be owned by a normal user; never run its build scripts as root.
  if [[ -e "$N2N_SRC" ]]; then
    log "已有源码目录 ${N2N_SRC}，不信任其内容；创建独立的 root 私有构建目录"
    N2N_SRC="$(mktemp -d "${BUILD_PARENT}/.jetson-n2n-3.1.1-build.XXXXXXXX")"
  fi
  log '克隆官方 n2n 3.1.1 源码'
  git clone --branch "$N2N_VERSION" --depth 1 https://github.com/ntop/n2n.git "$N2N_SRC"
  # Root-owned clone; do not execute untrusted pre-existing, user-writable source as root.
  local src="$N2N_SRC" commit
  commit="$(git -C "$src" rev-parse HEAD)"
  [[ "$commit" == "$N2N_COMMIT" ]] || fail "n2n 3.1.1 Git 提交不匹配：${commit}"
  log '编译并安装 n2n 3.1.1（最多 4 个并行任务）'
  ( cd "$src" && ./autogen.sh && ./configure && make -j4 && make install )
  ldconfig
  n2n_is_311 || fail '编译完成，但 /usr/sbin/edge 未通过 3.1.1 版本检测'
  log 'n2n 3.1.1 安装成功'
}
probe_tap() {
  [[ -c /dev/net/tun ]] || return 1
  local iface="jn2nt$$"
  ip tuntap add dev "$iface" mode tap >/dev/null 2>&1 || return 1
  ip link delete dev "$iface" >/dev/null 2>&1
}
make_tun_node_if_driver_present() {
  if [[ ! -c /dev/net/tun ]] && { [[ -d /sys/module/tun ]] || [[ -d /sys/class/misc/tun ]]; }; then
    install -d -m 755 /dev/net
    [[ ! -e /dev/net/tun ]] && mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
  fi
}
config_tun_builtin() {
  local f
  for f in /proc/config.gz "/boot/config-$(uname -r)"; do
    if [[ -r "$f" ]]; then
      if [[ "$f" == *.gz ]]; then
        zcat "$f" 2>/dev/null | grep -qx 'CONFIG_TUN=y' && return 0
      else
        grep -qx 'CONFIG_TUN=y' "$f" && return 0
      fi
    fi
  done
  return 1
}
ensure_tun() {
  modprobe tun >/dev/null 2>&1 || true
  make_tun_node_if_driver_present
  probe_tap || fail 'TUN/TAP 测试未通过。Jetson 版不会强行编译外部模块；请检查内核 CONFIG_TUN、/dev/net/tun、sudo dmesg'
  if config_tun_builtin; then
    log 'TUN/TAP 已内建于 Jetson 内核，TAP 测试通过'
  elif modinfo -n tun >/dev/null 2>&1; then
    install -d -m 755 /etc/modules-load.d
    printf 'tun\n' >/etc/modules-load.d/tun.conf
    chmod 644 /etc/modules-load.d/tun.conf
    log 'TUN/TAP 模块可通过 modprobe 加载，已配置开机自动加载'
  else
    fail '虽然 TAP 当前可用，但无法证明重启后 tun 会自动恢复；请核对内核配置及模块文件'
  fi
}
extract_key() {
  local file="$1" line='' found=''
  [[ -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^-k=(.+)$ ]]; then found="${BASH_REMATCH[1]}"; break; fi
    if [[ "$line" =~ (^|[[:space:]])-k[[:space:]]+([^[:space:]]+) ]]; then
      found="${BASH_REMATCH[2]}"; break
    fi
  done < "$file"
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}
get_secret() {
  local keyfile="${1:-}" secret='' perms
  if [[ -n "$keyfile" ]]; then
    [[ -f "$keyfile" && ! -L "$keyfile" ]] || fail '指定密钥文件不存在或为符号链接'
    [[ "$(stat -c '%u' "$keyfile")" == 0 ]] || fail '密钥文件必须是 root 所有'
    perms="$(stat -c '%a' "$keyfile")"
    (( (8#$perms & 077) == 0 )) || fail '密钥文件权限必须阻止非 root 访问（chmod 600）'
    secret="$(cat "$keyfile")"
  elif secret="$(extract_key "$EDGE_CONF")"; then
    log '复用现有 edge.conf 的密钥' >&2
  elif secret="$(extract_key "$SUP_CONF")"; then
    log '从旧 Supervisor 配置迁移密钥到 root 私有配置' >&2
  else
    [[ -r /dev/tty && -w /dev/tty ]] || fail '当前没有交互终端；可使用 --key-file /root/n2n.key'
    printf '首次安装请输入 n2n 共享密钥（不回显）：' >/dev/tty
    IFS= read -r -s secret </dev/tty || fail '读取密钥失败'
    printf '\n' >/dev/tty
  fi
  validate_key "$secret"
  printf '%s' "$secret"
}
read_new_key_twice() {
  local first='' second=''
  [[ -r /dev/tty && -w /dev/tty ]] || fail '必须在交互终端执行 --set-key'
  printf '请输入新共享密钥（不回显）：' >/dev/tty
  IFS= read -r -s first </dev/tty || fail '读取新密钥失败'
  printf '\n再次输入新共享密钥（不回显）：' >/dev/tty
  IFS= read -r -s second </dev/tty || fail '读取确认密钥失败'
  printf '\n' >/dev/tty
  [[ "$first" == "$second" ]] || fail '两次密钥不一致，原配置未更改'
  validate_key "$first"
  printf '%s' "$first"
}
render_edge_conf() {
  local id="$1" secret="$2" out="$3" ident="${ID_PREFIX}${1}"
  cat >"$out" <<EOF
# managed-by: jetson-n2n-setup v${VERSION}
# device-id: ${id}
-f
-k=${secret}
-c=${ident}_${id}
-I=${ident}
-A5
-l=${SUPER}
EOF
  chmod 600 "$out"
}
render_supervisor_conf() {
  local out="$1"
  cat >"$out" <<'EOF'
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
  chmod 644 "$out"
}
run_service() {
  systemctl enable --now supervisor >/dev/null
  local existed=0 state='' i
  supervisorctl status n2n-edge >/dev/null 2>&1 && existed=1
  supervisorctl reread
  supervisorctl update
  state="$(supervisorctl status n2n-edge 2>&1 || true)"
  if (( existed )); then
    if grep -Eq '[[:space:]](RUNNING|STARTING)[[:space:]]' <<<"$state"; then
      supervisorctl stop n2n-edge >/dev/null || return 1
    fi
    supervisorctl start n2n-edge >/dev/null || return 1
  elif ! grep -Eq '[[:space:]](RUNNING|STARTING)[[:space:]]' <<<"$state"; then
    supervisorctl start n2n-edge >/dev/null || return 1
  fi
  for i in {1..20}; do
    state="$(supervisorctl status n2n-edge 2>&1 || true)"
    if grep -Eq '[[:space:]]RUNNING[[:space:]]' <<<"$state"; then
      log "Supervisor: $state"
      return 0
    fi
    if grep -Eq '[[:space:]]FATAL[[:space:]]' <<<"$state"; then
      warn "Supervisor FATAL: $state"
      return 1
    fi
    sleep 1
  done
  warn "Supervisor 尚未处于 RUNNING：$state"
  return 1
}
restore_config() {
  local backup="$1"
  if [[ -f "$backup/edge.conf" ]]; then
    cp -p "$backup/edge.conf" "$EDGE_CONF"
  else
    rm -f "$EDGE_CONF"
  fi
  if [[ -f "$backup/n2n-edge.conf" ]]; then
    cp -p "$backup/n2n-edge.conf" "$SUP_CONF"
  else
    rm -f "$SUP_CONF"
  fi
  supervisorctl reread >/dev/null 2>&1 || true
  supervisorctl update >/dev/null 2>&1 || true
  if [[ -f "$backup/n2n-edge.conf" ]]; then
    supervisorctl restart n2n-edge >/dev/null 2>&1 || true
  fi
}
apply_full_config() {
  local id="$1" key="$2" backup configtmp suptmp
  install -d -m 700 "$CONFIG_DIR"
  install -d -m 755 "$(dirname "$SUP_CONF")"
  backup="$(mktemp -d "${CONFIG_DIR}/.jetson-n2n-backup.XXXXXXXX")"
  [[ ! -f "$EDGE_CONF" ]] || cp -p "$EDGE_CONF" "$backup/edge.conf"
  [[ ! -f "$SUP_CONF" ]] || cp -p "$SUP_CONF" "$backup/n2n-edge.conf"
  configtmp="$(mktemp "${CONFIG_DIR}/.edge.conf.XXXXXXXX")"
  suptmp="$(mktemp "$(dirname "$SUP_CONF")/.n2n-edge.conf.XXXXXXXX")"
  render_edge_conf "$id" "$key" "$configtmp"
  render_supervisor_conf "$suptmp"
  mv -f "$configtmp" "$EDGE_CONF"
  mv -f "$suptmp" "$SUP_CONF"
  if ! run_service; then
    warn 'Supervisor 启动失败，恢复上次配置'
    restore_config "$backup"
    fail "配置已尝试回滚。备份：${backup}；检查 /var/log/n2n-edge.log"
  fi
  log "设备编号：${id}；社区：${ID_PREFIX}${id}_${id}；身份：${ID_PREFIX}${id}"
  log "旧配置备份（root-only）：${backup}"
}
read_current_id() {
  [[ -r "$EDGE_CONF" ]] || fail '缺少 edge.conf，请先完成首次安装'
  grep -q '^# managed-by: jetson-n2n-setup' "$EDGE_CONF" || \
    fail 'edge.conf 并非 Jetson 脚本管理的配置，请先执行完整安装以迁移'
  local community identity id
  community="$(sed -n 's/^-c=//p' "$EDGE_CONF")"
  identity="$(sed -n 's/^-I=//p' "$EDGE_CONF")"
  [[ "$community" =~ ^${ID_PREFIX}([0-9]{3})_([0-9]{3})$ ]] || fail '社区名称格式异常'
  id="${BASH_REMATCH[1]}"
  [[ "$id" == "${BASH_REMATCH[2]}" && "$identity" == "${ID_PREFIX}${id}" ]] || fail '现有 -c、-I 参数不一致，请先用 --set-id 修复'
  printf '%s' "$id"
}
apply_key_only() {
  local key="$1" id="$2" backup tmp line='' count=0
  install -d -m 700 "$CONFIG_DIR"
  backup="$(mktemp -d "${CONFIG_DIR}/.jetson-n2n-key-backup.XXXXXXXX")"
  cp -p "$EDGE_CONF" "$backup/edge.conf"
  tmp="$(mktemp "${CONFIG_DIR}/.edge.conf.XXXXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == -k=* ]]; then
      ((count+=1))
      printf '%s\n' "-k=${key}"
    else
      printf '%s\n' "$line"
    fi
  done < "$EDGE_CONF" > "$tmp"
  if (( count != 1 )); then
    rm -f "$tmp"
    fail "现有配置中 -k= 条目数量不等于 1（发现 ${count}）；未修改"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$EDGE_CONF"
  if ! run_service; then
    warn '新密钥配置启动失败，尝试恢复旧密钥'
    cp -p "$backup/edge.conf" "$EDGE_CONF"
    supervisorctl restart n2n-edge >/dev/null 2>&1 || true
    fail "已尝试恢复旧密钥，备份：${backup}"
  fi
  log "设备 ${id} 的密钥已更新；-c、-I、-A5、Supernode 未改变"
  log "旧配置备份（root-only）：${backup}/edge.conf"
  log '注意：进程 RUNNING 不代表密钥与对端匹配，需实测通信'
}
show_status() {
  local community='not configured' identity='not configured' id='not configured' verify='not configured'
  if [[ -r "$EDGE_CONF" ]]; then
    community="$(sed -n 's/^-c=//p' "$EDGE_CONF" | head -n1)"
    identity="$(sed -n 's/^-I=//p' "$EDGE_CONF" | head -n1)"
    if [[ "$community" =~ ^${ID_PREFIX}([0-9]{3})_([0-9]{3})$ ]]; then
      id="${BASH_REMATCH[1]}"
      if [[ "$id" == "${BASH_REMATCH[2]}" && "$identity" == "${ID_PREFIX}${id}" ]]; then
        verify='ok'
      else
        verify='mismatch'
      fi
    else
      verify='unexpected community format'
    fi
  fi
  printf 'Jetson setup version: %s\nKernel: %s\n' "$VERSION" "$(uname -r)"
  printf 'ID: %s\nCommunity (-c): %s\nIdentity (-I): %s\nConfig check: %s\n' "$id" "$community" "$identity" "$verify"
  printf 'Supernode: %s\nn2n version: ' "$SUPER"
  if n2n_is_311; then echo '3.1.1'; else echo 'not found / different'; fi
  printf 'TUN device: '
  if [[ -c /dev/net/tun ]]; then echo present; else echo missing; fi
  printf 'Supervisor service: '
  systemctl is-active supervisor 2>/dev/null || true
  supervisorctl status n2n-edge 2>/dev/null || true
  printf 'Overlay interfaces:\n'
  ip -br link 2>/dev/null | grep -E '^edge[0-9]*[[:space:]]' || true
  echo '(共享密钥不会在本命令中打印)'
}
install_self() {
  local script
  script="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "$script" ]] || { warn '从 stdin 执行，不能自动保存维护脚本'; return; }
  [[ "$script" == "$SELF_INSTALL" ]] && return
  install -D -m 755 "$script" "$SELF_INSTALL"
}
main() {
  local action='install' id='' keyfile='' current_id='' newkey='' oldkey=''
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    '') usage; exit 2 ;;
    --status) [[ $# -eq 1 ]] || fail '--status 不接受其他参数'; show_status; exit 0 ;;
    --set-id) [[ $# -eq 2 ]] || fail '用法：--set-id 083'; action='set-id'; id="$2" ;;
    --set-key) [[ $# -eq 1 ]] || fail '用法：--set-key'; action='set-key' ;;
    *) id="$1"; shift
       if (( $# )); then
         [[ $# -eq 2 && "$1" == '--key-file' ]] || fail '仅支持 --key-file /root/n2n.key'
         keyfile="$2"
       fi ;;
  esac
  [[ "$action" == 'set-key' ]] || validate_id "$id"
  require_root
  acquire_lock
  ensure_log
  log "jetson-n2n-setup ${VERSION}：操作=${action}${id:+；编号=${id}}"
  if [[ "$action" == 'set-id' ]]; then
    require_platform
    [[ -r "$EDGE_CONF" ]] || fail '尚未安装，不能仅修改编号'
    grep -q '^# managed-by: jetson-n2n-setup' "$EDGE_CONF" || fail '已有配置不是 Jetson 脚本管理的，请先完整安装迁移'
    oldkey="$(extract_key "$EDGE_CONF")" || fail '找不到旧密钥'
    validate_key "$oldkey"
    apply_full_config "$id" "$oldkey"
    install_self
    log '仅修改编号完成，没有重新编译 n2n'
    exit 0
  fi
  if [[ "$action" == 'set-key' ]]; then
    require_platform
    current_id="$(read_current_id)"
    oldkey="$(extract_key "$EDGE_CONF")" || fail '找不到旧密钥'
    newkey="$(read_new_key_twice)"
    if [[ "$newkey" == "$oldkey" ]]; then
      log '新旧密钥一致，不修改配置和重启'
    else
      apply_key_only "$newkey" "$current_id"
    fi
    unset oldkey newkey
    install_self
    exit 0
  fi
  require_platform
  install_dependencies
  install_n2n
  ensure_tun
  keyfile="$(get_secret "$keyfile")"
  # Protect existing independently managed edge instances; do not pkill all edges.
  if pgrep -x edge >/dev/null 2>&1 && ! supervisorctl status n2n-edge >/dev/null 2>&1; then
    fail '检测到非 n2n-edge Supervisor 管理的 edge 进程；为避免冲突，未更改现有服务。请人工检查 ps -ef | grep [e]dge'
  fi
  apply_full_config "$id" "$keyfile"
  unset keyfile
  install_self
  log "安装完成：更改编号 sudo ${SELF_INSTALL} --set-id 084；更改密钥 --set-key；检查 --status"
  log '需要检查 Supernode 注册与节点间通信，不能只看 Supervisor RUNNING'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
