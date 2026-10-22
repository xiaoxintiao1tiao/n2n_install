#!/usr/bin/env bash
# EAI-BOX1500 / RK3576 / Debian 12 / Linux 6.1.99
# n2n 3.1.1 bootstrap + TUN module + Supervisor
# Public-distribution safe: no embedded n2n encryption key.
set -Eeuo pipefail
umask 077
export LC_ALL=C

VERSION="1.0.1"
N2N_VERSION="3.1.1"
N2N_COMMIT="ce998b986c633bc563835d8a3cc8f72a017b53d1"
KERNEL_REQUIRED="6.1.99"
N2N_SRC="/data/n2n-3.1.1"
TUN_SRC="/data/tun-module"
KDIR="/usr/src/linux-headers-6.1-rockchip"
TUN_URL="https://raw.githubusercontent.com/gregkh/linux/cac15753b8ceb505a3c646f83a86dccbab9e33a3/drivers/net/tun.c"
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
�÷���
  sudo bash rk3576-n2n-setup.sh 082              �״ΰ�װ����±��
  sudo rk3576-n2n-setup --set-id 083            ���޸ı�ţ�����װ
  sudo rk3576-n2n-setup --status                �鿴��ǰ״̬
  sudo bash rk3576-n2n-setup.sh 082 --key-file /root/n2n.key

