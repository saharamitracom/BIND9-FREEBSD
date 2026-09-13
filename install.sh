#!/bin/sh
#
# install-bind-rpz-freebsd.sh
#
# Installer BIND9 sebagai recursive resolver pelanggan ISP di FreeBSD,
# dengan DNS filtering RPZ Komdigi/TrustPositif:
#
#   - Sumber utama : zona RPZ via AXFR dari nameserver Komdigi (type secondary)
#   - Fallback     : zona RPZ digenerate lokal dari list domain TrustPositif
#   - Aksi blokir  : CNAME ke landing FQDN lokal yang punya A record ke
#                    webserver milik sendiri
#
# Idempotent: aman dijalankan ulang. Konfigurasi lama dibackup.
#
# Target: FreeBSD 13.x / 14.x / 15.x, paket bind918 / bind920 / bind922.
#
# Pemakaian:
#   ./install-bind-rpz-freebsd.sh --landing-ip=103.x.x.10 \
#       --landing-fqdn=blokir.namaisp.net.id \
#       --listen=103.x.x.2 \
#       --clients=103.x.x.0/22,10.10.0.0/16 \
#       --komdigi-primaries=203.0.113.10,203.0.113.11
#
#   ./install-bind-rpz-freebsd.sh --help
#
set -eu

VERSION="1.0"
PROG="$(basename "$0")"

# ---------------------------------------------------------------------------
# 1. Parameter default  (bisa dioverride lewat flag atau environment)
# ---------------------------------------------------------------------------

# Alamat yang didengarkan named. "auto" = pakai IP interface default route.
LISTEN_V4="${LISTEN_V4:-auto}"
LISTEN_V6="${LISTEN_V6:-}"

# Prefix pelanggan yang boleh rekursi. Pisahkan dengan koma.
CLIENTS="${CLIENTS:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"

# Landing page blokir (WAJIB diisi untuk produksi).
LANDING_FQDN="${LANDING_FQDN:-blokir.internal.lan}"
LANDING_IP4="${LANDING_IP4:-}"
LANDING_IP6="${LANDING_IP6:-}"

# Sumber utama: AXFR RPZ Komdigi. Kosongkan bila belum terdaftar.
# IP nameserver diberikan Komdigi setelah IP publik Anda didaftarkan.
KOMDIGI_PRIMARIES="${KOMDIGI_PRIMARIES:-}"
KOMDIGI_ZONE="${KOMDIGI_ZONE:-rpz.komdigi.go.id}"
KOMDIGI_TSIG_NAME="${KOMDIGI_TSIG_NAME:-}"
KOMDIGI_TSIG_ALGO="${KOMDIGI_TSIG_ALGO:-hmac-sha256}"
KOMDIGI_TSIG_SECRET="${KOMDIGI_TSIG_SECRET:-}"

# Fallback: list domain TrustPositif.
TP_URL="${TP_URL:-https://trustpositif.komdigi.go.id/assets/db/domains}"
TP_MIN_DOMAINS="${TP_MIN_DOMAINS:-50000}"   # guard: tolak list yang mencurigakan kecil
RPZ_WILDCARD="${RPZ_WILDCARD:-yes}"         # blokir subdomain juga (*.domain)
UPDATE_CRON="${UPDATE_CRON:-25 */6 * * *}"  # jadwal refresh fallback

# Tuning resolver.
CACHE_SIZE="${CACHE_SIZE:-50%}"
RECURSIVE_CLIENTS="${RECURSIVE_CLIENTS:-10000}"
STATS_ADDR="${STATS_ADDR:-127.0.0.1}"
STATS_PORT="${STATS_PORT:-8053}"
QUERY_LOG="${QUERY_LOG:-no}"                # yes = catat semua query (berat)
TUNE_SYSCTL="${TUNE_SYSCTL:-yes}"

# Lokasi.
NAMEDB="/usr/local/etc/namedb"
RPZDIR="${NAMEDB}/rpz"
WORKDIR="${NAMEDB}/working"
LOGDIR="/var/log/named"
CONF="/usr/local/etc/rpz-komdigi.conf"
UPDATER="/usr/local/sbin/rpz-komdigi-update"
BIND_USER="bind"
BIND_GROUP="bind"

# ---------------------------------------------------------------------------
# 2. Helper
# ---------------------------------------------------------------------------

msg()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<USAGE
${PROG} v${VERSION} - installer BIND9 + RPZ Komdigi untuk FreeBSD

Opsi:
  --listen=IP[,IP]          Alamat IPv4 yang didengarkan (default: auto)
  --listen6=IP[,IP]         Alamat IPv6 yang didengarkan (default: kosong)
  --clients=CIDR[,CIDR]     Prefix pelanggan yang boleh rekursi
  --landing-ip=IP           A record landing page blokir (wajib)
  --landing-ip6=IP          AAAA record landing page (opsional)
  --landing-fqdn=FQDN       Nama landing page (default: ${LANDING_FQDN})
  --komdigi-primaries=IP[,IP]  Nameserver AXFR Komdigi (kosong = AXFR off)
  --komdigi-zone=NAMA       Nama zona RPZ Komdigi (default: ${KOMDIGI_ZONE})
  --tsig=NAMA:ALGO:SECRET   TSIG untuk AXFR bila diminta Komdigi
  --tp-url=URL              Sumber list TrustPositif (fallback)
  --no-wildcard             Jangan blokir subdomain (*.domain), hemat memori
  --cache-size=N            max-cache-size (default: ${CACHE_SIZE})
  --query-log               Aktifkan logging seluruh query
  --no-sysctl               Lewati tuning sysctl
  --help                    Tampilkan bantuan ini

