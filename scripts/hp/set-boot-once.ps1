# Bước 3 (Windows trên HP): tạo mục khởi động UEFI "HP-LAB Installer" trỏ vào HPLABINST và đặt
# khởi động MỘT LẦN (BootNext) vào đó. Không đổi thứ tự khởi động mặc định: nếu bộ cài không lên
# hoặc tự dừng ở bước kiểm tra an toàn, lần khởi động sau vẫn vào Windows như cũ.
#   Không có -Reboot: chỉ cài đặt, KHÔNG khởi động lại.
#   -Reboot          : khởi động lại sau 20 giây → máy vào bộ cài → TỰ XOÁ WINDOWS, CÀI UBUNTU.
param([switch]$Reboot)
$ErrorActionPreference = 'Stop'

$vol = Get-Volume | Where-Object FileSystemLabel -eq 'HPLABINST'
if (-not $vol) { throw 'Chưa có phân vùng HPLABINST.' }
$L = $vol.DriveLetter
foreach ($f in 'EFI\boot\bootx64.efi', 'boot\grub\grub.cfg', 'nocloud\user-data') {
    if (-not (Test-Path -LiteralPath "${L}:\$f")) { throw "Thiếu $f — chạy stage-installer.ps1 trước." }
}

# Xoá mục cũ cùng tên (khi chạy lại)
$enum = (bcdedit /enum firmware) -join "`n"
foreach ($blk in ($enum -split "`n`n")) {
    if ($blk -match 'HP-LAB Installer' -and $blk -match 'identifier\s+(\{[0-9a-fA-F-]{36}\})') {
        bcdedit /delete $Matches[1] | Out-Null
    }
}

$out = bcdedit /copy '{bootmgr}' /d 'HP-LAB Installer'
$id = [regex]::Match(($out -join ' '), '\{[0-9a-fA-F-]{36}\}').Value
if (-not $id) { throw "bcdedit /copy thất bại: $out" }
bcdedit /set $id device "partition=${L}:" | Out-Null
bcdedit /set $id path '\EFI\boot\bootx64.efi' | Out-Null
bcdedit /set '{fwbootmgr}' bootsequence $id | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Không đặt được BootNext.' }

Write-Output "Đã đặt khởi động 1 lần vào HP-LAB Installer $id (${L}:\EFI\boot\bootx64.efi)"
bcdedit /enum '{fwbootmgr}' | Select-String -Pattern 'bootsequence|displayorder' | ForEach-Object { $_.Line }

if ($Reboot) {
    shutdown /r /t 20 /c 'HP-LAB: khoi dong vao bo cai Ubuntu'
    Write-Output 'Khởi động lại sau 20 giây. Hủy: shutdown /a'
} else {
    Write-Output 'CHƯA khởi động lại. Chạy lại với -Reboot khi sẵn sàng.'
}
