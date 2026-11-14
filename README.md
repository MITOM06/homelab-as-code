# homelab-as-code

An old HP EliteBook 840 G1 turned into a **reproducible, locked-down Linux lab** — wiped and
rebuilt from code in 30–60 minutes, **without a USB stick**, and reachable only over a private
Tailscale network.

The lab is used to study operating systems, networking and security, and to attack-test my own
applications in isolation.

**Stack:** Ubuntu Server 26.04 LTS autoinstall (cloud-init / curtin) · Ansible · nftables ·
Tailscale ACLs · Docker · PowerShell · Bash · xorriso

> Comments in the code are in Vietnamese. Personal identifiers (tailnet, user names, SSH keys,
> Wi-Fi) are replaced with placeholders; secrets are never committed.

---

## Architecture

```
laptop ──Tailscale──▶ hp-lab (tag:lab)
                       ├─ Ubuntu Server 26.04 LTS — boots unattended after a power cut
                       ├─ nftables: drop ALL inbound traffic except via tailscale0
                       ├─ SSH: keys only, no root login
                       ├─ Docker: published ports bind to 127.0.0.1 by default
                       └─ XFCE + xrdp: remote desktop, port 3389 reachable only over Tailscale

Tailscale ACL: trusted devices → lab is allowed; lab → anything is denied,
so a compromised lab cannot pivot to the rest of the network.
```

| Layer | Protects against | Where |
|---|---|---|
| Tailscale ACL | A compromised lab attacking other machines | Tailscale admin |
| nftables (input drop) | Other LAN / Wi-Fi hosts probing the lab | `roles/firewall` |
| SSH key-only, no root | Password guessing | `roles/ssh` |
| Docker bind 127.0.0.1 | Containers publishing ports past the firewall | `roles/docker` |
| unattended-upgrades | Known, already-patched vulnerabilities | `roles/base` |
| Install-time cleanup | Auth keys / Wi-Fi passwords left in installer logs | `roles/cleanup` |

## Installing without a USB stick

Part of the laptop's own SSD becomes a "virtual USB": Windows shrinks a volume by 6 GB, a FAT32
partition `HPLABINST` at the end of the disk receives the Ubuntu installer, and the laptop boots
into it **once**. The installer wipes Windows, installs Ubuntu into the freed space while keeping
the partition it is running from, and Ansible later deletes that partition and grows LVM over it.

```
before: [ESP][ C: Windows 122G ][ D: 95G ][HPLABINST 6G]
after:  [ESP][/boot 2G][ LVM ~215G ][HPLABINST]  → Ansible →  [ESP][/boot][ LVM ~221G ]
```

Safety rails, because this step destroys data:

- The disk layout is measured from Windows to the byte (`state/hp-disk-layout.json`) and rendered
  into the autoinstall config by `scripts/build-iso.sh`.
- The installer's `early-commands` verify the exact SSD model, partition label and offsets and
  **abort before touching the disk** on any mismatch.
- The installer accepts SSH (key only) so the install can be watched and rescued remotely.

## Repository layout

```
autoinstall/user-data.tmpl   Ubuntu autoinstall template (placeholders filled at build time)
scripts/
  fill-secrets.sh            prompt for user, password hash, Tailscale auth key, Wi-Fi → secrets/ (git-ignored)
  hp-prepare.sh              create the HPLABINST partition from Windows, record the disk layout
  build-iso.sh               render the template and repack the Ubuntu ISO
  hp-stage.sh                copy the ISO to the laptop and unpack it into HPLABINST, then delete it
  hp/*.ps1                   Windows-side helpers (partitioning, staging, boot-once)
  bench/hp-bench.sh          CPU / RAM / SSD / nginx / Node / Postgres / network benchmark with a thermal guard
ansible/
  site.yml                   idempotent playbook: cleanup, base, ssh, firewall, docker, wifi, desktop, laptop, tui
  wifi-failover-test.yml     proves the lab stays reachable over Wi-Fi with the LAN cable unplugged
```

## Usage

```bash
scripts/fill-secrets.sh            # run in a real terminal — inputs are hidden
scripts/build-iso.sh               # → build/hp-lab-autoinstall.iso
scripts/hp-stage.sh                # stage the installer on the laptop
# boot the laptop once into HPLABINST (F9 → Boot From EFI File)
cd ansible && ansible-playbook site.yml --ask-become-pass
```

Edit `ansible/inventory.yml` first: your tailnet host name, admin user and SSH public keys.

## Lessons learned

- Windows mounts an Ubuntu ISO with 8.3 ISO9660 names only — unpack it with `tar` (libarchive reads
  Rock Ridge) instead of copying from the mounted drive.
- Subiquity converts storage config to curtin `version: 1`, which does not delete undeclared
  partitions — `early-commands` must remove them explicitly, after every safety check.
- netplan does not accept `wifis` with `match:`; and the installer lacks firmware for the USB Wi-Fi
  adapter — install over Ethernet, configure Wi-Fi afterwards with Ansible.
- Ubuntu 26.04 ships `sudo-rs`, which hangs Ansible's become prompt — set `become_exe = sudo.ws`.
- HP firmware refuses boot entries created by `bcdedit` — select the installer once via F9.

## Benchmarks (2026-10-20)

sysbench 774 / 2,099 events/s (1 / 4 threads) · 5 min full load peaks at 73 °C without throttling ·
SSD 205 / 147 MB/s, 54k IOPS · nginx 19.4k req/s · Node 12.6k req/s · pgbench 3,044 tps ·
~300 MB RAM used at idle.