Contoh:
  ${PROG} --landing-ip=103.10.20.30 --landing-fqdn=blokir.namaisp.net.id \\
          --listen=103.10.20.2 --clients=103.10.20.0/22 \\
          --komdigi-primaries=203.0.113.10,203.0.113.11
USAGE
}

# ---------------------------------------------------------------------------
# 3. Parse argumen
# ---------------------------------------------------------------------------

for arg in "$@"; do
	case "$arg" in
	--listen=*)            LISTEN_V4="${arg#*=}" ;;
	--listen6=*)           LISTEN_V6="${arg#*=}" ;;
	--clients=*)           CLIENTS="${arg#*=}" ;;
	--landing-ip=*)        LANDING_IP4="${arg#*=}" ;;
	--landing-ip6=*)       LANDING_IP6="${arg#*=}" ;;
	--landing-fqdn=*)      LANDING_FQDN="${arg#*=}" ;;
	--komdigi-primaries=*) KOMDIGI_PRIMARIES="${arg#*=}" ;;
	--komdigi-zone=*)      KOMDIGI_ZONE="${arg#*=}" ;;
	--tsig=*)
		_t="${arg#*=}"
		KOMDIGI_TSIG_NAME="${_t%%:*}"
		_r="${_t#*:}"
		KOMDIGI_TSIG_ALGO="${_r%%:*}"
		KOMDIGI_TSIG_SECRET="${_r#*:}"
		;;
	--tp-url=*)            TP_URL="${arg#*=}" ;;
	--no-wildcard)         RPZ_WILDCARD="no" ;;
	--cache-size=*)        CACHE_SIZE="${arg#*=}" ;;
	--query-log)           QUERY_LOG="yes" ;;
	--no-sysctl)           TUNE_SYSCTL="no" ;;
	--help|-h)             usage; exit 0 ;;
	*) die "Opsi tidak dikenal: $arg  (lihat --help)" ;;
	esac
done

# ---------------------------------------------------------------------------
# 4. Preflight
# ---------------------------------------------------------------------------

[ "$(id -u)" = "0" ] || die "Harus dijalankan sebagai root."
[ "$(uname -s)" = "FreeBSD" ] || die "Script ini khusus FreeBSD (terdeteksi: $(uname -s))."

msg "FreeBSD $(freebsd-version 2>/dev/null || uname -r) terdeteksi"

if [ -z "$LANDING_IP4" ]; then
	warn "--landing-ip belum diisi. Landing page akan diarahkan ke 127.0.0.1"
	warn "Isi nanti di ${RPZDIR}/db.landing lalu: rndc reload ${LANDING_FQDN}"
	LANDING_IP4="127.0.0.1"
fi

case "$LANDING_FQDN" in
*.*) : ;;
*)   die "--landing-fqdn harus FQDN (mis. blokir.namaisp.net.id), bukan '${LANDING_FQDN}'" ;;
esac

if [ "$LISTEN_V4" = "auto" ]; then
	_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
	[ -n "$_if" ] || die "Tidak ada default route; tentukan --listen=IP secara eksplisit."
	LISTEN_V4="$(ifconfig "$_if" inet 2>/dev/null | awk '/inet /{print $2; exit}')"
	[ -n "$LISTEN_V4" ] || die "Gagal mendeteksi IPv4 di $_if; pakai --listen=IP."
	msg "IP listen terdeteksi otomatis: ${LISTEN_V4} (${_if})"
fi

# Ubah "a,b,c" menjadi baris-baris konfigurasi "a; b; c;"
to_acl() {
	echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
	           | grep -v '^$' | sed 's/$/;/' | sed 's/^/\t\t/'
}

ACL_CLIENTS="$(to_acl "$CLIENTS")"
ACL_LISTEN4="$(to_acl "$LISTEN_V4")"
[ -n "$LISTEN_V6" ] && ACL_LISTEN6="$(to_acl "$LISTEN_V6")" || ACL_LISTEN6=""

# ---------------------------------------------------------------------------
# 5. Instalasi paket
# ---------------------------------------------------------------------------

msg "Memastikan repo pkg siap"
pkg update -q || warn "pkg update gagal, lanjut dengan katalog yang ada"

BIND_PKG=""
if pkg info -q bind922 2>/dev/null; then BIND_PKG="bind922"
elif pkg info -q bind920 2>/dev/null; then BIND_PKG="bind920"
elif pkg info -q bind918 2>/dev/null; then BIND_PKG="bind918"
else
	for p in bind922 bind920 bind918; do
		if pkg rquery %n "$p" >/dev/null 2>&1; then BIND_PKG="$p"; break; fi
	done
	[ -n "$BIND_PKG" ] || die "Tidak menemukan paket bind9xx di repo. Cek: pkg search bind9"
	msg "Menginstal ${BIND_PKG}"
	pkg install -y "$BIND_PKG"
fi
msg "Paket BIND: ${BIND_PKG} ($(named -v 2>/dev/null || echo '?'))"

# ---------------------------------------------------------------------------
# 6. Struktur direktori
# ---------------------------------------------------------------------------

