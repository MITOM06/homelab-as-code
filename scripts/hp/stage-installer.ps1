# Bước 2 (Windows trên HP): bung ISO đã build vào phân vùng HPLABINST rồi XOÁ file ISO
# (ISO chứa auth key Tailscale + mật khẩu WiFi). Chỉ xoá nội dung của đúng phân vùng HPLABINST.
# Dùng tar (libarchive) chứ KHÔNG mount ISO: Windows chỉ đọc tên ISO9660 kiểu 8.3 viết hoa
# (.disk → _DISK, user-data → USER_DATA), còn tar đọc đúng tên Rock Ridge của Linux.
# Bỏ 3 symlink (ubuntu → ., dists/stable|unstable → resolute): FAT32 không có symlink, bộ cài không cần.
# -m: không khôi phục giờ sửa đổi (thư mục gốc FAT32 không đặt được → tar báo lỗi giả).
param([Parameter(Mandatory = $true)][string]$IsoPath,
      [Parameter(Mandatory = $true)][int]$ExpectFiles,
      [Parameter(Mandatory = $true)][int64]$ExpectBytes)
$ErrorActionPreference = 'Stop'

$vol = Get-Volume | Where-Object FileSystemLabel -eq 'HPLABINST'
if (-not $vol) { throw 'Chưa có phân vùng HPLABINST — chạy prepare-installer-partition.ps1 trước.' }
if (-not (Test-Path -LiteralPath $IsoPath)) { throw "Không thấy $IsoPath" }
$dst = "$($vol.DriveLetter):\"

Get-ChildItem -LiteralPath $dst -Force | Remove-Item -Recurse -Force
tar -xmf $IsoPath -C $dst --exclude ubuntu --exclude dists/stable --exclude dists/unstable
if ($LASTEXITCODE -ne 0) { throw "tar lỗi (mã $LASTEXITCODE)" }

$b = Get-ChildItem -LiteralPath $dst -Recurse -File -Force | Measure-Object Length -Sum
if ($b.Count -ne $ExpectFiles -or $b.Sum -ne $ExpectBytes) {
    throw "Chép không khớp: cần $ExpectFiles file/$ExpectBytes B, HPLABINST có $($b.Count) file/$($b.Sum) B"
}
Write-Output "Đã chép $($b.Count) file ($([math]::Round($b.Sum/1GB,2)) GB) vào HPLABINST ($dst), khớp ISO"

foreach ($f in 'EFI\boot\bootx64.efi', 'boot\grub\grub.cfg', 'nocloud\user-data', '.disk\info', 'casper\ubuntu-server-minimal.squashfs') {
    if (-not (Test-Path -LiteralPath (Join-Path $dst $f))) { throw "Thiếu $f trong HPLABINST" }
}
if (-not (Select-String -LiteralPath (Join-Path $dst 'boot\grub\grub.cfg') -Pattern 'autoinstall ds=nocloud' -Quiet)) {
    throw 'grub.cfg chưa có tham số autoinstall'
}
Remove-Item -LiteralPath $IsoPath -Force
Write-Output 'Đã xoá file ISO tạm. HPLABINST sẵn sàng.'
