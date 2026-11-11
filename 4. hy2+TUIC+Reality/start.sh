#!/bin/bash
set -e

# ================== 端口设置 ==================

export TUIC_PORT=${TUIC_PORT:-""}                     # 填入tuic节点端口

export HY2_PORT=${HY2_PORT:-""}                       # 填入hy2节点端口

export REALITY_PORT=${REALITY_PORT:-""}               # 填入reality节点端口（UDP/TCP可以共用1个端口）

# ==============================================


cd "$(dirname "$0")"
export FILE_PATH="${PWD}/.npm"
export DATA_PATH="${PWD}/singbox_data"
mkdir -p "$FILE_PATH" "$DATA_PATH"
export XDG_DATA_HOME="/tmp/.singbox_data"
export XDG_CACHE_HOME="/tmp/.singbox_cache"
export TMPDIR="/tmp"
rm -rf "${FILE_PATH}"/sb_* ~/.npm/_logs/* ./npm-debug.log* "${DATA_PATH}"/* /tmp/.singbox_* 2>/dev/null || true

UUID_FILE="${FILE_PATH}/uuid.txt"
if [ -f "$UUID_FILE" ]; then
  UUID=$(cat "$UUID_FILE")
  echo -e "\e[1;33m[UUID] 复用固定 UUID: $UUID\e[0m"
else
  UUID=$(cat /proc/sys/kernel/random/uuid)
  echo "$UUID" > "$UUID_FILE"
  chmod 600 "$UUID_FILE"
  echo -e "\e[1;32m[UUID] 首次生成并永久保存: $UUID\e[0m"
fi

# TUIC 密码由 UUID 派生（与 1 号变体相同：sha256(UUID+"-tuic") 取前 32 位），不再使用固定口令
TUIC_PASSWORD=$(printf '%s' "${UUID}-tuic" | sha256sum | awk '{print $1}' | cut -c1-32)

[ ! -d "${FILE_PATH}" ] && mkdir -p "${FILE_PATH}"

# Sing-box 版本解析与下载地址计算已移入下方下载分支：仅在确实需要下载时才请求 GitHub API

download_file() {
  local URL=$1
  local FILENAME=$2
  if command -v curl >/dev/null 2>&1; then
    curl -L -sS -o "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (curl)\e[0m"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$FILENAME" "$URL" && echo -e "\e[1;32m下载 $FILENAME (wget)\e[0m"
  else
    echo -e "\e[1;31m未找到 curl 或 wget\e[0m"
    exit 1
  fi
}

SINGBOX_BIN="${FILE_PATH}/sb_core"
if [ ! -f "$SINGBOX_BIN" ]; then
  # 自动通过 API 获取最新的 release 版本号（剥离 v 前缀），若 API 受限则以 1.11.4 保底
  SINGBOX_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/')
  if [ -z "$SINGBOX_VER" ]; then
    SINGBOX_VER="1.11.4"
  fi

  ARCH=$(uname -m)
  if [[ "$ARCH" == "arm"* ]] || [[ "$ARCH" == "aarch64" ]]; then
    ASSET_NAME="sing-box-${SINGBOX_VER}-linux-arm64.tar.gz"
  elif [[ "$ARCH" == "amd64"* ]] || [[ "$ARCH" == "x86_64" ]]; then
    ASSET_NAME="sing-box-${SINGBOX_VER}-linux-amd64.tar.gz"
  elif [[ "$ARCH" == "s390x" ]]; then
    ASSET_NAME="sing-box-${SINGBOX_VER}-linux-s390x.tar.gz"
  else
    echo "不支持的架构: $ARCH"
    exit 1
  fi
  DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/${ASSET_NAME}"

  echo -e "\e[1;33m[下载] 未检测到 Sing-box 核心，正在下载最新版本 v${SINGBOX_VER}...\e[0m"
  download_file "$DOWNLOAD_URL" "${FILE_PATH}/singbox.tar.gz"

  # 校验下载完整性：读取该版本发布资产的官方 SHA-256（GitHub API digest 字段），不匹配则中止；
  # 若该版本未提供 digest（如 v1.11.4），则提示后跳过校验
  EXPECTED_SHA256=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${SINGBOX_VER}" | awk -v asset="\"name\": \"${ASSET_NAME}\"" 'index($0, asset) { found=1 } found && /"digest":/ { print; exit }' | sed -E 's/.*"sha256:([0-9a-f]{64})".*/\1/')
  if [ -n "$EXPECTED_SHA256" ] && command -v sha256sum >/dev/null 2>&1; then
    ACTUAL_SHA256=$(sha256sum "${FILE_PATH}/singbox.tar.gz" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
      echo -e "\e[1;31m[校验] Sing-box 下载文件 SHA-256 与官方摘要不匹配，中止启动\e[0m"
      rm -f "${FILE_PATH}/singbox.tar.gz"
      exit 1
    fi
    echo -e "\e[1;32m[校验] Sing-box SHA-256 校验通过\e[0m"
  else
    echo -e "\e[1;33m[校验] 未能获取官方 SHA-256（该版本可能未提供），跳过校验\e[0m"
  fi
  tar -zxvf "${FILE_PATH}/singbox.tar.gz" -C "${FILE_PATH}" --strip-components=1 "sing-box-${SINGBOX_VER}-linux-"*/sing-box >/dev/null 2>&1 || \
  tar -zxvf "${FILE_PATH}/singbox.tar.gz" -C "${FILE_PATH}" --wildcards "*/sing-box" --strip-components=1 >/dev/null 2>&1
  mv "${FILE_PATH}/sing-box" "$SINGBOX_BIN" 2>/dev/null || true
  rm -f "${FILE_PATH}/singbox.tar.gz"
  chmod +x "$SINGBOX_BIN"
else
  echo -e "\e[1;32m[核心] 已存在 Sing-box 核心，跳过下载\e[0m"
fi

if [ "$REALITY_PORT" != "" ] && [ "$REALITY_PORT" != "0" ]; then
  KEY_FILE="${FILE_PATH}/key.txt"
  if [ -f "$KEY_FILE" ]; then
    echo -e "\e[1;33m[密钥] 检测到已有密钥，复用...\e[0m"
    private_key=$(grep "PrivateKey:" "$KEY_FILE" | awk '{print $2}')
    public_key=$(grep "PublicKey:" "$KEY_FILE" | awk '{print $2}')
  else
    echo -e "\e[1;33m[密钥] 首次生成 Reality 密钥对...\e[0m"
    output=$("$SINGBOX_BIN" generate reality-keypair)
    echo "$output" > "$KEY_FILE"
    private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
    public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
    chmod 600 "$KEY_FILE"
    echo -e "\e[1;32m[密钥] 密钥已保存，重启后保持不变\e[0m"
  fi
fi

if [ ! -f "${FILE_PATH}/cert.pem" ] || [ ! -f "${FILE_PATH}/private.key" ]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl ecparam -genkey -name prime256v1 -out "${FILE_PATH}/private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -subj "/CN=bing.com" 2>/dev/null
  elif "$SINGBOX_BIN" generate tls-keypair bing.com > "${FILE_PATH}/tls-keypair.tmp" 2>/dev/null && [ -s "${FILE_PATH}/tls-keypair.tmp" ]; then
    # 无 openssl 时的兜底：用 sing-box 自带命令生成密钥对，再拆分出 PEM 私钥与证书
    awk '/-----BEGIN.*PRIVATE KEY-----/{f=1} f{print} /-----END.*PRIVATE KEY-----/{f=0}' "${FILE_PATH}/tls-keypair.tmp" > "${FILE_PATH}/private.key"
    awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{f=0}' "${FILE_PATH}/tls-keypair.tmp" > "${FILE_PATH}/cert.pem"
    rm -f "${FILE_PATH}/tls-keypair.tmp"
    if [ ! -s "${FILE_PATH}/private.key" ] || [ ! -s "${FILE_PATH}/cert.pem" ]; then
      echo -e "\e[1;31m[证书] sing-box 生成的密钥对解析失败，中止启动\e[0m"
      exit 1
    fi
  else
    echo -e "\e[1;31m[证书] 未找到 openssl 且 sing-box 无法生成密钥对，无法生成证书，中止启动\e[0m"
    exit 1
  fi
  chmod 600 "${FILE_PATH}/private.key"
fi

INBOUNDS=()

if [ -n "$TUIC_PORT" ] && [ "$TUIC_PORT" != "0" ]; then
  INBOUNDS+=("{
    \"type\": \"tuic\",
    \"listen\": \"::\",
    \"listen_port\": $TUIC_PORT,
    \"users\": [{\"uuid\": \"$UUID\", \"password\": \"$TUIC_PASSWORD\"}],
    \"congestion_control\": \"bbr\",
    \"tls\": {\"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\"}
  }")
fi

if [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
  INBOUNDS+=("{
    \"type\": \"hysteria2\",
    \"listen\": \"::\",
    \"listen_port\": $HY2_PORT,
    \"users\": [{\"password\": \"$UUID\"}],
    \"masquerade\": \"https://bing.com\",
    \"tls\": {\"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\"}
  }")
fi

if [ -n "$REALITY_PORT" ] && [ "$REALITY_PORT" != "0" ]; then
  INBOUNDS+=("{
    \"type\": \"vless\",
    \"listen\": \"::\",
    \"listen_port\": $REALITY_PORT,
    \"users\": [{\"uuid\": \"$UUID\", \"flow\": \"xtls-rprx-vision\"}],
    \"tls\": {
      \"enabled\": true,
      \"server_name\": \"www.nazhumi.com\",
      \"reality\": {
        \"enabled\": true,
        \"handshake\": {\"server\": \"www.nazhumi.com\", \"server_port\": 443},
        \"private_key\": \"$private_key\",
        \"short_id\": [\"\"]
      }
    }
  }")