msg "Menyiapkan direktori"
for d in "$NAMEDB" "$RPZDIR" "$WORKDIR" "${WORKDIR}/slave" "$LOGDIR"; do
	[ -d "$d" ] || mkdir -p "$d"
done
chown -R "${BIND_USER}:${BIND_GROUP}" "$RPZDIR" "$WORKDIR" "$LOGDIR"
chmod 0750 "$RPZDIR" "$WORKDIR" "${WORKDIR}/slave" "$LOGDIR"

# rndc key
if [ ! -f "${NAMEDB}/rndc.key" ]; then
	msg "Membuat rndc.key"
	rndc-confgen -a -u "$BIND_USER" -c "${NAMEDB}/rndc.key" >/dev/null 2>&1 || \
		die "Gagal membuat rndc.key"
fi
chown "${BIND_USER}:${BIND_GROUP}" "${NAMEDB}/rndc.key"
chmod 0640 "${NAMEDB}/rndc.key"

# ---------------------------------------------------------------------------
# 7. Backup konfigurasi lama
# ---------------------------------------------------------------------------

STAMP="$(date +%Y%m%d%H%M%S)"
if [ -f "${NAMEDB}/named.conf" ]; then
	cp -p "${NAMEDB}/named.conf" "${NAMEDB}/named.conf.bak.${STAMP}"
	msg "named.conf lama dibackup ke named.conf.bak.${STAMP}"
fi

# ---------------------------------------------------------------------------
# 8. Zona lokal: landing page, whitelist, blacklist, seed RPZ
# ---------------------------------------------------------------------------

SERIAL="$(date +%s)"

msg "Menulis zona landing page (${LANDING_FQDN} -> ${LANDING_IP4})"
{
	cat <<LANDEOF
\$TTL 300
@	IN	SOA	${LANDING_FQDN}. hostmaster.${LANDING_FQDN}. (
			${SERIAL}	; serial
			3600		; refresh
			900		; retry
			604800		; expire
			300 )		; negative TTL
	IN	NS	${LANDING_FQDN}.
@	IN	A	${LANDING_IP4}
*	IN	A	${LANDING_IP4}
LANDEOF
	if [ -n "$LANDING_IP6" ]; then
		printf '@\tIN\tAAAA\t%s\n*\tIN\tAAAA\t%s\n' "$LANDING_IP6" "$LANDING_IP6"
	fi
} > "${RPZDIR}/db.landing"

# Daftar teks yang diedit operator
[ -f "${RPZDIR}/whitelist.txt" ] || cat > "${RPZDIR}/whitelist.txt" <<'WLEOF'
# Domain yang TIDAK boleh diblokir (passthru), satu domain per baris.
# Dipakai untuk dua hal:
#   1. dikecualikan dari zona fallback TrustPositif
#   2. jadi zona RPZ passthru yang dievaluasi PALING AWAL,
#      sehingga menang atas zona Komdigi
# Contoh:
# portal.pemkot-xyz.go.id
WLEOF

[ -f "${RPZDIR}/blacklist.txt" ] || cat > "${RPZDIR}/blacklist.txt" <<'BLEOF'
# Blokir tambahan di luar daftar Komdigi (mis. permintaan aparat lokal,
# domain phishing yang menyerang pelanggan). Satu domain per baris.
# Contoh:
# phishing-bank-palsu.tk
BLEOF

# Seed zona RPZ lokal (akan ditimpa updater)
seed_rpz() {
	_zone="$1"; _file="$2"
	[ -f "$_file" ] && return 0
	cat > "$_file" <<SEEDEOF
\$TTL 60
@	IN	SOA	localhost. root.localhost. ( 1 3600 900 604800 60 )
	IN	NS	localhost.
SEEDEOF
}

seed_rpz "rpz-whitelist.local"    "${RPZDIR}/db.rpz-whitelist"
seed_rpz "rpz-blacklist.local"    "${RPZDIR}/db.rpz-blacklist"
seed_rpz "rpz-trustpositif.local" "${RPZDIR}/db.rpz-trustpositif"

# Seed file zona secondary Komdigi supaya named tetap start walau AXFR
# belum jalan (serial 1, akan langsung ditimpa transfer pertama).
if [ -n "$KOMDIGI_PRIMARIES" ] && [ ! -f "${WORKDIR}/slave/db.rpz-komdigi" ]; then
	cat > "${WORKDIR}/slave/db.rpz-komdigi" <<SEEDEOF
\$TTL 60
@	IN	SOA	localhost. root.localhost. ( 1 3600 900 604800 60 )
	IN	NS	localhost.
SEEDEOF
fi

chown -R "${BIND_USER}:${BIND_GROUP}" "$RPZDIR" "${WORKDIR}"

# ---------------------------------------------------------------------------
# 9. named.conf
# ---------------------------------------------------------------------------

# Root hints: pakai milik paket kalau ada, kalau tidak unduh dari InterNIC.
if [ ! -f "${NAMEDB}/named.root" ]; then
	msg "Mengunduh root hints"
	fetch -q -T 30 -o "${NAMEDB}/named.root" https://www.internic.net/domain/named.root \
		|| warn "Gagal unduh named.root - BIND akan memakai root hints bawaan"
fi

LOCAL_ZONES=""
if [ -f "${NAMEDB}/named.root" ]; then
	LOCAL_ZONES="zone \".\" { type hint; file \"${NAMEDB}/named.root\"; };
