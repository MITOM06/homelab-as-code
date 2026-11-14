#!/bin/bash
# Mac → HP: tạo phân vùng HPLABINST (thu nhỏ D: 6GB, không xoá dữ liệu) và lưu bố cục ổ
# chính xác vào state/hp-disk-layout.json cho build-iso.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p state
OUT=$(scripts/hp-ps.sh scripts/hp/prepare-installer-partition.ps1)
echo "$OUT" | grep -v '^LAYOUT='
J=$(echo "$OUT" | sed -n 's/^LAYOUT=//p')
[[ -n "$J" ]] || { echo "✗ Không nhận được bố cục ổ từ HP"; exit 1; }
echo "$J" | yq -P -o json > state/hp-disk-layout.json
echo "✓ state/hp-disk-layout.json:"
yq -o tsv '.[] | [.number, .letter, .label, .offset, .size]' state/hp-disk-layout.json
