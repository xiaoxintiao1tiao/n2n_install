#!/usr/bin/env bash
# Set eth0 IPv4 static address on Ubuntu systems managed by ifupdown.
# Usage:
#   sudo ./set_eth0_network.sh 172.31.60.54 255.255.255.0 172.31.60.12
#   sudo ./set_eth0_network.sh                   # interactive; Enter keeps existing value
# This script only updates configuration on disk. It does NOT restart the network.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "错误：请使用 sudo 运行，例如 sudo $0 172.31.60.54 255.255.255.0 172.31.60.12" >&2
  exit 1
fi
if [[ $# -ne 0 && $# -ne 3 ]]; then
  echo "用法：sudo $0 [IP 子网掩码 网关]" >&2
  echo "示例：sudo $0 172.31.60.54 255.255.255.0 172.31.60.12" >&2
  echo "      sudo $0                  # 交互修改，回车保留当前值" >&2
  exit 2
fi

python3 - "$@" <<'PY'
import glob
import ipaddress
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from datetime import datetime

ROOT = Path('/etc/network')
MAIN = ROOT / 'interfaces'
BACKUP_DIR = Path('/var/backups/eth0-ifupdown')
DNS = '223.5.5.5 114.114.114.114'

# 只检查 ifupdown 实际通过 source/source-directory 引入的文件。
# 备份独立放在 /var/backups，避免下次运行被 source 通配符再次加载。
visited = set()
found = []

def visit(file):
    file = Path(file).resolve()
    if file in visited or not file.is_file():
        return
    visited.add(file)
    lines = file.read_text(encoding='utf-8').splitlines(keepends=True)
    for index, line in enumerate(lines):
        active = line.split('#', 1)[0].strip()
        if not active:
            continue
        if re.match(r'^iface\s+eth0\s+inet\s+\S+', active):
            found.append((file, lines, index))
            continue
        items = active.split()
        if items[0] == 'source':
            for expression in items[1:]:
                pattern = expression if os.path.isabs(expression) else str(ROOT / expression)
                for subfile in sorted(glob.glob(pattern)):
                    visit(subfile)
        elif items[0] == 'source-directory':
            for dirname in items[1:]:
                base = Path(dirname) if os.path.isabs(dirname) else ROOT / dirname
                if base.is_dir():
                    for subfile in sorted(base.iterdir()):
                        # ifupdown 的 source-directory 只包含字母、数字、_、- 文件名
                        if re.fullmatch(r'[A-Za-z0-9_-]+', subfile.name):
                            visit(subfile)

if not MAIN.is_file():
    sys.exit('错误：未找到 /etc/network/interfaces；请确认设备使用 ifupdown。')
visit(MAIN)
if len(found) != 1:
    sys.exit(f'错误：在有效 ifupdown 配置中找到 {len(found)} 处 eth0 IPv4 配置，未修改。请检查 /etc/network/interfaces 及其 source 文件。')

path, lines, start = found[0]
end = start + 1
# ifupdown 的配置项通常缩进，但也兼容不缩进的 address/gateway。
# 碰到下一个顶层声明时才结束当前 iface 段。
next_stanza = re.compile(r'^\s*(?:iface|auto|allow-[A-Za-z0-9_-]+|mapping|source|source-directory)\s+')
while end < len(lines) and not next_stanza.match(lines[end]):
    end += 1
block = lines[start:end]

# 读取当前设置，供交互输入默认值使用。
def old_value(key):
    for line in block[1:]:
        m = re.match(r'^\s*' + re.escape(key) + r'\s+(\S+)', line)
        if m:
            return m.group(1)
    return ''

old_ip = old_value('address')
old_mask = old_value('netmask')
old_gateway = old_value('gateway')
if '/' in old_ip and not old_mask:
    old_ip, old_mask = old_ip.split('/', 1)


def parse_ip(text):
    ip = ipaddress.IPv4Address(text)
    if ip.is_multicast or ip.is_unspecified or ip.is_loopback:
        raise ValueError('IP 不能是组播、未指定或回环地址')
    return ip


def parse_mask(text):
    value = text.strip().lstrip('/')
    network = ipaddress.IPv4Network('0.0.0.0/' + value)
    if not 1 <= network.prefixlen <= 30:
        raise ValueError('子网掩码须对应 /1 至 /30')
    return network.netmask


def validate(ip_text, mask_text, gw_text):
    ip = parse_ip(ip_text)
    mask = parse_mask(mask_text)
    network = ipaddress.IPv4Network(f'{ip}/{mask}', strict=False)
    if ip in (network.network_address, network.broadcast_address):
        raise ValueError('IP 不能是所在子网的网络地址或广播地址')
    gw = parse_ip(gw_text)
    if gw not in network:
        raise ValueError(f'网关 {gw} 不在 {network} 子网中')
    if gw in (network.network_address, network.broadcast_address):
        raise ValueError('网关不能是网络地址或广播地址')
    if gw == ip:
        raise ValueError('网关不能与 eth0 IP 相同')
    return str(ip), str(mask), str(gw), network.prefixlen


def ask(prompt, default):
    label = f'{prompt} [{default}]' if default else prompt
    with open('/dev/tty', 'r+', encoding='utf-8') as tty:
        tty.write(f'{label}: ')
        tty.flush()
        answer = tty.readline()
        if not answer:
            raise SystemExit('交互输入已终止，未修改配置。')
        return answer.strip() or default

if len(sys.argv) == 4:
    # 命令行模式：参数有错就拒绝修改，修正后重复执行即可。
    try:
        ip, mask, gateway, prefix = validate(*sys.argv[1:])
    except (ValueError, ipaddress.AddressValueError, ipaddress.NetmaskValueError) as exc:
        sys.exit(f'参数错误：{exc}\n未修改配置；请修正后重新执行。')
else:
    print('交互修改 eth0 网络设置（直接回车保留当前值）')
    while True:
        ip_input = ask('IPv4 地址', old_ip)
        mask_input = ask('子网掩码（如 255.255.255.0 或 /24）', old_mask)
        gw_input = ask('网关', old_gateway)
        try:
            ip, mask, gateway, prefix = validate(ip_input, mask_input, gw_input)
            break
        except ValueError as exc:
            print(f'输入错误：{exc}，请重新输入。')
            old_ip, old_mask, old_gateway = ip_input, mask_input, gw_input

print(f'\n配置文件：{path}')
print(f'IP       ：{ip}')
print(f'子网掩码 ：{mask} (/{prefix})')
print(f'网关     ：{gateway}')
print(f'DNS      ：{DNS}')

# 删除旧地址/掩码/网关/DNS，以及可能导致跨子网后过时的 network/broadcast。
remove_keys = ('address', 'netmask', 'gateway', 'dns-nameservers', 'network', 'broadcast')
remove_re = re.compile(r'^\s*(?:' + '|'.join(map(re.escape, remove_keys)) + r')\s+')
remainder = [line for line in block[1:] if not remove_re.match(line)]
replacement = [
    'iface eth0 inet static\n',
    f'    address {ip}\n',
    f'    netmask {mask}\n',
    f'    gateway {gateway}\n',
    f'    dns-nameservers {DNS}\n',
] + remainder
new_content = ''.join(lines[:start] + replacement + lines[end:])
old_content = ''.join(lines)
if new_content == old_content:
    print('\n配置已经一致，无需修改。')
    sys.exit(0)

BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
# 为相同文件多次修改生成唯一备份，永不覆盖旧备份。
stamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
backup = BACKUP_DIR / f'{path.name}.{stamp}.bak'
shutil.copy2(path, backup)

# 同目录原子替换，保留 owner/mode；避免写入中断导致配置文件损坏。
fd, tempname = tempfile.mkstemp(prefix='.eth0-', dir=str(path.parent))
try:
    info = path.stat()
    os.fchown(fd, info.st_uid, info.st_gid)
    os.fchmod(fd, stat.S_IMODE(info.st_mode))
    with os.fdopen(fd, 'w', encoding='utf-8') as fout:
        fout.write(new_content)
        fout.flush()
        os.fsync(fout.fileno())
    os.replace(tempname, path)
except Exception:
    if os.path.exists(tempname):
        os.unlink(tempname)
    raise

print(f'\n写入成功，备份：{backup}')
print('只修改了配置文件，没有断开网络，也没有自动重启。')
print('配置需在维护时段重启系统或重新激活 eth0 后才会完全生效。')
PY
