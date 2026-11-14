#!/bin/bash
# Chạy 1 file .ps1 trên HP (Windows) qua `ssh hp`: chép vào %TEMP% (kèm BOM UTF-8 để PowerShell 5.1
# đọc đúng tiếng Việt), chạy với -File + tham số, xoá file ngay sau đó.
#   scripts/hp-ps.sh scripts/hp/prepare-installer-partition.ps1
#   scripts/hp-ps.sh scripts/hp/set-boot-once.ps1 -Reboot
set -euo pipefail
PS1="$1"; shift
[[ -s "$PS1" ]] || { echo "✗ Không thấy $PS1"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NAME="hplab_$(basename "$PS1")"
printf '\xef\xbb\xbf' | cat - "$PS1" > "$TMP/$NAME"
R="C:/Users/Admin/AppData/Local/Temp/$NAME"
scp -q -o BatchMode=yes "$TMP/$NAME" "hp:$R"
set +e
ssh -o BatchMode=yes hp "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"[Console]::OutputEncoding=[Text.Encoding]::UTF8; try { & '$R' $*; exit 0 } catch { Write-Output ('LỖI: ' + \$_); exit 1 }\"" \
  | LC_ALL=C tr -d '\r' | { grep -a -v -E '^#< CLIXML|^<Objs' || true; }
RC=${PIPESTATUS[0]}
set -e
ssh -o BatchMode=yes hp "del \"${R//\//\\}\"" || echo "⚠️  Không xoá được $R trên HP"
exit "$RC"
