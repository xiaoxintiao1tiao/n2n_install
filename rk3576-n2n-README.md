# EAI-BOX1500 / RK3576：n2n 3.1.1 一键安装说明

## 固定参数

- SoC/OS：Rockchip RK3576、Debian 12、Linux 6.1.99、aarch64
- n2n：3.1.1
- `-c`：`1712350000` + 三位编号 + `_` + 三位编号，例如 `083` → `1712350000083_083`
- `-I`：`1712350000` + 三位编号，例如 `083` → `1712350000083`
- `-A5`：固定
- `-l`：固定 `43.137.14.161:7799`
- `-k`：本地保管；**公开脚本不包含真实密钥**

n2n 3.1.1 社区名称最多 19 个有效字符，`1712350000082_082` 为 17 个字符，符合限制。

## 编号映射规则（请特别注意）

| 输入编号 | 社区名 `-c` | 设备描述 `-I` |
|---|---|---|
| `082` | `1712350000082_082` | `1712350000082` |
| `083` | `1712350000083_083` | `1712350000083` |
| `999` | `1712350000999_999` | `1712350000999` |

对应 n2n 参数为 `-f -k <本地密钥> -c 1712350000083_083 -I 1712350000083 -A5 -l 43.137.14.161:7799`。出于安全原因，Supervisor 的 `command` 指向 `/etc/n2n/edge.conf`，实际传给 n2n 的配置参数与该示例等效，密钥不会直接出现于 Supervisor 文件中。

## 首次安装

把 `rk3576-n2n-setup.sh` 上传到你控制的公开 HTTPS 地址（如 GitHub Public Repo），以 GitHub Raw 为例，将下面 `YOUR_ACCOUNT/YOUR_REPO` 替换为实际仓库名称：

```bash
f=$(mktemp) && curl -fL --retry 3 \
  'https://raw.githubusercontent.com/YOUR_ACCOUNT/YOUR_REPO/main/rk3576-n2n-setup.sh' \
  -o "$f" && sudo bash "$f" 082; r=$?; rm -f "$f"; (exit "$r")
```

此命令一次下载安装脚本并执行（它**不会直接把密钥放在公网**）。首次没有本地密钥时，脚本要求终端输入一次密钥，输入不会回显；如果之前 `/etc/supervisor/conf.d/n2n-edge.conf` 存在 `-k ...`，脚本会在本机导入该密钥，并迁移至仅 root 可读的 `/etc/n2n/edge.conf`。之后只需编号。

如需非交互安装，预先由安全渠道提供 root 私有密钥文件：

```bash
sudo chmod 600 /root/n2n.key
sudo bash rk3576-n2n-setup.sh 082 --key-file /root/n2n.key
```

不要把 `n2n.key` 或已填写密钥的配置文件上传到公开 Git 仓库。

## 编号输错：不重装直接修正

例：把 `082` 改为 `083`：

```bash
sudo /usr/local/sbin/rk3576-n2n-setup --set-id 083
```

同时修改 `/etc/n2n/edge.conf` 中的 `-c` 和 `-I`，保留密钥、`-A5` 与 Supernode，重启由 Supervisor 托管的 edge；不重新下载、编译 n2n 或 `tun.ko`。变更前自动备份，edge 进程启动失败时尝试回滚。**参数必须是三位数字**，例如 `82` 会拒绝，避免误丢前导零。

也可以重复执行：`sudo /usr/local/sbin/rk3576-n2n-setup 083`，但这会顺带执行版本和 TUN 检查。

## 查看状态

```bash
sudo /usr/local/sbin/rk3576-n2n-setup --status
sudo supervisorctl status n2n-edge
ip -br addr
sudo tail -n 40 /var/log/n2n-edge.log
```

`RUNNING` 仅表示 edge 进程存活，不代表注册 Supernode 或对端互通成功。请同时验证注册日志和实际 Overlay 网络通信。

## 安全与兼容性

1. 脚本在首次安装时需要 root 权限；只接受 **RK3576 / Debian 12 / aarch64 / kernel 6.1.99**，避免把针对 6.1.99 的外部内核模块装在其他内核上。
2. 首先检测 TUN/TAP；已有可持久加载的 TUN 则不编译。缺失时依赖 `/usr/src/linux-headers-6.1-rockchip`，下载 Linux stable 6.1.99 的 `tun.c`，使用 `-DCONFIG_TUN_MODULE` 构建并测试 TAP。
3. 新配置保存在 `/etc/n2n/edge.conf`，权限 `0600`。Supervisor 的 command 行只引用配置文件，不出现密钥；已有旧式配置在首次迁移后将被替换，备份保存在 `/etc/n2n/.rk3576-backup.*`。
4. 安装脚本会复制到 `/usr/local/sbin/rk3576-n2n-setup`，可直接维护编号。
5. 失败时查看 `/var/log/rk3576-n2n-setup.log`，不包含脚本主动打印的密钥。请不要开启 `bash -x` 调试该脚本。
6. 如果已经将真实 n2n 密钥发布到公共位置，应更换密钥并同步更新其他节点。
7. 内核升级或固件刷新后，必须重新确认 `tun.ko` 的兼容性；不可以跨内核版本复用。

## 本地验证说明

已完成 Bash 语法检查、三位编号拒绝测试、`082→083→999` 的模拟配置更新与密钥保留测试；由于当前环境并非这台实体 RK3576，**无法在这里实测 apt、内核模块加载、Supervisor 和实际组网**。这些步骤需要首次部署后在实体设备上验收。

## 如果之前安装过旧版脚本

之前发布的脚本将 `-I` 错误固定为 `1712350000082`。**仅运行旧版 `--set-id 083` 无法修复该错误**。先从你的公网 HTTPS 地址重新下载更新后的脚本：

```bash
f=$(mktemp) && curl -fsSL 'https://raw.githubusercontent.com/YOUR_ACCOUNT/YOUR_REPO/main/rk3576-n2n-setup.sh' -o "$f" && sudo bash "$f" --set-id 083; rc=$?; rm -f "$f"; (exit "$rc")
```

新版 `--set-id` 修改配置成功后，也会更新 `/usr/local/sbin/rk3576-n2n-setup`，以后可以直接本机执行 `--set-id`。