"
fi
# Paket bind9xx memakai primary/ (versi baru) atau master/ (versi lama).
for _d in primary master; do
	if [ -f "${NAMEDB}/${_d}/localhost-forward.db" ]; then
		LOCAL_ZONES="${LOCAL_ZONES}zone \"localhost\"        { type primary; file \"${NAMEDB}/${_d}/localhost-forward.db\"; };
"
	fi
	if [ -f "${NAMEDB}/${_d}/localhost-reverse.db" ]; then
		LOCAL_ZONES="${LOCAL_ZONES}zone \"127.in-addr.arpa\" { type primary; file \"${NAMEDB}/${_d}/localhost-reverse.db\"; };
"
	fi
	if [ -f "${NAMEDB}/${_d}/empty.db" ]; then
		LOCAL_ZONES="${LOCAL_ZONES}zone \"0.ip6.arpa\"       { type primary; file \"${NAMEDB}/${_d}/empty.db\"; };
"
	fi
done
[ -n "$LOCAL_ZONES" ] || LOCAL_ZONES="// (tidak ada zona lokal bawaan paket yang ditemukan)"

msg "Menulis ${NAMEDB}/named.conf"

# Blok TSIG (opsional)
TSIG_BLOCK=""
TSIG_REF=""
if [ -n "$KOMDIGI_TSIG_NAME" ] && [ -n "$KOMDIGI_TSIG_SECRET" ]; then
	TSIG_BLOCK="key \"${KOMDIGI_TSIG_NAME}\" {
	algorithm ${KOMDIGI_TSIG_ALGO};
	secret \"${KOMDIGI_TSIG_SECRET}\";
};
"
	TSIG_REF=" key ${KOMDIGI_TSIG_NAME}"
fi

# Daftar primaries untuk zona secondary.
# PRIMARIES_LIST boleh membawa "key ..." (valid di blok primaries),
# PRIMARIES_PLAIN untuk address_match_list seperti allow-notify (tidak boleh key).
PRIMARIES_LIST=""
PRIMARIES_PLAIN=""
if [ -n "$KOMDIGI_PRIMARIES" ]; then
	PRIMARIES_PLAIN="$(echo "$KOMDIGI_PRIMARIES" | tr ',' '\n' | grep -v '^$' \
		| sed 's/$/;/' | sed 's/^/\t\t/')"
	PRIMARIES_LIST="$(echo "$KOMDIGI_PRIMARIES" | tr ',' '\n' | grep -v '^$' \
		| sed "s/\$/${TSIG_REF};/" | sed 's/^/\t\t/')"
fi

# Urutan response-policy menentukan pemenang: whitelist dulu, lalu blacklist
# lokal, lalu Komdigi (AXFR), terakhir fallback TrustPositif.
RP_KOMDIGI=""
ZONE_KOMDIGI=""
if [ -n "$KOMDIGI_PRIMARIES" ]; then
	RP_KOMDIGI="		zone \"${KOMDIGI_ZONE}\" policy cname ${LANDING_FQDN}.;
"
	ZONE_KOMDIGI="zone \"${KOMDIGI_ZONE}\" {
	type secondary;
	primaries {
${PRIMARIES_LIST}
	};
	file \"${WORKDIR}/slave/db.rpz-komdigi\";
	allow-query { localhost; };
	allow-transfer { none; };
	allow-notify {
${PRIMARIES_PLAIN}
	};
	max-transfer-time-in 60;
	check-names ignore;
};
"
fi

QUERYLOG_CHANNEL=""
if [ "$QUERY_LOG" = "yes" ]; then
	QUERYLOG_CHANNEL="	category queries { querylog; };
"
fi

cat > "${NAMEDB}/named.conf" <<NCEOF
//
// named.conf - recursive resolver pelanggan ISP + RPZ Komdigi
// Digenerate oleh ${PROG} v${VERSION} pada $(date '+%Y-%m-%d %H:%M:%S %Z')
// JANGAN diedit manual tanpa mencatatnya; script ini menimpa file ini.
//

acl "pelanggan" {
		localhost;
		localnets;
${ACL_CLIENTS}
};

acl "admin" {
		127.0.0.1;
		::1;
};