��ű���ǡ���� 3 λ���֣����� 001��082��999��������ǰ���㡣
�״ΰ�װʱ�����δ����ԭ����Կ�����ӱ����ն���������һ�Ρ�
������ȫ�޽�����װ�������Ȱ�ȫ����ֻ�� root �ɶ�����Կ�ļ����ټ� --key-file ������
EOF
}
require_root() { [[ "${EUID}" -eq 0 ]] || fail '��ʹ�� sudo �� root ִ��'; }
validate_id() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]{3}$ ]] || fail "��� '${id}' ��Ч��ֻ��������λ���֣����� 082��82 �����Զ����㣩"
  local identity="${ID_PREFIX}${id}"
  local community="${identity}_${id}"
  ((${#community} <= 19)) || fail '�������Ƴ��� n2n 3.1.1 ֧�ֵ� 19 �ֽ�'
}
validate_key() {
  local secret="$1"
  [[ "$secret" =~ ^[A-Za-z0-9._@%+=:/-]{8,128}$ ]] || \
     fail '��Կ��ʽ���Ϲ棺�� 8-128 �� ASCII �ַ�����������ĸ�����ּ� . _ @ % + = : / -'
}
ensure_log() {
  install -d -m 700 /var/log
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}
acquire_lock() {
  command -v flock >/dev/null || fail 'flock �����ڣ��޷���֤��ʵ����װ'
  exec 9>/run/lock/rk3576-n2n-setup.lock
  flock -n 9 || fail '��һ��װ/�޸Ľ�����������'
}
require_platform() {
  local soc="" release="" distro=""
  soc="$(tr '\0' '\n' </proc/device-tree/compatible 2>/dev/null || :)"
  release="$(uname -r)"; distro="$(. /etc/os-release && echo "${ID}:${VERSION_ID}")"
  [[ "$(uname -m)" == 'aarch64' ]] || fail 'ֻ���� aarch64 �豸����'
  grep -qx 'rockchip,rk3576' <<<"$soc" || fail '���� RK3576���ܾ��޸��ں�'
  [[ "$release" == "$KERNEL_REQUIRED" ]] || fail "�ں�Ϊ $release����ǰ�ű�ֻ֧�� $KERNEL_REQUIRED"
  [[ "$distro" == 'debian:12' ]] || fail "��ǰϵͳ $distro���ű�����֤ Debian 12"
  log "ƽ̨ͨ����RK3576 / Debian 12 / Kernel ${release}"
}
install_packages_if_missing() {
  local packages=(git curl ca-certificates build-essential autoconf automake libtool pkg-config iproute2 kmod supervisor)
  local missing=() p
  for p in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -qx 'install ok installed'; then
      missing+=("$p")
    fi
  done
  if ((${#missing[@]})); then
    log "��װȱ�ٵ�ϵͳ������${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    log '����ϵͳ�������Ѱ�װ'
  fi
}
n2n_is_311() {
  [[ -x /usr/sbin/edge ]] &&
    /usr/sbin/edge -h 2>&1 | grep -q 'n2n v\.3\.1\.1'
}
install_n2n() {
  if n2n_is_311; then log 'n2n 3.1.1 �Ѱ�װ����������'; return 0; fi
  if [[ -e /usr/sbin/edge ]]; then
    fail '/usr/sbin/edge �Ѵ��ڣ�������Ԥ�ڵ� 3.1.1�����⸲�ǣ����˹�ȷ��'
  fi
  mkdir -p /data
  if [[ ! -d "$N2N_SRC/.git" ]]; then
    [[ ! -e "$N2N_SRC" ]] || fail "Դ��Ŀ¼ $N2N_SRC �Ѵ��ڵ����� Git �ֿ�"
    log '���� n2n 3.1.1 Դ��'
    git clone --branch "$N2N_VERSION" --depth 1 https://github.com/ntop/n2n.git "$N2N_SRC"
  fi
  # Avoid executing a pre-existing, user-writable source tree as root.
  [[ "$(stat -c '%u' "$N2N_SRC")" == 0 ]] || \
    fail "ԴĿ¼ $N2N_SRC �� root ���У����ܰ�ȫ����Ϊ root ���룬���˹���������׼��"
  local src_mode
  src_mode="$(stat -c '%a' "$N2N_SRC")"
  (( (8#$src_mode & 022) == 0 )) || \
    fail "ԴĿ¼ $N2N_SRC �ɱ��� root д�룬�ܾ��� root ����"
  local commit
  commit="$(git -C "$N2N_SRC" rev-parse HEAD)"
  [[ "$commit" == "$N2N_COMMIT" ]] || fail "n2n Դ���ύ��ƥ�䣬�õ� $commit"
  log '���� n2n��-j4���ʺ� 2GB RAM��'
  ( cd "$N2N_SRC" && ./autogen.sh && ./configure && make -j4 && make install )
  ldconfig
  n2n_is_311 || fail 'n2n ��װ��汾��֤ʧ��'
  log 'n2n 3.1.1 ��װ�ɹ�'
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
    if [[ -f /proc/config.gz ]] && zcat /proc/config.gz | grep -qx 'CONFIG_TUN=y'; then
      log 'TUN/TAP �������ںˣ�����ģ�鹹��'
      return 0
    fi
    if modinfo -n tun >/dev/null 2>&1; then
      log 'TUN/TAP ������ tun.ko ���� modprobe �ҵ�������ģ�鹹��'
      return 0
    fi
    if [[ -s "$TUN_SRC/tun.ko" ]]; then
      log 'TUN ����ʱ���أ�����δ���ð�װ����װ���� tun.ko'
      local mod_dir="/lib/modules/$(uname -r)/extra"
      install -d -m 755 "$mod_dir"
      install -m 644 "$TUN_SRC/tun.ko" "$mod_dir/tun.ko"
      depmod -a || warn 'depmod ���棬���� modprobe'
      modinfo -n tun >/dev/null || fail '�޷����� tun.ko ģ������'
      return 0
    fi
    fail 'TUN ����ʱ���أ���ģ���ļ�δ��װ���Ҳ�������������ܱ�֤������ָ�'
  fi
  log '���Լ������� TUN ģ��'
  modprobe tun >/dev/null 2>&1 || true
  ensure_tun_device_node
  if tap_probe; then log '����ϵͳ���� TUN ģ��ɹ�'; return 0; fi

  log 'ϵͳû�п��õ� TUN/TAP��׼�������뵱ǰ�ں�ƥ��� tun.ko'
  [[ -d "$KDIR" ]] || fail "ȱʧ $KDIR�����򳧼һ�ȡ��ȷ headers"
  [[ "$(make -s -C "$KDIR" kernelrelease)" == "$(uname -r)" ]] || fail 'headers release ���ں˲�ƥ��'
  for f in .config Module.symvers include/generated/autoconf.h include/generated/utsrelease.h; do
    [[ -s "$KDIR/$f" ]] || fail "headers ȱ�� $f"
  done
  if [[ -f /proc/config.gz ]]; then
    zcat /proc/config.gz | grep -qx 'CONFIG_MODULES=y' || fail '�ں˲�֧�ֶ�̬ģ��'
  else
    fail 'ȱ�� /proc/config.gz���޷���ȫȷ���ں�ѡ��'
  fi
  grep -qx '# CONFIG_TUN is not set' "$KDIR/.config" || \
    fail 'headers �� CONFIG_TUN ������֤������ͬ���ܾ�ǿ�Ʊ���'
  if grep -qx 'CONFIG_MODVERSIONS=y' "$KDIR/.config"; then
    fail 'headers ������ CONFIG_MODVERSIONS�������ڱ�����֤����ģ�鹹��·��'
  fi
  mkdir -p "$TUN_SRC"
  if [[ ! -s "$TUN_SRC/tun.c" ]]; then
    log '���� Linux stable v6.1.99 tun.c���̶������ύ��'
    curl -fL --retry 3 --proto '=https' --tlsv1.2 \
      "$TUN_URL" -o "$TUN_SRC/tun.c.tmp"
    mv "$TUN_SRC/tun.c.tmp" "$TUN_SRC/tun.c"
  fi
  grep -q 'Universal TUN/TAP device driver' "$TUN_SRC/tun.c" || fail 'tun.c �ļ��쳣'
  cat > "$TUN_SRC/Makefile" <<'EOF'
obj-m += tun.o
ccflags-y += -DCONFIG_TUN_MODULE
EOF
  log '���� tun.ko'
  make -C "$KDIR" M="$TUN_SRC" clean
  make -C "$KDIR" M="$TUN_SRC" modules
  [[ "$(modinfo -F vermagic "$TUN_SRC/tun.ko" | awk '{print $1}')" == "$(uname -r)" ]] || \
    fail 'tun.ko vermagic �������ں˲�ƥ��'
  local mod_dir="/lib/modules/$(uname -r)/extra"
  install -d -m 755 "$mod_dir"
  install -m 644 "$TUN_SRC/tun.ko" "$mod_dir/tun.ko"
  depmod -a || warn 'depmod ���־��棬������֤����'
  if ! modprobe tun; then
    fail 'modprobe tun ʧ�ܣ���鿴 dmesg�����ᴴ�� Supervisor ����'
  fi
  ensure_tun_device_node
  tap_probe || fail 'TUN ���غ� TAP ��������ʧ��'
  log 'TUN/TAP ���롢���غ� TAP ʵ��ɹ�'
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
    [[ -f "$key_file" && ! -L "$key_file" ]] || fail '��Կ�ļ������ڻ��Ƿ�������'
    [[ "$(stat -c '%u' "$key_file")" == 0 ]] || fail '��Կ�ļ������ root ����'
    local perms
    perms="$(stat -c '%a' "$key_file")"
    (( (8#$perms & 077) == 0 )) || fail '��Կ�ļ������ֹ��/�����û����ʣ����� chmod 600��'
    secret="$(cat "$key_file")"
  elif secret="$(extract_key_from_old_file "$EDGE_CONF")"; then
    log '�������� /etc/n2n/edge.conf �е���Կ'
  elif secret="$(extract_key_from_old_file "$SUP_CONF")"; then
    log '��⵽�� Supervisor �����е���Կ��Ǩ�Ƶ� root-only ����'
  else
    [[ -r /dev/tty ]] || fail 'û�пɽ����ն�������Կ����Ԥ�� root-only ��Կ�ļ���ʹ�� --key-file'
    printf '�״ΰ�װ������ n2n ������Կ�����벻��ʾ����' > /dev/tty
    IFS= read -r -s secret < /dev/tty || fail '��ȡ������Կʧ��'
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
  supervisorctl reread
  supervisorctl update
  # Restart is needed after an in-place edit of edge.conf (Supervisor command unchanged).
  if supervisorctl status n2n-edge 2>/dev/null | grep -q RUNNING; then
    supervisorctl restart n2n-edge
  else
    supervisorctl start n2n-edge
  fi
  local i out
  for i in {1..12}; do
    out="$(supervisorctl status n2n-edge 2>&1 || true)"
    if grep -q 'RUNNING' <<<"$out"; then log "Supervisor: $out"; return 0; fi
    sleep 1
  done
  warn "����δ���� RUNNING��${out:-unknown}"
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
    warn '������֤ʧ�ܣ����ڻع�ԭ����'
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
    fail "edge ��������ʧ�ܣ��������Ѿ����ָܻ�������Ŀ¼��${backup_dir}���鿴 /var/log/n2n-edge.log"
  fi
  log "�����ñ�ţ�$id��Identity��${ID_PREFIX}${id}���������ƣ�${ID_PREFIX}${id}_${id}"
  log 'Supernode ע����˵�����ͨ����Ҫ������֤��RUNNING �����������ɹ�'
  log "�����ñ��ݣ�$backup_dir"
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
  echo '(���������� n2n ��Կ)'
}
install_self() {
  local script_path
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  [[ -f "$script_path" ]] || { warn '��ǰʹ�ñ�׼�����������޷����汾��ά���ű�'; return; }
  [[ "$script_path" == "$SELF_INSTALL" ]] && return
  install -m 755 "$script_path" "$SELF_INSTALL"
}
main() {
  local mode='install' id='' key_file=''
  case "${1:-}" in
    -h|--help|'') usage; [[ -n "${1:-}" ]] && exit 0 || exit 2 ;;
    --status) [[ $# -eq 1 ]] || fail '�������'; show_status; exit 0 ;;
    --set-id) mode='set-id'; [[ $# -eq 2 ]] || fail '�÷���--set-id 083'; id="$2" ;;
    *) id="$1"; shift
       if [[ $# -gt 0 ]]; then
          [[ $# -eq 2 && "$1" == '--key-file' ]] || fail '��֧�ֿ�ѡ�� --key-file /root/path'
          key_file="$2"
       fi ;;
  esac
  validate_id "$id"
  require_root
  acquire_lock
  ensure_log
  log "rk3576-n2n-setup $VERSION������=$mode�����=$id"
  if [[ "$mode" == 'set-id' ]]; then
    [[ -f "$EDGE_CONF" ]] || fail '��δ��ɽű����������У�sudo bash �ű�.sh 082'
    grep -q '^# managed-by: rk3576-n2n-setup' "$EDGE_CONF" || fail '���� edge.conf ���Ǳ��ű����ɵģ�������ģ���������������װǨ��'
    local secret
    secret="$(extract_key_from_old_file "$EDGE_CONF")" || fail '��������δ�ҵ���Կ'
    validate_key "$secret"
    apply_config "$id" "$secret"
    unset secret
    install_self
    log '����޸���ɣ�û�����±��� n2n / tun���Ѹ��±���ά���ű�'
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
  log "������ɡ��´θı�ţ�sudo $SELF_INSTALL --set-id 083"
  log "״̬�鿴��sudo $SELF_INSTALL --status"
}
main "$@"
