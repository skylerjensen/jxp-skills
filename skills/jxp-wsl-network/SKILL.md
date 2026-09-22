---
name: jxp-wsl-network
description: WSL 内网络/代理/镜像配置与排错：autoProxy 全局代理陷阱、国内外源分流、pip/npm/git/HF 下载加速、常见错误码处置。当在 WSL 中遇到下载慢、pip 卡死、SSL 失败、403、超时，或需要配置国内镜像时使用。
---

# jxp-wsl-network

> JXP 个人 WSL 网络与镜像配置 Skill。
> 定位：**避免重复试错**。WSL 的网络配置有两个反直觉陷阱，每次换机器/重装都会踩，一律按本文件执行。
> 来源：2026-09-22/23 搭建 ASR 环境时的实测（见 `jxp-video-to-text` skill 的环境文档）。

## 何时使用

- WSL 内 `pip` / `npm` / `git clone` / `huggingface` 下载慢或卡死
- 出现 `SSL_ERROR_SYSCALL`、`WININET_E_CANNOT_CONNECT`、`403`、`Read timed out`
- 需要给某个工具配国内镜像，但不确定该不该走代理
- 新装 WSL 或换网络环境后，需要一次性配好

## 核心结论（先看这个）

```text
Windows 侧开了代理（Clash/V2Ray 等）时：
  .wslconfig 的 autoProxy=true  →  会向 WSL 注入全局 http_proxy/https_proxy

因此必须分流：
  国内镜像（阿里云/清华/ModelScope） → 直连（no_proxy 排除）
  国外源（pypi.org/pytorch/HuggingFace/GitHub） → 走代理

⚠️ 最大的坑：国内镜像被 autoProxy 强制走代理后，反而会卡死
   （实测 pip 卡 21 分钟无进展，CPU 时间仅 10 秒）
```

**另一条前提**：`.wslconfig` 设 `networkingMode=mirrored` 时，WSL 与 Windows **共享网络**，所以 **Windows 侧代理 `127.0.0.1:7897` 在 WSL 内可直接使用**，无需额外配置。

## 第一步：探测环境

```bash
# 1) 当前是否被注入代理
env | grep -i proxy
# 典型输出：http_proxy=http://127.0.0.1:7897 （来自 autoProxy）

# 2) Windows 侧代理端口（注册表）
/mnt/c/Windows/System32/reg.exe query \
  "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer

# 3) 代理是否真的可用（关键：必须测一个国外站点）
for p in 7897 7890 10809 1080; do
  curl -s -o /dev/null --max-time 5 -x "http://127.0.0.1:$p" https://www.google.com \
    && echo "可用: $p"
done
```

## 第二步：按目标选通道（实测速度，2026-09 本机）

| 目标 | 直连 | 经代理 | **采用** |
| --- | --- | --- | --- |
| `mirrors.aliyun.com`（PyPI） | **11 MB/s** | 卡死 | 直连 |
| `pypi.tuna.tsinghua.edu.cn` | **10.2 MB/s** | 卡死 | 直连 |
| `modelscope.cn`（模型） | **11.4 MB/s** | — | 直连 |
| `download.pytorch.org` | **SSL 失败** | **10.5 MB/s** | **代理** |
| `pypi.org` / `files.pythonhosted.org` | 卡死 | 快 | **代理** |
| `huggingface.co` | 不可用 | 234 KB/s（慢） | 代理（备选） |
| `hf-mirror.com` | 227 KB/s（慢） | — | 仅小文件 |
| `github.com`（release 大文件） | 慢/失败 | 偶发 SSL 中断 | **加速镜像** |
| `ghfast.top` / `gh-proxy.com` | **2.4 MB/s** | — | 直连 |

> **要点**：模型类大文件**优先找 ModelScope 的国内托管副本**，比 HF 通道快 45 倍。

## 第三步：各工具配置模板

### pip（最常用）

```bash
# 国内镜像直连（日常）
export PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
export PIP_TRUSTED_HOST=mirrors.aliyun.com
export no_proxy="mirrors.aliyun.com,pypi.tuna.tsinghua.edu.cn,localhost,127.0.0.1,::1"
export NO_PROXY="$no_proxy"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

# 国外源 / 大包重定向回 files.pythonhosted.org 时（必须走代理）
pip install --proxy http://127.0.0.1:7897 -i https://pypi.org/simple/ <pkg>
```

> ⚠️ **实践发现**：某些大包（如 `nvidia-cublas-cu12`）即使 `-i` 指向国内镜像，
> pip 仍会从索引重定向回 `files.pythonhosted.org`。此时**必须** `--proxy`；反之若给国内
> 镜像加了代理又会卡死。**判据：看 `ss -tnp | grep pip` 连的是哪个 IP**。

### pytorch（CPU/GPU 轮子）