${TSIG_BLOCK}
options {
	directory		"${WORKDIR}";
	pid-file		"/var/run/named/pid";
	dump-file		"/var/dump/named_dump.db";
	statistics-file		"/var/stats/named.stats";
	session-keyfile		"/var/run/named/session.key";

	// ---- Listener -------------------------------------------------
	listen-on port 53 {
		127.0.0.1;
${ACL_LISTEN4}
	};
$(if [ -n "$ACL_LISTEN6" ]; then
	printf '\tlisten-on-v6 port 53 {\n\t\t::1;\n%s\n\t};\n' "$ACL_LISTEN6"
else
	printf '\tlisten-on-v6 { ::1; };\n'
fi)

	// ---- Kontrol akses --------------------------------------------
	recursion yes;
	allow-query		{ pelanggan; };
	allow-query-cache	{ pelanggan; };
	allow-recursion		{ pelanggan; };
	allow-transfer		{ none; };
	allow-update		{ none; };
	version			"DNS";
	hostname		none;
	server-id		none;

	// ---- Validasi & privasi ---------------------------------------
	dnssec-validation	auto;
	minimal-responses	yes;
	querylog		$( [ "$QUERY_LOG" = "yes" ] && echo yes || echo no );

	// ---- Cache & performa untuk trafik pelanggan ------------------
	max-cache-size		${CACHE_SIZE};
	max-cache-ttl		86400;
	max-ncache-ttl		3600;
	prefetch		2 9;
	recursive-clients	${RECURSIVE_CLIENTS};
	tcp-clients		1000;
	clients-per-query	10;
	max-clients-per-query	100;
	fetches-per-zone	200 drop;
	fetches-per-server	200 drop;

	// Serve-stale: pelanggan tetap dapat jawaban saat upstream ngadat
	stale-answer-enable	yes;
	stale-answer-ttl	30;
	max-stale-ttl		86400;
	stale-cache-enable	yes;

	zone-statistics		yes;

	// ---- Response Policy Zone -------------------------------------
	// Urutan = prioritas. Zona pertama yang cocok yang dipakai.
	response-policy {
		zone "rpz-whitelist.local"    policy passthru;
		zone "rpz-blacklist.local"    policy cname ${LANDING_FQDN}.;
${RP_KOMDIGI}		zone "rpz-trustpositif.local" policy cname ${LANDING_FQDN}.;
	}
	qname-wait-recurse no
	nsip-enable no
	nsdname-enable no
	break-dnssec yes
	max-policy-ttl 60
	recursive-only yes;
};

// ---- Logging ----------------------------------------------------------
logging {
	channel "default_log" {
		file "${LOGDIR}/named.log" versions 7 size 50m;
		severity info;
		print-time yes;
		print-severity yes;
		print-category yes;
	};
	channel "rpz_log" {
		file "${LOGDIR}/rpz.log" versions 7 size 100m;
		severity info;
		print-time yes;
	};
	channel "security_log" {
		file "${LOGDIR}/security.log" versions 7 size 20m;
		severity info;
		print-time yes;
	};
	channel "xfer_log" {
		file "${LOGDIR}/xfer.log" versions 5 size 20m;
		severity info;
		print-time yes;
	};
	channel "querylog" {
		file "${LOGDIR}/query.log" versions 5 size 200m;
		severity info;
		print-time yes;
	};

	category default		{ default_log; };
	category general		{ default_log; };
	category rpz			{ rpz_log; };
	category security		{ security_log; };
	category xfer-in		{ xfer_log; };
	category xfer-out		{ xfer_log; };
	category notify			{ xfer_log; };
	category resolver		{ default_log; };
	category rate-limit		{ security_log; };
	category lame-servers		{ null; };
	category edns-disabled		{ null; };
${QUERYLOG_CHANNEL}};

// ---- Statistik untuk Prometheus bind_exporter -------------------------
statistics-channels {
	inet ${STATS_ADDR} port ${STATS_PORT} allow { ${STATS_ADDR}; };
};

// ---- rndc -------------------------------------------------------------
include "${NAMEDB}/rndc.key";
controls {
	inet 127.0.0.1 port 953 allow { admin; } keys { "rndc-key"; };
};

// ---- Zona landing page blokir -----------------------------------------
// Target CNAME dari semua policy di atas. Wajib resolvable dari resolver ini.
zone "${LANDING_FQDN}" {
	type primary;
	file "${RPZDIR}/db.landing";
	allow-query { any; };
	allow-transfer { none; };
	notify no;
};

// ---- Zona RPZ ---------------------------------------------------------
zone "rpz-whitelist.local" {
	type primary;
	file "${RPZDIR}/db.rpz-whitelist";
	allow-query { localhost; };
	allow-transfer { none; };
	notify no;
	check-names ignore;
};

zone "rpz-blacklist.local" {
	type primary;
	file "${RPZDIR}/db.rpz-blacklist";
	allow-query { localhost; };
	allow-transfer { none; };
	notify no;
	check-names ignore;
};

${ZONE_KOMDIGI}
zone "rpz-trustpositif.local" {
	type primary;
	file "${RPZDIR}/db.rpz-trustpositif";
	allow-query { localhost; };
	allow-transfer { none; };
	notify no;
	check-names ignore;
};

// ---- Zona lokal standar ------------------------------------------------
${LOCAL_ZONES}
NCEOF

chown "${BIND_USER}:${BIND_GROUP}" "${NAMEDB}/named.conf"
chmod 0640 "${NAMEDB}/named.conf"

# ---------------------------------------------------------------------------
# 10. File konfigurasi untuk updater
# ---------------------------------------------------------------------------

msg "Menulis ${CONF}"
cat > "$CONF" <<CFGEOF
# Konfigurasi rpz-komdigi-update. Diedit bebas, tidak ditimpa installer
# kecuali installer dijalankan ulang.

TP_URL="${TP_URL}"
TP_MIN_DOMAINS="${TP_MIN_DOMAINS}"
RPZ_WILDCARD="${RPZ_WILDCARD}"

RPZDIR="${RPZDIR}"
LANDING_FQDN="${LANDING_FQDN}"
BIND_USER="${BIND_USER}"
BIND_GROUP="${BIND_GROUP}"

# Zona AXFR Komdigi yang dipantau kesegarannya (kosong = tidak dipantau)
KOMDIGI_ZONE="${KOMDIGI_PRIMARIES:+${KOMDIGI_ZONE}}"
# Umur maksimal zona AXFR sebelum dianggap basi (detik). Default 24 jam.
KOMDIGI_MAX_AGE="86400"