fi

IFS=','
cat > "${FILE_PATH}/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    ${INBOUNDS[*]}
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

SINGBOX_PID_FILE="${FILE_PATH}/singbox.pid"
RESTART_FLAG="${FILE_PATH}/.scheduled_restart"

# 保活循环：sing-box 意外退出后 3 秒自动拉起并累计崩溃次数；定时重启通过标记文件区分，不计崩溃
supervise_singbox() {
  local crash_count=0
  while true; do
    "$SINGBOX_BIN" run -c "${FILE_PATH}/config.json" >/dev/null 2>&1 &
    SINGBOX_PID=$!
    echo "$SINGBOX_PID" > "$SINGBOX_PID_FILE"
    echo "[SING-BOX] 启动完成 PID=$SINGBOX_PID"
    wait "$SINGBOX_PID" 2>/dev/null || true
    if [ -f "$RESTART_FLAG" ]; then
      rm -f "$RESTART_FLAG"
      echo "[SING-BOX] 定时重启触发，重新拉起..."
    else
      crash_count=$((crash_count + 1))
      echo "[SING-BOX] 进程意外退出（累计崩溃 ${crash_count} 次），3 秒后自动拉起..."
    fi
    sleep 3
  done
}

supervise_singbox &

IP=$(curl -s --max-time 2 ipv4.ip.sb || curl -s --max-time 1 api.ipify.org || echo "IP_ERROR")
ISP=$(curl -s --max-time 2 https://speed.cloudflare.com/meta | awk -F'"' '{print $26"-"$18}' || echo "0.0")

# ================== 生成订阅 ==================
> "${FILE_PATH}/list.txt"
[ "$TUIC_PORT" != "" ] && [ "$TUIC_PORT" != "0" ] && echo "tuic://${UUID}:${TUIC_PASSWORD}@${IP}:${TUIC_PORT}?sni=www.bing.com&alpn=h3&congestion_control=bbr&allowInsecure=1#tuic_easyshare" >> "${FILE_PATH}/list.txt"
[ "$HY2_PORT" != "" ] && [ "$HY2_PORT" != "0" ] && echo "hysteria2://${UUID}@${IP}:${HY2_PORT}/?sni=www.bing.com&insecure=1#hy2_easyshare" >> "${FILE_PATH}/list.txt"
[ "$REALITY_PORT" != "" ] && [ "$REALITY_PORT" != "0" ] && echo "vless://${UUID}@${IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.nazhumi.com&fp=firefox&pbk=${public_key}&type=tcp#reality_easyshare" >> "${FILE_PATH}/list.txt"

base64 "${FILE_PATH}/list.txt" | tr -d '\n' > "${FILE_PATH}/sub.txt"
cat "${FILE_PATH}/list.txt"
echo -e "\n\e[1;32m${FILE_PATH}/sub.txt 已保存\e[0m"

schedule_restart() {
  echo "[定时重启:Sing-box] 已启动（北京时间 00:03）"
  LAST_RESTART_DAY=-1

  while true; do
    now_ts=$(date +%s)
    beijing_ts=$((now_ts + 28800))
    H=$(( (beijing_ts / 3600) % 24 ))
    M=$(( (beijing_ts / 60) % 60 ))
    D=$(( beijing_ts / 86400 ))

    if [ "$H" -eq 0 ] && [ "$M" -eq 3 ] && [ "$D" -ne "$LAST_RESTART_DAY" ]; then
      echo "[定时重启:Sing-box] 到达 00:03 → 重启 sing-box"
      LAST_RESTART_DAY=$D

      # 先写定时重启标记再结束进程，保活循环会在 3 秒后自动拉起（不计崩溃次数）
      touch "$RESTART_FLAG"
      SB_PID=$(cat "$SINGBOX_PID_FILE" 2>/dev/null || true)
      if [ -n "$SB_PID" ]; then
        kill "$SB_PID" 2>/dev/null || true
      fi

      rm -rf ~/.npm/_logs/* ./npm-debug.log* "${DATA_PATH}"/* /tmp/.singbox_* 2>/dev/null || true

      echo "[定时重启:Sing-box] 已触发，等待保活循环拉起新进程"
    fi

    sleep 30
  done
}

schedule_restart
