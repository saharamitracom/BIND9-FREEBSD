# BIND9-FREEBSD
# BIND9 + RPZ Komdigi di FreeBSD

Installer satu file untuk resolver rekursif pelanggan ISP dengan filtering
RPZ Komdigi/TrustPositif. Sudah divalidasi dengan `named-checkconf` dan
`named-checkzone` (BIND 9.18).

## Arsitektur filtering

Empat zona RPZ dievaluasi berurutan — **zona pertama yang cocok yang menang**:

| # | Zona | Aksi | Sumber |
|---|------|------|--------|
| 1 | `rpz-whitelist.local` | `passthru` | `rpz/whitelist.txt` (manual) |
| 2 | `rpz-blacklist.local` | `cname` landing | `rpz/blacklist.txt` (manual) |
| 3 | zona AXFR Komdigi | `cname` landing | transfer dari NS Komdigi |
| 4 | `rpz-trustpositif.local` | `cname` landing | unduhan list TrustPositif |

Whitelist di posisi 1 artinya domain di situ **kebal** terhadap blokir Komdigi —
berguna saat ada false positive yang dikomplain pelanggan sambil menunggu
normalisasi resmi.

Aksi blokir memakai `policy cname <landing-fqdn>`, dan `<landing-fqdn>` dilayani
secara autoritatif oleh resolver ini sendiri dengan A record ke webserver Anda.
Jadi klien menerima:

```
judi-xxx.com.            60 IN CNAME blokir.namaisp.net.id.
blokir.namaisp.net.id.  300 IN A     103.10.20.30
```

Target landing didefinisikan **di satu tempat** (named.conf), bukan disebar ke
jutaan record — ganti IP cukup edit `rpz/db.landing` lalu `rndc reload`.

## Instalasi

```sh
fetch -o install-bind-rpz-freebsd.sh <lokasi-file>
chmod +x install-bind-rpz-freebsd.sh

./install-bind-rpz-freebsd.sh \
    --listen=103.10.20.2 \
    --clients=103.10.20.0/22,10.10.0.0/16 \
    --landing-ip=103.10.20.30 \
    --landing-fqdn=blokir.namaisp.net.id \
    --komdigi-primaries=<ip-ns-komdigi-1>,<ip-ns-komdigi-2>
```

Belum terdaftar AXFR ke Komdigi? Jalankan tanpa `--komdigi-primaries` — zona
AXFR tidak dibuat dan filtering murni jalan dari fallback TrustPositif. Setelah
pendaftaran disetujui, jalankan ulang script dengan flag tersebut; konfigurasi
lama otomatis dibackup.

Bila Komdigi meminta TSIG: `--tsig=nama-key:hmac-sha256:BASE64SECRET`

Opsi lain: `--listen6`, `--landing-ip6`, `--komdigi-zone`, `--tp-url`,
`--no-wildcard`, `--cache-size`, `--query-log`, `--no-sysctl`. Lihat `--help`.

## Yang dipasang

```
/usr/local/etc/namedb/named.conf              konfigurasi utama (digenerate)
/usr/local/etc/namedb/rpz/whitelist.txt       daftar passthru, diedit manual
/usr/local/etc/namedb/rpz/blacklist.txt       blokir tambahan, diedit manual
/usr/local/etc/namedb/rpz/db.landing          zona landing page
/usr/local/etc/namedb/rpz/db.rpz-*            zona RPZ hasil generate
/usr/local/etc/namedb/working/slave/          zona hasil AXFR Komdigi
/usr/local/etc/rpz-komdigi.conf               setting updater
/usr/local/sbin/rpz-komdigi-update            generator + reloader
/var/log/named/                               named.log, rpz.log, xfer.log, ...
```

Cron dipasang di `/etc/crontab`, default tiap 6 jam. Rotasi log lewat
`/usr/local/etc/newsyslog.conf.d/rpz-komdigi.conf`.

## Operasi harian

```sh
# refresh daftar TrustPositif sekarang
rpz-komdigi-update

# setelah edit whitelist/blacklist (tanpa unduh ulang list besar)
rpz-komdigi-update --local-only

# status AXFR Komdigi + umur zona fallback
rpz-komdigi-update --check

# lihat domain apa saja yang kena blokir, real time
tail -f /var/log/named/rpz.log

# status per zona
rndc zonestatus rpz-trustpositif.local
rndc zonestatus rpz.komdigi.go.id

# baca isi zona hasil AXFR (formatnya raw)
named-compilezone -f raw -F text -o - rpz.komdigi.go.id \
    /usr/local/etc/namedb/working/slave/db.rpz-komdigi | less
```

Uji cepat:

