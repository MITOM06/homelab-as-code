#!/bin/bash
# Mac → HP: tải ISO đã build sang HP (sftp, tự nối lại khi WiFi rớt), bung vào HPLABINST,
# rồi xoá ISO ở cả 2 đầu (ISO chứa auth key Tailscale + mật khẩu WiFi).
set -euo pipefail
cd "$(dirname "$0")/.."
ISO=build/hp-lab-autoinstall.iso
REMOTE=C:/Users/Admin/AppData/Local/Temp/hp-lab.iso
[[ -s "$ISO" ]] || { echo "✗ Thiếu $ISO — chạy scripts/build-iso.sh trước"; exit 1; }
SIZE=$(stat -f %z "$ISO")

remote_size() {
  # In rõ "SIZE=<byte>" / "SIZE=" rồi chỉ đọc dòng đó: PowerShell qua ssh có thể in thêm rác CLIXML
  ssh -o BatchMode=yes hp "powershell -NoProfile -Command \"\$f = Get-Item '$REMOTE' -ErrorAction SilentlyContinue; 'SIZE=' + \$(if (\$f) { \$f.Length })\"" \
    | tr -d '\r' | sed -n 's/^SIZE=\([0-9]*\)$/\1/p'
}

for i in $(seq 1 20); do
  echo "[$(date +%H:%M:%S)] tải ISO sang HP, lượt $i"
  # put -a (tải tiếp) chỉ chạy khi file đích đã tồn tại; lượt đầu dùng put thường
  if [[ -z "$(remote_size)" ]]; then PUT=put; else PUT="put -a"; fi
  printf '%s "%s" "/%s"\n' "$PUT" "$ISO" "$REMOTE" \
    | sftp -q -b - -o BatchMode=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 hp >/dev/null || true
  [[ "$(remote_size)" == "$SIZE" ]] && break
  sleep 10
done
[[ "$(remote_size)" == "$SIZE" ]] || { echo "✗ Tải ISO không xong"; exit 1; }
echo "✓ Đã tải ISO ($((SIZE / 1048576)) MB)"

# Số file (trừ thư mục/symlink, gồm cả boot.catalog) + tổng byte trong ISO để HP đối chiếu sau khi bung
read -r NFILES NBYTES < <(xorriso -indev "$ISO" -find / -not -type d -not -type l -exec lsdl 2>/dev/null | awk '{n++; s+=$5} END {print n, s}')
scripts/hp-ps.sh scripts/hp/stage-installer.ps1 -IsoPath "$REMOTE" -ExpectFiles "$NFILES" -ExpectBytes "$NBYTES"
rm -rf build
echo "✓ Đã xoá build/ trên Mac"
