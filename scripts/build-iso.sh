#!/bin/bash
# Đóng file autoinstall vào ISO Ubuntu → build/hp-lab-autoinstall.iso (chép vào phân vùng HPLABINST trên HP).
# Chỉ build file ISO trên Mac; KHÔNG đụng máy HP.
set -euo pipefail
cd "$(dirname "$0")/.."
ISO=iso/ubuntu-26.04.1-live-server-amd64.iso
OUT=build/hp-lab-autoinstall.iso
need() { [[ -s "$1" ]] || { echo "✗ Thiếu $1 — chạy scripts/fill-secrets.sh trước"; exit 1; }; }

command -v xorriso >/dev/null || { echo "✗ Thiếu xorriso (brew install xorriso)"; exit 1; }
[[ -s "$ISO" ]] || { echo "✗ Thiếu $ISO"; exit 1; }
for f in username password_hash ts_authkey wifi_ssid wifi_pass; do need "secrets/$f"; done

[[ -s state/hp-disk-layout.json ]] || { echo "✗ Thiếu state/hp-disk-layout.json — chạy scripts/hp-prepare.sh trước"; exit 1; }

rm -rf build && mkdir -p build/nocloud && chmod 700 build
python3 -I - "$HOME/.ssh/id_ed25519.pub" <<'PY'
import sys, json, pathlib
s = pathlib.Path('secrets'); r = lambda n: (s / n).read_text().strip()
t = pathlib.Path('autoinstall/user-data.tmpl').read_text()

# Bố cục ổ: giữ sda1 (ESP) + sda4 (HPLABINST), tạo sda2 /boot + sda3 PV vào khoảng trống giữa
MiB, GiB = 1 << 20, 1 << 30
parts = {p['number']: p for p in json.loads(pathlib.Path('state/hp-disk-layout.json').read_text())}
esp, inst = parts.get(1), parts.get(4)
assert len(parts) == 4 and esp and inst, f'Mong đợi 4 phân vùng (ESP..HPLABINST), thấy {sorted(parts)}'
assert esp['gpt_type'].lower() == '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}', 'sda1 không phải ESP'
assert inst['label'] == 'HPLABINST', f"sda4 không phải HPLABINST ({inst['label']})"
boot_off = -(-(esp['offset'] + esp['size']) // MiB) * MiB
boot_size = 2 * GiB
pv_off = boot_off + boot_size
pv_size = (inst['offset'] - pv_off) // MiB * MiB
assert pv_size >= 150 * GiB, f'PV chỉ còn {pv_size / GiB:.1f} GiB — bố cục lạ, dừng'
layout = {'__ESP_OFFSET__': esp['offset'], '__ESP_SIZE__': esp['size'],
          '__BOOT_OFFSET__': boot_off, '__BOOT_SIZE__': boot_size,
          '__PV_OFFSET__': pv_off, '__PV_SIZE__': pv_size,
          '__INST_OFFSET__': inst['offset'], '__INST_SIZE__': inst['size']}
for k, v in layout.items():
    t = t.replace(k, str(v))
print(f"  bố cục: /boot {boot_size // GiB} GiB @ {boot_off} | PV {pv_size / GiB:.1f} GiB @ {pv_off} | HPLABINST @ {inst['offset']}")

for k, v in {'__USERNAME__': r('username'), '__PASSWORD_HASH__': r('password_hash'),
             '__TS_AUTHKEY__': r('ts_authkey'),
             '__WIFI_SSID__': r('wifi_ssid'), '__WIFI_PASS__': r('wifi_pass'),
             '__SSH_PUBKEY__': pathlib.Path(sys.argv[1]).read_text().strip()}.items():
    if any(c in v for c in '"\\\n'): sys.exit(f"✗ Giá trị cho {k} chứa ký tự \" hoặc \\ hoặc xuống dòng — đổi giá trị khác")
    t = t.replace(k, v)
import re
left = [m for m in re.findall(r'__[A-Z_]+__', t) if m != '__XXX__']
assert not left, f'Còn placeholder chưa thay: {left}'
pathlib.Path('build/nocloud/user-data').write_text(t)
PY
: > build/nocloud/meta-data

# Kiểm cú pháp YAML + các khoá bắt buộc ngay trên Mac (lỗi ở đây rẻ hơn lỗi lúc HP đang boot)
command -v yq >/dev/null || { echo "✗ Thiếu yq (brew install yq)"; exit 1; }
yq -e '.autoinstall.storage.version == 2 and (.autoinstall.storage.config | length) == 13 and (.autoinstall.early-commands | length) == 11' \
  build/nocloud/user-data >/dev/null || { echo "✗ user-data sai cú pháp hoặc thiếu khoá"; exit 1; }

# Thêm tham số kernel "autoinstall" để installer chạy tự động, không hỏi xác nhận
xorriso -osirrox on -indev "$ISO" -extract /boot/grub/grub.cfg build/grub.cfg >/dev/null 2>&1
chmod u+w build/grub.cfg
sed -i '' 's|---|autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---|g' build/grub.cfg
grep -q 'autoinstall ds=nocloud' build/grub.cfg || { echo "✗ Không sửa được grub.cfg"; exit 1; }

xorriso -indev "$ISO" -outdev "$OUT" \
  -map build/nocloud /nocloud \
  -map build/grub.cfg /boot/grub/grub.cfg \
  -boot_image any replay >/dev/null 2>&1
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
echo "⚠️  ISO này chứa auth key Tailscale + mật khẩu WiFi: chép sang HP xong thì xoá build/ (hp-stage.sh tự xoá)."