LOGFILE="${LOGDIR}/rpz-update.log"
CFGEOF
chmod 0640 "$CONF"

# ---------------------------------------------------------------------------
# 11. Script updater fallback
# ---------------------------------------------------------------------------

msg "Menulis ${UPDATER}"
cat > "$UPDATER" <<'UPDEOF'
#!/bin/sh
#
# rpz-komdigi-update - regenerasi zona RPZ fallback TrustPositif serta
# zona whitelist/blacklist lokal, lalu reload zona di BIND tanpa restart.
#
# Pemakaian:
#   rpz-komdigi-update              # unduh list + regenerate semua zona
#   rpz-komdigi-update --local-only # hanya whitelist/blacklist, tanpa unduh
#   rpz-komdigi-update --check      # laporkan status AXFR & umur zona
#
set -eu
export LC_ALL=C   # konsisten untuk sort/comm

CONF="/usr/local/etc/rpz-komdigi.conf"
[ -f "$CONF" ] || { echo "Konfigurasi $CONF tidak ditemukan" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${RPZDIR:?}" "${LANDING_FQDN:?}" "${LOGFILE:=/var/log/named/rpz-update.log}"
: "${TP_MIN_DOMAINS:=50000}" "${RPZ_WILDCARD:=yes}"
: "${BIND_USER:=bind}" "${BIND_GROUP:=bind}"
: "${KOMDIGI_ZONE:=}" "${KOMDIGI_MAX_AGE:=86400}"

MODE="full"
case "${1:-}" in
--local-only) MODE="local" ;;
--check)      MODE="check" ;;
"")           : ;;
*) echo "Opsi tidak dikenal: $1" >&2; exit 1 ;;
esac

TMPDIR_RPZ="$(mktemp -d /tmp/rpz.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RPZ"' EXIT INT TERM

log() {
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"
	[ -t 1 ] && printf '%s\n' "$*" || true
}

# --- Normalisasi daftar domain mentah -> satu domain per baris, unik -------
normalize() {
	tr -d '\r' \
	| tr 'A-Z' 'a-z' \
	| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
	| sed 's/^\.//; s/\.$//' \
	| grep -v '^[#;]' \
	| grep -v '^$' \
	| awk '{print $NF}' \
	| grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' \
	| sort -u
}

# --- Generate file zona RPZ dari daftar domain -----------------------------
# $1 = file daftar, $2 = file zona keluaran, $3 = aksi (cname|passthru)
gen_zone() {
	_list="$1"; _out="$2"; _action="$3"
	_serial="$(date +%s)"

	if [ "$_action" = "passthru" ]; then
		_rdata="rpz-passthru."
	else
		_rdata="${LANDING_FQDN}."
	fi

	{
		printf '$TTL 60\n'
		printf '@\tIN\tSOA\tlocalhost. root.localhost. ( %s 3600 900 604800 60 )\n' "$_serial"
		printf '\tIN\tNS\tlocalhost.\n'
		awk -v rd="$_rdata" -v wc="$RPZ_WILDCARD" '
			{
				print $0 "\tCNAME\t" rd
				if (wc == "yes") print "*." $0 "\tCNAME\t" rd
			}' "$_list"
	} > "$_out"
}

# --- Instal zona secara atomik setelah lolos named-checkzone ---------------
install_zone() {
	_zone="$1"; _new="$2"; _dst="$3"
	if ! named-checkzone -q "$_zone" "$_new" >/dev/null 2>&1; then
		log "GAGAL: named-checkzone menolak zona ${_zone}, zona lama dipertahankan"
		named-checkzone "$_zone" "$_new" 2>&1 | head -20 >> "$LOGFILE"
		return 1
	fi
	if [ -f "$_dst" ]; then cp -p "$_dst" "${_dst}.prev"; fi
	install -o "$BIND_USER" -g "$BIND_GROUP" -m 0640 "$_new" "$_dst"
	_n="$(grep -c 'CNAME' "$_dst" 2>/dev/null || true)"
	if rndc reload "$_zone" >/dev/null 2>&1; then
		log "OK: zona ${_zone} direload (${_n} record)"
	else
		log "PERINGATAN: rndc reload ${_zone} gagal (named mati?)"
		return 1
	fi
	return 0
}

# --- Mode --check ----------------------------------------------------------
if [ "$MODE" = "check" ]; then
	if [ -n "$KOMDIGI_ZONE" ]; then
		_st="$(rndc zonestatus "$KOMDIGI_ZONE" 2>/dev/null || true)"
		if [ -n "$_st" ]; then
			echo "--- Zona AXFR Komdigi: ${KOMDIGI_ZONE}"
			echo "$_st" | grep -E 'serial|refresh|expire|loaded|transfer' || true
		else
			echo "Zona ${KOMDIGI_ZONE} tidak terbaca dari rndc."
		fi
	else
		echo "AXFR Komdigi tidak dikonfigurasi."
	fi
	echo "--- Zona fallback TrustPositif"
	if [ -f "${RPZDIR}/db.rpz-trustpositif" ]; then
		echo "  record : $(grep -c 'CNAME' "${RPZDIR}/db.rpz-trustpositif")"
		echo "  update : $(date -r "$(stat -f %m "${RPZDIR}/db.rpz-trustpositif")" '+%Y-%m-%d %H:%M:%S')"
	else
		echo "  belum pernah digenerate"
	fi
	exit 0
