# Proxmox Host Device IDs

Raw capture below: **2026-01-16**. Summary table re-verified **2026-08-25** on `pve` (192.168.1.239).

Use these IDs when writing Terraform/Packer disk references or Proxmox passthrough configs. The stable identifiers are the `ata-*`, `nvme-*`, and `usb-*` names — the `dm-*` and `lvm-pv-uuid-*` names are LVM internals and not referenced directly.

## Storage layout summary

**Re-verified live on `pve` 2026-08-25.** The raw capture further down is the
original 2026-01-16 paste and is kept as-is; it was taken on a host called
`homelab` with an `ubuntu-vg`, which no longer describes this machine. Trust
this table, not that paste.

| Device | Model | Role |
|--------|-------|------|
| `sda1` (WDC WDS240G1G0B, 223.6 GB) | SATA SSD | `/srv/staging-ssd` — torrent incomplete downloads |
| `sdb2`–`sdb5` (ST24000NT002, 21.8 TB) | USB (QNAP TR-004) | 4 PVs → `media_vg/media_lv` (xfs) → `/mnt/d24` |
| `sdc1` (ST16000NM000J, 14.6 TB) | USB (QNAP TR-004) | plain xfs → `/mnt/d16` |
| `sdd1` (ST8000AS0002, 7.3 TB) | USB (QNAP TR-004) | plain xfs → `/mnt/d8` |
| `nvme0n1p3` (WD BLACK SN770, 931.5 GB) | NVMe | sole PV of VG `pve` — root, `/srv/appdata` (500 GB ext4) and every guest disk |

`/srv/media` is **mergerfs** over `/mnt/d8:/mnt/d16:/mnt/d24` (43.7 TB), not a
single LVM volume — only the 24 TB disk goes through LVM. The mount names are
nominal capacities, so `/mnt/d8` is the 7.3 TB disk and `/mnt/d24` the 21.8 TB
one.

GPU: Intel UHD Graphics 770 (Raptor Lake, `8086:a780`) — passed through to
`01-media-vm` as `hostpci0` for Plex transcoding.
USB: Intel Raptor Lake USB 3.2 Gen 2x2 XHCI (`8086:7a60`).

Stable identifiers remain the `ata-*`, `nvme-*` and `usb-*` names; `dm-*` and
`lvm-pv-uuid-*` are LVM internals.

To refresh this snapshot: run `ls -l /dev/disk/by-id`, `lsblk -o NAME,SIZE,MODEL,SERIAL,WWN`, and `lspci -nn | rg -i 'vga|usb'` on the Proxmox host.

---

