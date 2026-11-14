# Bước 1 (Windows trên HP): tạo phân vùng HPLABINST ở cuối ổ để chứa bộ cài Ubuntu (thay cho USB).
# - Thu nhỏ D: thêm $SizeGB GB rồi tạo phân vùng FAT32 trong khoảng trống đó. KHÔNG xoá dữ liệu.
# - Chạy lại được: nếu HPLABINST đã có thì chỉ in bố cục.
# - Dòng cuối in "LAYOUT=<json>" — bố cục chính xác từng byte, build-iso.sh dùng để khai báo phân vùng.
param([int]$SizeGB = 6)
$ErrorActionPreference = 'Stop'

$disk = Get-Disk -Number 0
if ($disk.FriendlyName -notmatch 'KINGMAX' -or $disk.PartitionStyle -ne 'GPT') {
    throw "Ổ 0 không phải SSD KINGMAX/GPT ($($disk.FriendlyName), $($disk.PartitionStyle)) — dừng."
}

$inst = Get-Volume | Where-Object FileSystemLabel -eq 'HPLABINST'
if ($inst) {
    Write-Output "HPLABINST đã có ($($inst.DriveLetter):), bỏ qua bước tạo."
} else {
    $parts = @(Get-Partition -DiskNumber 0)
    if ($parts.Count -ne 3) { throw "Mong đợi 3 phân vùng (ESP, C:, D:), thấy $($parts.Count) — dừng." }
    $d = Get-Partition -DriveLetter D
    if ($d.PartitionNumber -ne 3) { throw "D: không phải phân vùng 3 — dừng." }

    $newSize = $d.Size - [int64]$SizeGB * 1GB
    $supported = Get-PartitionSupportedSize -DriveLetter D
    if ($newSize -lt $supported.SizeMin) { throw "Không thu nhỏ D: được (cần $newSize, tối thiểu $($supported.SizeMin))." }

    Write-Output "Thu nhỏ D: $([math]::Round($d.Size/1GB,1)) GB -> $([math]::Round($newSize/1GB,1)) GB"
    Resize-Partition -DriveLetter D -Size $newSize
    $p = New-Partition -DiskNumber 0 -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $p -FileSystem FAT32 -NewFileSystemLabel 'HPLABINST' -Confirm:$false | Out-Null
    Write-Output "Đã tạo HPLABINST ($($p.DriveLetter):) $([math]::Round($p.Size/1GB,2)) GB"
}

$layout = Get-Partition -DiskNumber 0 | Sort-Object Offset | ForEach-Object {
    $label = ''; $letter = ''
    if ($_.DriveLetter -and $_.DriveLetter -ne [char]0) {
        $letter = "$($_.DriveLetter)"; $label = (Get-Volume -DriveLetter $_.DriveLetter).FileSystemLabel
    }
    [pscustomobject]@{ number = $_.PartitionNumber; letter = $letter; label = "$label"
                       offset = $_.Offset; size = $_.Size; gpt_type = "$($_.GptType)" }
}
Write-Output ("LAYOUT=" + (ConvertTo-Json @($layout) -Compress))