fi

# --- Whitelist & blacklist lokal -------------------------------------------
: > "${TMPDIR_RPZ}/wl"
if [ -f "${RPZDIR}/whitelist.txt" ]; then
	normalize < "${RPZDIR}/whitelist.txt" > "${TMPDIR_RPZ}/wl" || true
fi
gen_zone "${TMPDIR_RPZ}/wl" "${TMPDIR_RPZ}/z.wl" passthru
install_zone "rpz-whitelist.local" "${TMPDIR_RPZ}/z.wl" "${RPZDIR}/db.rpz-whitelist" || true

: > "${TMPDIR_RPZ}/bl"
if [ -f "${RPZDIR}/blacklist.txt" ]; then
	normalize < "${RPZDIR}/blacklist.txt" > "${TMPDIR_RPZ}/bl" || true
fi
gen_zone "${TMPDIR_RPZ}/bl" "${TMPDIR_RPZ}/z.bl" cname
install_zone "rpz-blacklist.local" "${TMPDIR_RPZ}/z.bl" "${RPZDIR}/db.rpz-blacklist" || true

if [ "$MODE" = "local" ]; then
	log "Mode --local-only selesai"
	exit 0
fi

# --- Unduh list TrustPositif ------------------------------------------------
log "Mengunduh daftar TrustPositif dari ${TP_URL}"
if ! fetch -q -T 120 -o "${TMPDIR_RPZ}/raw" "$TP_URL"; then
	log "GAGAL: unduhan dari ${TP_URL} tidak berhasil, zona fallback lama dipertahankan"
	exit 1
fi

normalize < "${TMPDIR_RPZ}/raw" > "${TMPDIR_RPZ}/tp.all"
COUNT="$(wc -l < "${TMPDIR_RPZ}/tp.all" | tr -d ' ')"

if [ "$COUNT" -lt "$TP_MIN_DOMAINS" ]; then
	log "GAGAL: hanya ${COUNT} domain valid (minimum ${TP_MIN_DOMAINS}). Dianggap unduhan rusak, dibatalkan."
	exit 1
fi

# Buang domain yang ada di whitelist
if [ -s "${TMPDIR_RPZ}/wl" ]; then
	comm -23 "${TMPDIR_RPZ}/tp.all" "${TMPDIR_RPZ}/wl" > "${TMPDIR_RPZ}/tp"
else
	cp "${TMPDIR_RPZ}/tp.all" "${TMPDIR_RPZ}/tp"
fi
FINAL="$(wc -l < "${TMPDIR_RPZ}/tp" | tr -d ' ')"
log "Daftar TrustPositif: ${COUNT} domain valid, ${FINAL} setelah whitelist"

gen_zone "${TMPDIR_RPZ}/tp" "${TMPDIR_RPZ}/z.tp" cname
install_zone "rpz-trustpositif.local" "${TMPDIR_RPZ}/z.tp" "${RPZDIR}/db.rpz-trustpositif"

# --- Pantau kesegaran zona AXFR --------------------------------------------
if [ -n "$KOMDIGI_ZONE" ]; then
	_loaded="$(rndc zonestatus "$KOMDIGI_ZONE" 2>/dev/null | awk -F': ' '/loaded serial/{print $2}')"
	if [ -z "$_loaded" ]; then
		log "PERINGATAN: zona AXFR ${KOMDIGI_ZONE} tidak termuat. Filtering bertumpu pada fallback TrustPositif."
	else
		log "Zona AXFR ${KOMDIGI_ZONE} aktif, serial ${_loaded}"
	fi
fi

log "Selesai."
UPDEOF

chmod 0750 "$UPDATER"

# ---------------------------------------------------------------------------
# 12. Cron + rotasi log
# ---------------------------------------------------------------------------

msg "Memasang jadwal cron"
CRONMARK="# rpz-komdigi-update (dikelola ${PROG})"
if ! grep -Fq "$CRONMARK" /etc/crontab 2>/dev/null; then
	{
		printf '\n%s\n' "$CRONMARK"
		printf '%s\troot\t%s >/dev/null 2>&1\n' "$UPDATE_CRON" "$UPDATER"
	} >> /etc/crontab
	msg "Baris cron ditambahkan ke /etc/crontab (${UPDATE_CRON})"
else
	msg "Baris cron sudah ada, dilewati"
fi

mkdir -p /usr/local/etc/newsyslog.conf.d
cat > /usr/local/etc/newsyslog.conf.d/rpz-komdigi.conf <<NSEOF
# logfile			owner:group	mode count size when flags
${LOGDIR}/rpz-update.log	${BIND_USER}:${BIND_GROUP}	640  7     1000 *    JC
NSEOF
touch "${LOGDIR}/rpz-update.log"
chown "${BIND_USER}:${BIND_GROUP}" "${LOGDIR}/rpz-update.log"

# ---------------------------------------------------------------------------
# 13. Tuning sysctl (opsional)
# ---------------------------------------------------------------------------

if [ "$TUNE_SYSCTL" = "yes" ]; then
	msg "Menerapkan tuning sysctl untuk resolver bervolume tinggi"
	SYSMARK="# tuning DNS resolver (dikelola ${PROG})"
	if ! grep -Fq "$SYSMARK" /etc/sysctl.conf 2>/dev/null; then
		cat >> /etc/sysctl.conf <<SYSEOF