toomhorvath@homelab:~$ ls -l /dev/disk/by-id
lsblk -o NAME,SIZE,MODEL,SERIAL,WWN
lspci -nn | rg -i 'vga|usb'
total 0
lrwxrwxrwx 1 root root  9 Jan 16 18:56 ata-ST16000NM000J-2TW103_ZR52X7S0 -> ../../sdc
lrwxrwxrwx 1 root root 10 Jan 16 18:56 ata-ST16000NM000J-2TW103_ZR52X7S0-part1 -> ../../sdc1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 ata-ST24000NT002-3N1101_ZYD1KPDF -> ../../sdb
lrwxrwxrwx 1 root root 10 Jan 16 18:56 ata-ST24000NT002-3N1101_ZYD1KPDF-part1 -> ../../sdb1
lrwxrwxrwx 1 root root 10 Jan 16 18:56 ata-ST24000NT002-3N1101_ZYD1KPDF-part2 -> ../../sdb2
lrwxrwxrwx 1 root root 10 Jan 16 18:56 ata-ST24000NT002-3N1101_ZYD1KPDF-part3 -> ../../sdb3
lrwxrwxrwx 1 root root 10 Jan 16 18:56 ata-ST24000NT002-3N1101_ZYD1KPDF-part4 -> ../../sdb4
lrwxrwxrwx 1 root root 10 Jan 16 18:56 ata-ST24000NT002-3N1101_ZYD1KPDF-part5 -> ../../sdb5
lrwxrwxrwx 1 root root  9 Jan 16 18:56 ata-ST8000AS0002-1NA17Z_Z8410NRT -> ../../sdd
lrwxrwxrwx 1 root root 10 Jan 16 18:56 ata-ST8000AS0002-1NA17Z_Z8410NRT-part1 -> ../../sdd1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 ata-WDC_WDS240G1G0B-00RC30_174288800627 -> ../../sda
lrwxrwxrwx 1 root root 10 Jan 19 17:09 ata-WDC_WDS240G1G0B-00RC30_174288800627-part1 -> ../../sda1
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-name-media_vg-media_lv -> ../../dm-4
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-name-ubuntu--vg-appdata--lv -> ../../dm-2
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-name-ubuntu--vg-timemachine--lv -> ../../dm-1
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-name-ubuntu--vg-ubuntu--lv -> ../../dm-0
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-uuid-LVM-lJWStPVbiRP4BiaRSEQulQWAjBe48GnHARr4LuHrCN2cAtT2R3eaMVTaSv3CkTCs -> ../../dm-4
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-uuid-LVM-QFJUejM0RfSTxmUgjn1JQiE4mPwWi3wGGbJZRWlKaOUNLfp8y2dH9FQ11lmAPSBy -> ../../dm-1
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-uuid-LVM-QFJUejM0RfSTxmUgjn1JQiE4mPwWi3wGkuLszyVFjRyi68nERUuKk3uSJwKBuNwd -> ../../dm-0
lrwxrwxrwx 1 root root 10 Jan 16 18:56 dm-uuid-LVM-QFJUejM0RfSTxmUgjn1JQiE4mPwWi3wGx1HcQACeofODbm8dFez3Ru81eltXiOGJ -> ../../dm-2
lrwxrwxrwx 1 root root 10 Jan 16 18:56 lvm-pv-uuid-1KCO6V-rSlX-dkMK-KDY1-zIc0-I2PD-JnGieO -> ../../sdb5
lrwxrwxrwx 1 root root 15 Jan 16 18:56 lvm-pv-uuid-5orD62-vSdZ-Fq3w-RG6z-5Rfo-UsDO-swmsZZ -> ../../nvme0n1p3
lrwxrwxrwx 1 root root 10 Jan 16 18:56 lvm-pv-uuid-DtjeTQ-Fa7h-e33f-ZzxN-Ofeo-fO7s-XjVfPq -> ../../sdb2
lrwxrwxrwx 1 root root 10 Jan 16 18:56 lvm-pv-uuid-nZTgk2-hBwm-xdLH-PNTN-Wxzf-KRml-wnhs24 -> ../../sdb3
lrwxrwxrwx 1 root root 10 Jan 16 18:56 lvm-pv-uuid-OtOfOi-WUWz-k13v-ikeN-C0Db-3rTW-QNgkOV -> ../../sdb4
lrwxrwxrwx 1 root root 13 Jan 16 18:56 nvme-eui.e8238fa6bf530001001b448b4c164575 -> ../../nvme0n1
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-eui.e8238fa6bf530001001b448b4c164575-part1 -> ../../nvme0n1p1
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-eui.e8238fa6bf530001001b448b4c164575-part2 -> ../../nvme0n1p2
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-eui.e8238fa6bf530001001b448b4c164575-part3 -> ../../nvme0n1p3
lrwxrwxrwx 1 root root 13 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884 -> ../../nvme0n1
lrwxrwxrwx 1 root root 13 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884_1 -> ../../nvme0n1
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884_1-part1 -> ../../nvme0n1p1
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884_1-part2 -> ../../nvme0n1p2
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884_1-part3 -> ../../nvme0n1p3
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884-part1 -> ../../nvme0n1p1
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884-part2 -> ../../nvme0n1p2
lrwxrwxrwx 1 root root 15 Jan 16 18:56 nvme-WD_BLACK_SN770_1TB_233942801884-part3 -> ../../nvme0n1p3
lrwxrwxrwx 1 root root  9 Jan 16 18:56 scsi-0ATA_WDC_WDS240G1G0B-_174288800627 -> ../../sda
lrwxrwxrwx 1 root root 10 Jan 19 17:09 scsi-0ATA_WDC_WDS240G1G0B-_174288800627-part1 -> ../../sda1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 scsi-1ATA_WDC_WDS240G1G0B-00RC30_174288800627 -> ../../sda
lrwxrwxrwx 1 root root 10 Jan 19 17:09 scsi-1ATA_WDC_WDS240G1G0B-00RC30_174288800627-part1 -> ../../sda1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 scsi-35001b448b6402271 -> ../../sda
lrwxrwxrwx 1 root root 10 Jan 19 17:09 scsi-35001b448b6402271-part1 -> ../../sda1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 scsi-SATA_WDC_WDS240G1G0B-_174288800627 -> ../../sda
lrwxrwxrwx 1 root root 10 Jan 19 17:09 scsi-SATA_WDC_WDS240G1G0B-_174288800627-part1 -> ../../sda1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 usb-QNAP_TR-004_DISK00_51554650553030313734-0:0 -> ../../sdb
lrwxrwxrwx 1 root root 10 Jan 16 18:56 usb-QNAP_TR-004_DISK00_51554650553030313734-0:0-part1 -> ../../sdb1
lrwxrwxrwx 1 root root 10 Jan 16 18:56 usb-QNAP_TR-004_DISK00_51554650553030313734-0:0-part2 -> ../../sdb2
lrwxrwxrwx 1 root root 10 Jan 16 18:56 usb-QNAP_TR-004_DISK00_51554650553030313734-0:0-part3 -> ../../sdb3
lrwxrwxrwx 1 root root 10 Jan 16 18:56 usb-QNAP_TR-004_DISK00_51554650553030313734-0:0-part4 -> ../../sdb4
lrwxrwxrwx 1 root root 10 Jan 16 18:56 usb-QNAP_TR-004_DISK00_51554650553030313734-0:0-part5 -> ../../sdb5
lrwxrwxrwx 1 root root  9 Jan 16 18:56 usb-QNAP_TR-004_DISK01_51554650553030313734-0:1 -> ../../sdc
lrwxrwxrwx 1 root root 10 Jan 16 18:56 usb-QNAP_TR-004_DISK01_51554650553030313734-0:1-part1 -> ../../sdc1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 usb-QNAP_TR-004_DISK02_51554650553030313734-0:2 -> ../../sdd
lrwxrwxrwx 1 root root 10 Jan 16 18:56 usb-QNAP_TR-004_DISK02_51554650553030313734-0:2-part1 -> ../../sdd1
lrwxrwxrwx 1 root root  9 Jan 16 18:56 wwn-0x5001b448b6402271 -> ../../sda
lrwxrwxrwx 1 root root 10 Jan 19 17:09 wwn-0x5001b448b6402271-part1 -> ../../sda1
NAME                             SIZE MODEL                SERIAL       WWN
loop0                             13M
loop1                             13M
loop2                             74M
loop3                           50.9M
loop4                           73.9M
loop5                           48.1M
sda                            223.6G WDC WDS240G1G0B-     174288800627 0x5001b448b6402271
└─sda1                         223.6G                                   0x5001b448b6402271
sdb                             21.8T ST24000NT002-3N1101  ZYD1KPDF
├─sdb1                            16M
├─sdb2                           6.8T
│ └─media_vg-media_lv           21.8T
├─sdb3                           7.2T
│ └─media_vg-media_lv           21.8T
├─sdb4                             2T
│ └─media_vg-media_lv           21.8T
└─sdb5                           5.9T
  └─media_vg-media_lv           21.8T
sdc                             14.6T ST16000NM000J-2TW103 ZR52X7S0
└─sdc1                          14.6T
sdd                              7.3T ST8000AS0002-1NA17Z  Z8410NRT
└─sdd1                           7.3T
nvme0n1                        931.5G WD_BLACK SN770 1TB   233942801884 eui.e8238fa6bf530001001b448b4c164575
├─nvme0n1p1                        1G                                   eui.e8238fa6bf530001001b448b4c164575
├─nvme0n1p2                        2G                                   eui.e8238fa6bf530001001b448b4c164575
└─nvme0n1p3                    928.5G                                   eui.e8238fa6bf530001001b448b4c164575
  ├─ubuntu--vg-ubuntu--lv        200G
  ├─ubuntu--vg-timemachine--lv   280G
  └─ubuntu--vg-appdata--lv       200G
00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-S GT1 [UHD Graphics 770] [8086:a780] (rev 04)
00:14.0 USB controller [0c03]: Intel Corporation Raptor Lake USB 3.2 Gen 2x2 (20 Gb/s) XHCI Host Controller [8086:7a60] (rev 11)
toomhorvath@homelab:~$
