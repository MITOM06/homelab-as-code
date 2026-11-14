#!/bin/bash
# Nhập các bí mật cho autoinstall. CHẠY TRONG TERMINAL (cần gõ ẩn), không chạy qua AI.
# Kết quả nằm ở secrets/ (git-ignored, chmod 600).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p secrets && chmod 700 secrets

ask_secret() { # $1 = nhãn, $2 = file
  local a b
  while true; do
    read -rsp "$1: " a; echo
    read -rsp "Nhập lại: " b; echo
    [[ -n "$a" && "$a" == "$b" ]] && break
    echo "  ✗ Không khớp hoặc rỗng, nhập lại."
  done
  printf '%s' "$a" > "secrets/$2"; chmod 600 "secrets/$2"
}

read -rp "Tên user Linux [labadmin]: " u; printf '%s' "${u:-labadmin}" > secrets/username

echo "— Mật khẩu user (dùng cho sudo / đăng nhập tại máy; SSH chỉ dùng key):"
ask_secret "Mật khẩu user" .pw_plain
openssl passwd -6 -stdin < secrets/.pw_plain > secrets/password_hash
rm -f secrets/.pw_plain; chmod 600 secrets/password_hash

echo "— Auth key Tailscale (Settings → Keys → Generate: one-off, pre-approved, tag:lab, hết hạn 1 ngày):"
read -rsp "tskey-auth-...: " k; echo; printf '%s' "$k" > secrets/ts_authkey; chmod 600 secrets/ts_authkey

read -rp "WiFi SSID: " s; printf '%s' "$s" > secrets/wifi_ssid
read -rsp "WiFi password: " w; echo; printf '%s' "$w" > secrets/wifi_pass; chmod 600 secrets/wifi_pass

echo "✓ Xong. File trong secrets/:"; ls -l secrets/