${SYSMARK}
kern.ipc.maxsockbuf=16777216
net.inet.udp.recvspace=1048576
net.inet.udp.maxdgram=57344
net.inet.ip.portrange.randomized=1
net.inet.ip.portrange.first=1024
net.inet.ip.portrange.last=65535
SYSEOF
	fi
	sysctl kern.ipc.maxsockbuf=16777216 >/dev/null 2>&1 || true
	sysctl net.inet.udp.recvspace=1048576 >/dev/null 2>&1 || true
	sysctl net.inet.ip.portrange.first=1024 >/dev/null 2>&1 || true
	sysctl net.inet.ip.portrange.last=65535 >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 14. rc.conf + validasi + start
# ---------------------------------------------------------------------------

msg "Mengatur rc.conf"
sysrc named_enable="YES" >/dev/null
sysrc named_conf="${NAMEDB}/named.conf" >/dev/null
sysrc named_chrootdir="" >/dev/null
sysrc named_uid="${BIND_USER}" >/dev/null

msg "Validasi named.conf"
if ! named-checkconf "${NAMEDB}/named.conf"; then
	die "named.conf tidak valid. Konfigurasi lama ada di ${NAMEDB}/named.conf.bak.${STAMP}"
fi
msg "named.conf valid"

msg "Generate zona RPZ pertama kali (bisa beberapa menit untuk list besar)"
"$UPDATER" || warn "Generasi awal gagal - named tetap start dengan zona kosong. Cek ${LOGDIR}/rpz-update.log"

if service named status >/dev/null 2>&1; then
	msg "Reload named"
	service named reload || service named restart
else
	msg "Menjalankan named"
	service named start
fi

sleep 3

# ---------------------------------------------------------------------------
# 15. Verifikasi
# ---------------------------------------------------------------------------

echo
msg "=== Verifikasi ==="

printf '  named berjalan      : '
service named status >/dev/null 2>&1 && echo "ya" || echo "TIDAK - cek ${LOGDIR}/named.log"

printf '  resolusi normal     : '
if dig +short +time=3 +tries=1 @127.0.0.1 www.freebsd.org A >/dev/null 2>&1; then
	echo "ok"
else
	echo "GAGAL"
fi

printf '  landing page        : '
_land="$(dig +short +time=3 +tries=1 @127.0.0.1 "${LANDING_FQDN}" A 2>/dev/null | head -1)"
[ -n "$_land" ] && echo "${LANDING_FQDN} -> ${_land}" || echo "GAGAL resolve"

printf '  uji domain diblokir : '
_sample="$(grep -m1 -E '^[a-z0-9]' "${RPZDIR}/db.rpz-trustpositif" 2>/dev/null | awk '{print $1}')"
if [ -n "$_sample" ]; then
	_res="$(dig +short +time=3 +tries=1 @127.0.0.1 "$_sample" A 2>/dev/null | tail -1)"
	if [ "$_res" = "$LANDING_IP4" ]; then
		echo "ok (${_sample} -> ${_res})"
	else
		echo "PERIKSA (${_sample} -> ${_res:-kosong}, harusnya ${LANDING_IP4})"
	fi
else
	echo "lewati (zona fallback kosong)"
fi

if [ -n "$KOMDIGI_PRIMARIES" ]; then
	printf '  zona AXFR Komdigi   : '
	_ser="$(rndc zonestatus "${KOMDIGI_ZONE}" 2>/dev/null | awk -F': ' '/loaded serial/{print $2}')"
	if [ -n "$_ser" ] && [ "$_ser" != "1" ]; then
		echo "termuat, serial ${_ser}"
	else
		echo "belum termuat - cek ${LOGDIR}/xfer.log dan pastikan IP publik server sudah didaftarkan ke Komdigi"
	fi
fi

printf '  statistik           : http://%s:%s/ (untuk bind_exporter)\n' "$STATS_ADDR" "$STATS_PORT"

cat <<SUMMARY

==============================================================================
 Selesai.

 Konfigurasi   : ${NAMEDB}/named.conf
 Zona RPZ      : ${RPZDIR}/
 Whitelist     : ${RPZDIR}/whitelist.txt   (edit, lalu: ${UPDATER} --local-only)
 Blacklist     : ${RPZDIR}/blacklist.txt   (idem)
 Landing zone  : ${RPZDIR}/db.landing      (A ${LANDING_IP4})
 Updater       : ${UPDATER}
 Setting       : ${CONF}
 Log           : ${LOGDIR}/

 Perintah harian:
   ${UPDATER}                 # refresh fallback TrustPositif
   ${UPDATER} --check         # status AXFR & umur zona fallback
   rndc zonestatus rpz-trustpositif.local
   tail -f ${LOGDIR}/rpz.log  # lihat domain yang kena blokir

 Langkah berikutnya:
   1. Buka port 53/udp + 53/tcp hanya untuk prefix pelanggan di pf/ipfw.
   2. Pastikan ${LANDING_FQDN} melayani HTTP/HTTPS di ${LANDING_IP4}.
   3. Daftarkan IP publik resolver ini ke Komdigi agar AXFR diizinkan.
   4. Pasang net-mgmt/bind_exporter, arahkan ke ${STATS_ADDR}:${STATS_PORT}.
==============================================================================
SUMMARY
