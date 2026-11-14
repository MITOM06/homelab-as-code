#!/bin/bash
# Benchmark hp-lab — chạy TRÊN HP (không cần sudo: công cụ chạy trong container Docker).
#   Từ Air:  scp scripts/bench/hp-bench.sh hp:~ && ssh hp 'bash ~/hp-bench.sh'
# Kết quả: ~/bench/<ngày>/ (summary.txt = số chính, *.log = output gốc)
# An toàn nhiệt: CPU package >= 92°C → dừng ngay container đang chạy (máy từng tự tắt vì quá nhiệt).
set -uo pipefail
OUT=~/bench/$(date +%Y%m%d-%H%M); mkdir -p "$OUT"; cd "$OUT" || exit 1
SUM=summary.txt; : > "$SUM"
TEMP_LIMIT=92
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a run.log; }
kv()  { echo "$1=$2" | tee -a "$SUM"; }
pkg_temp() { for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type)" = x86_pkg_temp ] && echo $(( $(cat $z/temp) / 1000 )); done; }
cur_mhz() { awk '/cpu MHz/{s+=$4;n++} END{printf "%d", s/n}' /proc/cpuinfo; }

# Canh nhiệt chạy nền suốt bài test: ghi nhiệt + xung mỗi 2s, quá ngưỡng thì kill container "bench-*"
watchdog() {
  while :; do
    t=$(pkg_temp); echo "$(date +%s) $t $(cur_mhz)" >> thermal.log
    if [ "${t:-0}" -ge "$TEMP_LIMIT" ]; then
      echo "QUÁ NHIỆT ${t}°C — dừng bài test" | tee -a run.log
      docker ps -q --filter name=bench- | xargs -n1 docker kill >/dev/null 2>&1
      touch OVERHEAT
    fi
    sleep 2
  done
}
watchdog & WD=$!
trap 'kill $WD 2>/dev/null; docker rm -f $(docker ps -aq --filter name=bench-) >/dev/null 2>&1' EXIT

# Lấy nhiệt cao nhất / xung thấp nhất trong khoảng thời gian [t0, now]
thermal_span() { awk -v a="$1" '$1>=a {if($2>mx)mx=$2; if(mn==""||$3<mn)mn=$3; s+=$3; n++} END{printf "%s %s %d", mx, mn, s/n}' thermal.log; }

# ───────── 0. Trạng thái rảnh (trước khi tải gì) ─────────
log "0. Trạng thái rảnh"
kv os "$(. /etc/os-release; echo "$PRETTY_NAME") / kernel $(uname -r)"
kv cpu "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo) ($(nproc) luồng)"
kv cpu_max_mhz "$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) / 1000 ))"
kv governor "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
kv ram_total_mb "$(free -m | awk '/Mem:/{print $2}')"
kv ram_used_idle_mb "$(free -m | awk '/Mem:/{print $3}')"
kv swap "$(swapon --show=NAME,SIZE --noheadings | tr '\n' ' ' | sed 's/ *$//')"
kv processes "$(ps -e --no-headers | wc -l)"
kv services_running "$(systemctl list-units --type=service --state=running --no-legend | wc -l)"
kv load_avg "$(cut -d' ' -f1-3 /proc/loadavg)"
kv temp_idle_c "$(pkg_temp)"
kv disk_root "$(df -h / | awk 'NR==2{print $3" dùng / "$2" ("$5")"}')"
kv os_size_gb "$(df -BG --output=used / | tail -1 | tr -dc 0-9)G tổng đã dùng (gồm ~/data)"
kv boot_time "$(systemd-analyze 2>/dev/null | head -1 | sed 's/Startup finished in //')"

