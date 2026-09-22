#!/usr/bin/env bash
# jxp-wsl-network : WSL 网络/代理/镜像一次性探测
#
# 用途：换机器、换代理软件、或下载异常时先跑这个，再决定走哪条通道。
# 用法：bash net_probe.sh [--quick]
set -uo pipefail

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

c_hdr() { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
c_ok()  { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
c_bad() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; }
c_inf() { printf '  %s\n' "$*"; }

# ── 1. 代理环境 ───────────────────────────────────────────
c_hdr "1. WSL 内代理环境变量"
found=0
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
  val="${!v:-}"
  if [ -n "$val" ]; then c_inf "$v=$val"; found=1; fi
done
[ "$found" = 0 ] && c_inf "(未设置任何 proxy 变量)"
[ "$found" = 1 ] && c_inf "→ 提示：若值为 127.0.0.1:<port>，多半来自 .wslconfig 的 autoProxy=true"

# ── 2. Windows 侧代理端口 ─────────────────────────────────
c_hdr "2. Windows 侧代理配置"
REG=/mnt/c/Windows/System32/reg.exe
if [ -x "$REG" ]; then
  en=$($REG query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' | tail -1)
  sv=$($REG query "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyServer 2>/dev/null | grep -oP '127\.0\.0\.1:\d+' | head -1)
  c_inf "ProxyEnable=$en  ProxyServer=${sv:-（无）}"
  [ "$en" = "0x1" ] && [ -n "$sv" ] && WINPROXY="http://$sv"
else
  c_bad "找不到 reg.exe，跳过"
fi

# ── 3. 候选代理可用性（以能否访问 Google 为准）───────────
c_hdr "3. 候选代理可用性"
PORTS=()
[ -n "${WINPROXY:-}" ] && PORTS+=("$WINPROXY")
for p in 7897 7890 10809 1080 2080; do
  u="http://127.0.0.1:$p"
  case " ${PORTS[*]:-} " in *"$u"*) continue;; esac
  PORTS+=("$u")
done

GOOD_PROXY=""
for u in "${PORTS[@]}"; do
  if curl -s -o /dev/null --max-time 5 -x "$u" https://www.google.com 2>/dev/null; then
    c_ok "可用: $u"
    [ -z "$GOOD_PROXY" ] && GOOD_PROXY="$u"
  else
    c_bad "不可用: $u"
  fi
done
[ -n "$GOOD_PROXY" ] && c_inf "→ 选定代理: $GOOD_PROXY"

# ── 4. 通道测速 ───────────────────────────────────────────
c_hdr "4. 关键通道连通性与速度"
probe() {  # probe <名称> <URL> <是否走代理>
  local name="$1" url="$2" via="$3" t=20
  local opt=()
  if [ "$via" = "proxy" ]; then
    [ -z "$GOOD_PROXY" ] && { c_inf "$name: 无可用代理，跳过"; return; }
    opt=(-x "$GOOD_PROXY")
  else
    opt=(--noproxy '*')
  fi
  local out rc
  out=$(timeout $((t+10)) curl -sL "${opt[@]}" --max-time "$t" -o /dev/null \
        -w '%{http_code} %{speed_download}' "$url" 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then
    local code spd; code=$(echo "$out" | awk '{print $1}'); spd=$(echo "$out" | awk '{print $2}')
    local human; human=$(awk -v s="$spd" 'BEGIN{ if(s>1048576) printf "%.1f MB/s", s/1048576; else printf "%.0f KB/s", s/1024 }')
    if [ "$code" = "200" ] || [ "$code" = "206" ] || [ "$code" = "302" ]; then
      c_ok "$name: HTTP $code, $human"
    else
      c_bad "$name: HTTP $code, $human"
    fi
  else
    c_bad "$name: 连接失败/超时 (rc=$rc)"
  fi
}

probe "阿里云 PyPI     (直连) " "https://mirrors.aliyun.com/pypi/simple/pip/"          direct
probe "清华 PyPI       (直连) " "https://pypi.tuna.tsinghua.edu.cn/simple/pip/"          direct
probe "ModelScope      (直连) " "https://www.modelscope.cn/api/v1/models/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-pytorch" direct
if [ "$QUICK" = 0 ]; then
  probe "pytorch 官方    (代理) " "https://download.pytorch.org/whl/cpu/"                  proxy
  probe "PyPI 官方       (代理) " "https://pypi.org/simple/pip/"                           proxy
  probe "HuggingFace     (代理) " "https://huggingface.co/Systran/faster-whisper-large-v3/resolve/main/config.json" proxy
  probe "hf-mirror       (直连) " "https://hf-mirror.com/Systran/faster-whisper-large-v3/resolve/main/config.json" direct
  probe "ghfast.top      (直连) " "https://ghfast.top/https://github.com/microsoft/WSL/releases" direct
fi

# ── 5. 建议配置 ───────────────────────────────────────────
c_hdr "5. 建议：写入 ~/.bashrc 的分流配置"
cat <<EOF
# ---- jxp-wsl-network 建议配置 ----
export JP_PROXY="${GOOD_PROXY:-http://127.0.0.1:7897}"

# 国内镜像：直连（务必排除代理，否则会卡死）
export PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
export PIP_TRUSTED_HOST=mirrors.aliyun.com
export no_proxy="mirrors.aliyun.com,pypi.tuna.tsinghua.edu.cn,modelscope.cn,hf-mirror.com,localhost,127.0.0.1,::1"
export NO_PROXY="\$no_proxy"

# 国外源需要代理时，用 --proxy 显式指定，例如：
#   pip install --proxy \$JP_PROXY -i https://pypi.org/simple/ <pkg>
#   http_proxy=\$JP_PROXY https_proxy=\$JP_PROXY pip install torch --index-url https://download.pytorch.org/whl/cpu

export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_DISABLE_XET=1
# ---- end ----
EOF

c_hdr "探测完成"
[ -n "$GOOD_PROXY" ] && c_inf "代理可用：$GOOD_PROXY" || c_inf "未发现可用代理；国外源将不可达，优先改用国内镜像"
