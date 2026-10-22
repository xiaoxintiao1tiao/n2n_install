# NVIDIA Jetson Orin Nano：n2n 3.1.1 自动安装、开机启动与维护

版本：**Jetson 安装脚本 v1.0.0**。注意：这是安装脚本版本，**n2n 本身始终是 3.1.1**。

> 由既有 RK3576 脚本的部署方式延伸，但 **Jetson 不使用 RK3576 的 `tun.ko`、headers 或内核补丁**。本脚本已通过 Bash 语法和隔离逻辑测试；未在实体 Jetson Orin Nano 上执行完整的安装及 Supernode 连通性验收。

## 1. 适用范围

- NVIDIA Jetson Orin Nano / 识别到 `tegra234` 的 Jetson Orin 设备，ARM64 (`aarch64`)
- Ubuntu 20.04 / 22.04 / 24.04 等 Debian/Ubuntu APT 系系统（脚本有平台检查）
- 系统已有可工作的内建或可加载 TUN/TAP；若缺失则中止，不乱编外部内核模块
- 网络能够通过 `github.com` 克隆源码和安装仓库，能够通过 APT 软件源获取缺失依赖
- `systemd` 和 `supervisord` 可用，业务机允许安装依赖和管理 `n2n-edge`

**重要：** 目标设备必须拥有 Supernode 的正确共享密钥，输入后仅保存在 root 可读的 `/etc/n2n/edge.conf` 中；公共 GitHub 仓库禁止包含真实密钥。

## 2. 生成规则

固定：

- n2n 版本：3.1.1
- `-A5`
- Supernode：`43.137.14.161:7799`
- 身份前缀：`1712350000`
- `-k`：设备上本地保存的共享密钥，**不会公开放入脚本**

| 传入三位编号 | 社区 `-c` | 身份 `-I` |
|---|---|---|
| `081` | `1712350000081_081` | `1712350000081` |
| `082` | `1712350000082_082` | `1712350000082` |
| `083` | `1712350000083_083` | `1712350000083` |

脚本将真实参数保存到 `/etc/n2n/edge.conf`；Supervisor 使用 `/usr/sbin/edge /etc/n2n/edge.conf`，不会在 `command` 中明文输出密钥。

## 3. 把 Jetson 脚本放到 GitHub

建议沿用已有仓库：

https://github.com/xiaoxintiao1tiao/n2n_install

将 `jetson-orin-n2n-setup.sh` 和本 `jetson-orin-n2n-README.md` 上传到 `main` 分支；**不要覆盖**原有的 `rk3576-n2n-setup.sh`、`tun.c`。

GitHub 网页上可选择 **Add file → Upload files → Commit changes**。以后更新同名文件，再次上传覆盖并提交即可。建议版本变更时先对照提交差异。

也可通过 PowerShell：

```powershell
git clone https://github.com/xiaoxintiao1tiao/n2n_install.git
cd n2n_install
Copy-Item "C:\你的下载目录\jetson-orin-n2n-setup.sh" ".\jetson-orin-n2n-setup.sh" -Force
Copy-Item "C:\你的下载目录\jetson-orin-n2n-README.md" ".\jetson-orin-n2n-README.md" -Force
git add jetson-orin-n2n-setup.sh jetson-orin-n2n-README.md
git commit -m "Add Jetson Orin Nano n2n installer"
git push origin main
```

## 4. 新 Jetson 工控机首次安装

### 推荐：Git 克隆整个公开仓库

```bash
cd ~
git clone --depth 1 https://github.com/xiaoxintiao1tiao/n2n_install.git n2n_install
cd ~/n2n_install

grep '^VERSION=' jetson-orin-n2n-setup.sh
bash -n jetson-orin-n2n-setup.sh
sudo bash ./jetson-orin-n2n-setup.sh 083
```

脚本将：

1. 检查 `aarch64`、Tegra234、Ubuntu/Debian 的有效组合。
2. 检测已装依赖，只通过 APT 补齐缺少的包；不进行整机 `upgrade` / `full-upgrade`，不取消 `apt-mark hold`。
3. 检查是否已有 n2n 3.1.1。没有时克隆官方标签 `3.1.1`，校验固定提交后执行 `./autogen.sh`、`./configure`、`make -j4`、`make install`。
4. 检查内核自带 TUN/TAP；按需 `modprobe tun`，实际创建并删除临时 TAP 网卡，以确认工作正常；模块模式时配置自动加载。
5. 复用老配置中的 n2n 密钥，或在交互终端隐藏输入共享密钥。
6. 将配置保存为 `/etc/n2n/edge.conf`（权限 600），安装 Supervisor，自动启动 edge，并将本脚本复制到 `/usr/local/sbin/jetson-n2n-setup`。

首次输入密钥时终端没有字符显示，是正常的。只输入密钥本身，不包括 `-k`。

### 一行式（确认代码已经上传 GitHub 后使用）

```bash
d=$(mktemp -d) && git clone -q --depth 1 https://github.com/xiaoxintiao1tiao/n2n_install.git "$d" && bash -n "$d/jetson-orin-n2n-setup.sh" && sudo bash "$d/jetson-orin-n2n-setup.sh" 083
```

注意末尾三位编号。建议在生产设备上优先下载并人工查看脚本后再执行；公网脚本可能被更新，批量部署应固定经过验收的 Git 提交。

### 使用非交互密钥文件

```bash
sudo install -m 600 -o root -g root /安全路径/已有密钥文件 /root/n2n.key
sudo bash ./jetson-orin-n2n-setup.sh 083 --key-file /root/n2n.key
```

密钥文件需 root 所有，其他用户不可读。不要通过命令行参数直接传递密钥明文。

## 5. 旧 Jetson 已按手工方式安装：如何迁移