# ───────── 1. Chuẩn bị image ─────────
log "1. Tải image + công cụ (lần đầu ~2–5 phút qua WiFi)"
docker build -q -t hp-bench-tools - >/dev/null <<'DOCKERFILE' || { log "build image lỗi"; exit 1; }
FROM ubuntu:26.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      sysbench fio stress-ng wrk ca-certificates && rm -rf /var/lib/apt/lists/*
DOCKERFILE
for i in nginx:alpine node:22-alpine postgres:17-alpine; do docker pull -q "$i" >/dev/null || log "pull $i lỗi"; done
T="docker run --rm --name bench-tools hp-bench-tools"

# ───────── 2. CPU ─────────
log "2. CPU (sysbench, số nguyên tố)"
$T sysbench cpu --threads=1 --time=30 run > cpu-1t.log
kv cpu_1thread_events_s "$(awk '/events per second/{print $4}' cpu-1t.log)"
$T sysbench cpu --threads=4 --time=30 run > cpu-4t.log
kv cpu_4thread_events_s "$(awk '/events per second/{print $4}' cpu-4t.log)"

log "2b. CPU tải 100% liên tục 5 phút — xem có tụt xung vì nóng không"
t0=$(date +%s)
docker run --rm --name bench-stress hp-bench-tools stress-ng --cpu 4 --timeout 300s --metrics-brief > stress-5min.log 2>&1
read mx mn avg <<<"$(thermal_span $t0)"
kv sustained_temp_max_c "$mx"; kv sustained_mhz_min "$mn"; kv sustained_mhz_avg "$avg"
kv sustained_bogo_ops_s "$(awk '/metrc:.* cpu +[0-9]/{print $(NF-1)}' stress-5min.log)"
sleep 60; kv temp_after_60s_cooldown_c "$(pkg_temp)"

# ───────── 3. RAM ─────────
log "3. RAM"
$T sysbench memory --memory-block-size=1M --memory-total-size=20G --memory-oper=read run > mem-read.log
kv mem_read_mib_s "$(grep -o '[0-9.]* MiB/sec' mem-read.log | cut -d' ' -f1)"
$T sysbench memory --memory-block-size=1M --memory-total-size=20G --memory-oper=write run > mem-write.log
kv mem_write_mib_s "$(grep -o '[0-9.]* MiB/sec' mem-write.log | cut -d' ' -f1)"
docker run --rm --name bench-vm hp-bench-tools stress-ng --vm 1 --vm-bytes 5G --vm-keep --timeout 30s --metrics-brief > mem-5g.log 2>&1; rc=$?
kv mem_5gb_alloc "$([ $rc -eq 0 ] && echo OK || echo LỖI) (swap dùng sau test: $(free -m | awk '/Swap:/{print $3}')MB)"

# ───────── 4. SSD ─────────
log "4. SSD (fio, file 1GB, bỏ qua cache)"
mkdir -p "$OUT/fio"
F="docker run --rm --name bench-fio -v $OUT/fio:/d hp-bench-tools fio --directory=/d --name=t --size=1G --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting --output-format=json"
$F --rw=read  --bs=1M --iodepth=8  > fio-seqread.log;  kv ssd_seq_read_mb_s  "$(jq '.jobs[0].read.bw/1024|floor' fio-seqread.log)"
$F --rw=write --bs=1M --iodepth=8  > fio-seqwrite.log; kv ssd_seq_write_mb_s "$(jq '.jobs[0].write.bw/1024|floor' fio-seqwrite.log)"
$F --rw=randread  --bs=4k --iodepth=32 > fio-rr32.log; kv ssd_4k_randread_q32_iops  "$(jq '.jobs[0].read.iops|floor' fio-rr32.log)"
$F --rw=randwrite --bs=4k --iodepth=32 > fio-rw32.log; kv ssd_4k_randwrite_q32_iops "$(jq '.jobs[0].write.iops|floor' fio-rw32.log)"
$F --rw=randread  --bs=4k --iodepth=1  > fio-rr1.log;  kv ssd_4k_randread_q1_iops   "$(jq '.jobs[0].read.iops|floor' fio-rr1.log)"
kv ssd_4k_q1_latency_us "$(jq '.jobs[0].read.clat_ns.mean/1000|floor' fio-rr1.log)"
rm -rf "$OUT/fio"

# ───────── 5. Tải thực tế ─────────
log "5a. Web tĩnh (nginx) — wrk 4 luồng, 100 kết nối, 30s"
docker network create bench-net >/dev/null 2>&1
docker run -d --rm --name bench-nginx --network bench-net nginx:alpine >/dev/null; sleep 3
docker run --rm --name bench-wrk --network bench-net hp-bench-tools wrk -t4 -c100 -d30s http://bench-nginx/ > web-nginx.log
kv nginx_req_s "$(awk '/Requests\/sec/{print $2}' web-nginx.log)"
kv nginx_latency_avg "$(awk '/Latency/{print $2; exit}' web-nginx.log)"
docker rm -f bench-nginx >/dev/null

log "5b. API Node.js (JSON, 1 process) — wrk 30s"
docker run -d --rm --name bench-node --network bench-net node:22-alpine node -e '
require("http").createServer((q,s)=>{s.setHeader("content-type","application/json");s.end(JSON.stringify({ok:true,t:Date.now(),items:Array.from({length:20},(_,i)=>({i,n:"item"+i}))}))}).listen(3000)' >/dev/null; sleep 3
docker run --rm --name bench-wrk --network bench-net hp-bench-tools wrk -t4 -c100 -d30s http://bench-node:3000/ > web-node.log
kv node_req_s "$(awk '/Requests\/sec/{print $2}' web-node.log)"
kv node_latency_avg "$(awk '/Latency/{print $2; exit}' web-node.log)"
kv node_container_mem "$(docker stats --no-stream --format '{{.MemUsage}}' bench-node | cut -d/ -f1)"
docker rm -f bench-node >/dev/null

log "5c. PostgreSQL (pgbench TPC-B, scale 50 ≈ 750MB, 16 client, 60s)"
docker run -d --rm --name bench-pg --network bench-net -e POSTGRES_PASSWORD=bench postgres:17-alpine >/dev/null
for i in $(seq 1 30); do docker exec bench-pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 2; done
# pgbench chạy ngay trong container postgres (image có sẵn) → client + DB chung CPU, giống app + DB cùng 1 máy
docker exec bench-pg pgbench -U postgres -i -s 50 -q postgres > pg-init.log 2>&1
docker exec bench-pg pgbench -U postgres -c 16 -j 4 -T 60 postgres > pg-run.log 2>&1
kv pg_tps "$(awk '/^tps/{print $3; exit}' pg-run.log)"
kv pg_latency_ms "$(awk '/latency average/{print $4}' pg-run.log)"
kv pg_container_mem "$(docker stats --no-stream --format '{{.MemUsage}}' bench-pg | cut -d/ -f1)"
docker rm -f bench-pg >/dev/null; docker network rm bench-net >/dev/null

# ───────── 6. Mạng ─────────
log "6. Mạng"
kv ping_router_ms "$(ping -c 10 -q 192.168.1.1 | awk -F/ '/rtt/{print $5}')"
kv ping_internet_ms "$(ping -c 10 -q 1.1.1.1 | awk -F/ '/rtt/{print $5}')"
kv internet_down_mb_s "$(curl -s -o /dev/null --max-time 120 -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=30000000' | awk '{printf "%.2f", $1/1048576}')"
kv internet_up_mb_s "$(head -c 10000000 /dev/urandom | curl -s -o /dev/null --max-time 120 -w '%{speed_upload}' --data-binary @- https://speed.cloudflare.com/__up | awk '{printf "%.2f", $1/1048576}')"
kv wifi_link "$(cat /proc/net/wireless | awk 'NR==3{print "signal " $4 " dBm"}')"

kv temp_max_whole_run_c "$(awk '{if($2>m)m=$2} END{print m}' thermal.log)"
[ -f OVERHEAT ] && kv overheat "CÓ — có bài bị dừng giữa chừng" || kv overheat "không"
log "XONG → $OUT/summary.txt"