```bash
# 必须走代理；直连会 SSL_ERROR_SYSCALL（download-r2.pytorch.org 不可达）
http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 \
  pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu
```

### HuggingFace

```bash
# 首选：先看 ModelScope 有没有同一模型的国内副本（快 45 倍）
# 次选：hf-mirror（直连，慢但可用）
export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_DISABLE_XET=1        # 关键：新版 HF 走 Xet 协议会绕过镜像
export no_proxy="hf-mirror.com,localhost,127.0.0.1"
```

> **重要**：`faster-whisper` 等库按模型名下载时会走 HF 通道。若已有 ModelScope 下载的
> 权重，**直接传本地目录路径**即可，避免二次下载。

### GitHub release 大文件

```bash
# 加速镜像（实测 ghfast.top / gh-proxy.com 约 2.4 MB/s）
curl -L -o out.bin "https://ghfast.top/https://github.com/<owner>/<repo>/releases/download/<tag>/<file>"
```

### git

```bash
# SSH 走 22 端口，通常不受 http 代理影响；克隆慢时改用镜像或代理
git config --global http.proxy http://127.0.0.1:7897   # 需要时
git config --global --unset http.proxy                 # 用完取消
```

## 排错对照表

| 现象 | 根因 | 处置 |
| --- | --- | --- |
| pip 长时间无输出、CPU 时间极低 | 国内镜像被 autoProxy 强制走代理 | 把镜像域名加入 `no_proxy` |
| `SSL_ERROR_SYSCALL in connection to ...` | 目标站直连被重置 | 改用代理或加速镜像 |
| `Read timed out` / 卡在 `Downloading` | 大包重定向回官方源但没走代理 | 加 `--proxy` |
| 下载 20 秒零增长 | 连接假死 | 查 `ss -tnp` 看真实对端 IP |
| `wsl --update` 返回 `0x80190193` | Windows Update 通道被代理拦（403） | 见下节 |
| `WININET_E_CANNOT_CONNECT` | `wsl.exe` 走 WinHTTP，不继承 WinINET 代理 | 手动侧载 MSI |
| HF 下载极慢但连接正常 | Xet 协议绕过 `HF_ENDPOINT` | `export HF_HUB_DISABLE_XET=1` |
| `sudo` 报 `no new privileges` | 会话受限，无法装系统包 | 用 pip/用户态替代（如 PyAV 代替 ffmpeg） |

## WSL 自身更新的特殊处理

`wsl --update` 两条通道都可能失败：

| 命令 | 失败表现 | 原因 |
| --- | --- | --- |
| `wsl --update` | `0x80190193`（HTTP 403） | 走 Windows Update，被代理拦 |
| `wsl --update --web-download` | `WININET_E_CANNOT_CONNECT` | `wsl.exe` 走 WinHTTP，未继承 `ProxyServer` 注册表设置 |

**可靠做法：手动侧载**

```bash
# ① 查最新版与资产名
curl -s -x http://127.0.0.1:7897 \
  "https://github.com/microsoft/WSL/releases/expanded_assets/<VERSION>" | grep -oP 'href="[^"]*\.(msi|msixbundle)"'

# ② 经加速镜像下载到 Windows 侧
curl -L -o "/mnt/c/Users/<user>/Downloads/wsl.<ver>.x64.msi" \
  "https://ghfast.top/https://github.com/microsoft/WSL/releases/download/<ver>/wsl.<ver>.x64.msi"
```

```powershell
# ③ Windows 侧安装（会弹 UAC），然后重启 WSL
msiexec /i "$env:USERPROFILE\Downloads\wsl.<ver>.x64.msi" /qb
wsl --shutdown
```

> 注意：`/mnt/c/Users/*/Downloads` 通配会先匹配到 `Default User`（模板目录，不可写），
> 必须显式指定真实用户名目录。

## 诊断脚本

配套脚本：`scripts/net_probe.sh` —— 一次性输出代理状态、各通道连通性与实测速度。

```bash
bash scripts/net_probe.sh
```

## 已知环境基线（本机）

| 项 | 值 |
| --- | --- |
| WSL | 2.7.8.0 / 内核 6.18.33.1-1 / Ubuntu 24.04 |
| `.wslconfig` | `networkingMode=mirrored`、`autoProxy=true`、`memory=12GB`、`processors=16` |
| Windows 代理 | `127.0.0.1:7897`（WinINET 已配，WinHTTP 未配） |
| 宿主内存 | 15.9 GB ⚠️ 故 `memory` 不宜超过 10–12GB |

## 注意

- 本文件是**环境适配**经验，换机器/换代理软件后端口与速度需重新探测（跑 `net_probe.sh`）。
- 不要把代理地址硬编码进项目配置文件，用环境变量或脚本探测。