```sh
dig @127.0.0.1 www.freebsd.org +short          # harus normal
dig @127.0.0.1 <domain-yang-diblokir> +short   # harus keluar IP landing
dig @127.0.0.1 blokir.namaisp.net.id +short    # harus IP webserver Anda
```

### Melepas false positive

```sh
echo "portal.dinas-xyz.go.id" >> /usr/local/etc/namedb/rpz/whitelist.txt
rpz-komdigi-update --local-only
```

Berlaku detik itu juga, tanpa restart named. Tetap ajukan normalisasi resmi ke
Komdigi supaya tidak perlu dipelihara manual selamanya.

## Pengamanan yang sudah ada

- `allow-recursion` / `allow-query-cache` dibatasi ACL `pelanggan` — resolver
  tidak jadi open resolver yang bisa dipakai amplifikasi DDoS.
- `fetches-per-zone` / `fetches-per-server` 200 drop, `clients-per-query`
  — proteksi terhadap random-subdomain attack.
- `version "DNS"`, `hostname none`, `server-id none` — tidak membocorkan versi.
- `allow-transfer { none; }` di semua zona; zona RPZ hanya bisa diquery dari
  localhost.

Tetap batasi port 53 di firewall ke prefix pelanggan saja. Contoh pf:

```
table <pelanggan> persist { 103.10.20.0/22, 10.10.0.0/16 }
pass in quick on $ext_if proto { tcp udp } from <pelanggan> to ($ext_if) port 53
block in quick on $ext_if proto { tcp udp } to ($ext_if) port 53
```

## Monitoring

`statistics-channels` aktif di `127.0.0.1:8053` dan `zone-statistics yes`.
Pasang exporter lalu scrape dari Prometheus:

```sh
pkg install -y bind_exporter
sysrc bind_exporter_enable="YES"
sysrc bind_exporter_args="-bind.stats-url http://127.0.0.1:8053/ \
    -bind.stats-groups=server,view,tasks"
service bind_exporter start
```

Metrik yang layak dijadikan alert:

- `bind_resolver_query_duration_seconds` naik → upstream bermasalah
- zona `rpz.komdigi.go.id` tidak berubah serial > 24 jam → AXFR mati
- `bind_incoming_queries_total` turun drastis → trafik pelanggan tidak masuk

## Catatan kapasitas

Daftar TrustPositif berisi ratusan ribu sampai jutaan domain. Dengan
`RPZ_WILDCARD=yes` tiap domain jadi 2 record (`domain` + `*.domain`), jadi
1 juta domain ≈ 2 juta record dan memori named bisa 1,5–3 GB **di luar** cache.
Kalau RAM terbatas, jalankan dengan `--no-wildcard` (blokir hanya domain persis)
dan turunkan `--cache-size`. `rndc reload` untuk zona sebesar itu makan puluhan
detik — selama itu named tetap menjawab dari zona versi lama, tidak ada downtime.

Generasi zona fallback pertama kali di akhir instalasi bisa berjalan beberapa
menit. Itu normal.

## Troubleshooting

**Zona AXFR tidak termuat.** Cek `/var/log/named/xfer.log`. Penyebab paling
umum: IP publik resolver belum didaftarkan ke Komdigi, atau TSIG salah.
Selama zona ini tidak ada, tiga zona RPZ lain tetap bekerja — filtering tidak
mati total.

**Unduhan TrustPositif gagal atau isinya kosong.** Updater menolak list yang
berisi kurang dari `TP_MIN_DOMAINS` domain valid (default 50.000) dan
mempertahankan zona lama, jadi kegagalan unduhan tidak pernah membuka blokir.
Lihat `/var/log/named/rpz-update.log`. Kalau URL sumber berubah, ganti `TP_URL`
di `/usr/local/etc/rpz-komdigi.conf`.

**Domain diblokir padahal tidak seharusnya.** `tail /var/log/named/rpz.log`
menunjukkan zona mana yang memicu. Kalau dari zona Komdigi, masukkan ke
whitelist sambil ajukan normalisasi.

**named-checkconf mengeluh zona lokal tidak ada.** Script hanya menulis baris
zona `localhost` / `127.in-addr.arpa` / `0.ip6.arpa` bila file bawaan paket
memang ditemukan di `primary/` atau `master/`, jadi ini seharusnya tidak terjadi.
Kalau tetap muncul, hapus baris terkait di bagian "Zona lokal standar".

**Rollback.** Konfigurasi lama ada di
`/usr/local/etc/namedb/named.conf.bak.<timestamp>`, zona RPZ versi sebelumnya
di `db.rpz-*.prev`.

## Sumber

- [TrustPositif — Komdigi](https://trustpositif.komdigi.go.id/)
- [Daftar domain TrustPositif](https://trustpositif.komdigi.go.id/assets/db/domains)
- [Pengajuan normalisasi](https://trustpositif.komdigi.go.id/normalisasi)