1. 先检查 `/usr/sbin/edge` 版本及当前 Supervisor 是否在管理 `n2n-edge`：

```bash
/usr/sbin/edge -h 2>&1 | head -n 8
sudo supervisorctl status n2n-edge
sudo systemctl status supervisor --no-pager
```

2. 先备份现有 Supervisor 配置（文件可能含共享密钥，严格 root 权限）：

```bash
sudo install -d -m 700 /root/n2n-backup
sudo cp -p /etc/supervisor/conf.d/n2n-edge.conf /root/n2n-backup/n2n-edge.conf.before-jetson
sudo chmod 600 /root/n2n-backup/n2n-edge.conf.before-jetson
```

3. 通过第 4 节克隆新脚本，执行 `sudo bash ./jetson-orin-n2n-setup.sh 083`。若检测到原 Supervisor 配置中的 `-k`，会迁移进 root 私有 edge.conf，通常无需再次输入。

4. 新配置可能需要短暂重启 `n2n-edge`，**请安排允许 VPN 短时中断的窗口**。如果有另外手工启动的 edge 进程，脚本会拒绝直接接管，需先辨明服务归属，**不要盲目执行 `pkill edge`**。

5. 确认组网联通后，删除不再需要的明文密钥备份。若之前已将密钥上传至公共仓库，应统一更换密钥。

## 6. 日常维护

```bash
# 修改三位编号：-c、-I 同步更新，不重编 n2n
sudo /usr/local/sbin/jetson-n2n-setup --set-id 084

# 隐藏输入两次共享密钥，仅修改 -k 并重启 edge
sudo /usr/local/sbin/jetson-n2n-setup --set-key

# 查看编号、版本、模块、Supervisor 状态（不会打印密钥）
sudo /usr/local/sbin/jetson-n2n-setup --status

# 查看 n2n 进程
sudo supervisorctl status n2n-edge
sudo tail -n 60 /var/log/n2n-edge.log
```

修改编号/密钥都会备份旧配置；如果 edge 进程无法启动，会尝试恢复原配置。**如果密钥错了但进程显示 RUNNING，脚本无法自动判断密钥错误；需要测试与实际其他 n2n 节点通信。**

## 7. 脚本代码更新与覆盖

已有仓库目录的设备：

```bash
cd ~/n2n_install
git pull --ff-only origin main
grep '^VERSION=' jetson-orin-n2n-setup.sh
bash -n jetson-orin-n2n-setup.sh
```

只覆盖本地维护脚本，不触动运行中的 n2n：

```bash
sudo install -m 755 ./jetson-orin-n2n-setup.sh /usr/local/sbin/jetson-n2n-setup
sudo /usr/local/sbin/jetson-n2n-setup --status
```

若首次安装未完成，可以重新执行 `sudo bash ./jetson-orin-n2n-setup.sh 083`；脚本会跳过已安装组件。

**重要：** `jetson-n2n-setup` 与 `rk3576-n2n-setup` 是不同命令；不要在 Jetson 上运行 RK3576 的内核模块安装流程。

## 8. 安装验收与开机启动验证

```bash
uname -m
uname -r
cat /proc/device-tree/model 2>/dev/null
ls -l /dev/net/tun
sudo /usr/local/sbin/jetson-n2n-setup --status
sudo supervisorctl status n2n-edge
ip -br addr
sudo tail -n 50 /var/log/n2n-edge.log
```

确认 TUN、edge 进程正常后，要进一步验证 Supernode 注册及对端通信，确认 VPN 正常。

在计划好的维护窗口重启设备，重新检查：

```bash
sudo reboot
# 重启回来后
sudo supervisorctl status n2n-edge
ls -l /dev/net/tun
sudo /usr/local/sbin/jetson-n2n-setup --status
```

## 9. 常见错误

| 错误 | 原因 / 处理 |
|---|---|
| `curl: (35) Recv failure` | GitHub Raw 连接重置，改用 Git clone 获取脚本。Jetson 安装脚本本身不依赖 Raw 下载内核源码。 |
| `curl/libcurl4` 依赖冲突 | 可能是厂商软件包 hold；脚本只安装缺失依赖，不执行全系统升级。 |
| `TUN/TAP 测试未通过` | 检查 `sudo modprobe tun`、`/dev/net/tun`、`dmesg`，必要时按 JetPack/BSP 恢复厂商内核模块。不要复用 RK3576 的 tun.ko。 |
| 进程 `RUNNING` 但不能互通 | 检查密钥、社区名、Supernode 端口、防火墙、其他节点。 |
| `--set-key` 输错 | 重新运行 `--set-key`；输入时不回显，两次不一致则原配置不改。 |
| `--set-id 83` 被拒绝 | 设备编号必须三位，如 `083`。 |
| 检测到手工 edge 进程 | 不使用 `pkill edge`；先辨明已有进程、端口和配置，再切换到 Supervisor。 |

## 10. 重要文件路径

| 文件 | 用途 |
|---|---|
| `/usr/sbin/edge` | n2n 程序 |
| `/usr/sbin/supernode` | 可选的 n2n Supernode 程序 |
| `/etc/n2n/edge.conf` | root-only 共享密钥及连接参数 |
| `/etc/supervisor/conf.d/n2n-edge.conf` | Supervisor 服务配置 |
| `/usr/local/sbin/jetson-n2n-setup` | 安装后的维护脚本 |
| `/var/log/jetson-n2n-setup.log` | 安装日志 |
| `/var/log/n2n-edge.log` | n2n edge 运行日志 |
| `/data/n2n-3.1.1/` | 新装机器源码目录（已有目录时会改用私有临时构建目录） |

不包含任何实际共享密钥的示例文件才适合上传 GitHub Public 仓库。
