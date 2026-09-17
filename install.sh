#!/bin/sh
#
# install-bind-rpz-freebsd.sh
#
# Installer BIND9 sebagai recursive resolver pelanggan ISP di FreeBSD,
# dengan DNS filtering RPZ Komdigi/TrustPositif & Custom SafeSearch.
#
# Idempotent: aman dijalankan ulang. Konfigurasi lama dibackup.
# Target: FreeBSD 13.x / 14.x / 15.x, paket bind918 / bind920 / bind922.
#
set -eu

VERSION="1.2"
PROG="$(basename "$0")"

# ---------------------------------------------------------------------------
# 1. Parameter default
# ---------------------------------------------------------------------------

LISTEN_V4="${LISTEN_V4:-auto}"
LISTEN_V6="${LISTEN_V6:-}"
CLIENTS="${CLIENTS:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
LANDING_FQDN="${LANDING_FQDN:-blokir.internal.lan}"
LANDING_IP4="${LANDING_IP4:-}"
LANDING_IP6="${LANDING_IP6:-}"
KOMDIGI_PRIMARIES="${KOMDIGI_PRIMARIES:-}"
KOMDIGI_ZONE="${KOMDIGI_ZONE:-rpz.komdigi.go.id}"
KOMDIGI_TSIG_NAME="${KOMDIGI_TSIG_NAME:-}"
KOMDIGI_TSIG_ALGO="${KOMDIGI_TSIG_ALGO:-hmac-sha256}"
KOMDIGI_TSIG_SECRET="${KOMDIGI_TSIG_SECRET:-}"
TP_URL="${TP_URL:-https://trustpositif.komdigi.go.id/assets/db/domains}"
TP_MIN_DOMAINS="${TP_MIN_DOMAINS:-50000}"
RPZ_WILDCARD="${RPZ_WILDCARD:-yes}"
UPDATE_CRON="${UPDATE_CRON:-25 */6 * * *}"
CACHE_SIZE="${CACHE_SIZE:-50%}"
RECURSIVE_CLIENTS="${RECURSIVE_CLIENTS:-10000}"
STATS_ADDR="${STATS_ADDR:-127.0.0.1}"
STATS_PORT="${STATS_PORT:-8053}"
QUERY_LOG="${QUERY_LOG:-no}"
TUNE_SYSCTL="${TUNE_SYSCTL:-yes}"

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
USAGE
}

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
# 3. Preflight & Instalasi
# ---------------------------------------------------------------------------

[ "$(id -u)" = "0" ] || die "Harus dijalankan sebagai root."
[ "$(uname -s)" = "FreeBSD" ] || die "Script ini khusus FreeBSD."

if [ -z "$LANDING_IP4" ]; then
	warn "--landing-ip belum diisi. Landing page diarahkan ke 127.0.0.1"
	LANDING_IP4="127.0.0.1"
fi

if [ "$LISTEN_V4" = "auto" ]; then
	_if="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
	[ -n "$_if" ] || die "Tidak ada default route; tentukan --listen=IP secara eksplisit."
	LISTEN_V4="$(ifconfig "$_if" inet 2>/dev/null | awk '/inet /{print $2; exit}')"
	[ -n "$LISTEN_V4" ] || die "Gagal mendeteksi IPv4 di $_if; pakai --listen=IP."
	msg "IP listen terdeteksi otomatis: ${LISTEN_V4} (${_if})"
fi

to_acl() {
	echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
	           | grep -v '^$' | sed 's/$/;/' | sed 's/^/\t\t/'
}

ACL_CLIENTS="$(to_acl "$CLIENTS")"
ACL_LISTEN4="$(to_acl "$LISTEN_V4")"
[ -n "$LISTEN_V6" ] && ACL_LISTEN6="$(to_acl "$LISTEN_V6")" || ACL_LISTEN6=""

msg "Memastikan repo pkg siap"
pkg update -q || true

BIND_PKG=""
for p in bind922 bind920 bind918; do
	if pkg rquery %n "$p" >/dev/null 2>&1; then BIND_PKG="$p"; break; fi
done
[ -n "$BIND_PKG" ] || die "Tidak menemukan paket bind9xx di repo."
pkg install -y "$BIND_PKG"

# ---------------------------------------------------------------------------
# 4. Direktori & Zona Lokal
# ---------------------------------------------------------------------------

for d in "$NAMEDB" "$RPZDIR" "$WORKDIR" "${WORKDIR}/slave" "$LOGDIR"; do
	[ -d "$d" ] || mkdir -p "$d"
done

if [ ! -f "${NAMEDB}/rndc.key" ]; then
	rndc-confgen -a -u "$BIND_USER" -c "${NAMEDB}/rndc.key" >/dev/null 2>&1
fi
chown "${BIND_USER}:${BIND_GROUP}" "${NAMEDB}/rndc.key"
chmod 0640 "${NAMEDB}/rndc.key"

STAMP="$(date +%Y%m%d%H%M%S)"
[ -f "${NAMEDB}/named.conf" ] && cp -p "${NAMEDB}/named.conf" "${NAMEDB}/named.conf.bak.${STAMP}"

SERIAL="$(date +%s)"

# Landing Zone
cat <<LANDEOF > "${RPZDIR}/db.landing"
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

# Custom CNAME Zone (SafeSearch)
if [ ! -f "${RPZDIR}/db.rpz-custom" ]; then
	msg "Membuat zona custom (SafeSearch)"
	cat <<CUSTEOF > "${RPZDIR}/db.rpz-custom"
\$TTL 60
@	IN	SOA	localhost. root.localhost. ( ${SERIAL} 3600 900 604800 60 )
	IN	NS	localhost.

; --- Google SafeSearch ---
google.com               IN  CNAME forcesafesearch.google.com.
www.google.com           IN  CNAME forcesafesearch.google.com.

; --- Bing SafeSearch ---
bing.com                 IN  CNAME strict.bing.com.
www.bing.com             IN  CNAME strict.bing.com.

CUSTEOF
fi

# Whitelist & Blacklist
[ -f "${RPZDIR}/whitelist.txt" ] || cat > "${RPZDIR}/whitelist.txt" <<'WLEOF'
# Domain yang TIDAK boleh diblokir (passthru)
WLEOF

[ -f "${RPZDIR}/blacklist.txt" ] || cat > "${RPZDIR}/blacklist.txt" <<'BLEOF'
# Blokir tambahan manual ke landing page
BLEOF

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

if [ -n "$KOMDIGI_PRIMARIES" ] && [ ! -f "${WORKDIR}/slave/db.rpz-komdigi" ]; then
	cat > "${WORKDIR}/slave/db.rpz-komdigi" <<SEEDEOF
\$TTL 60
@	IN	SOA	localhost. root.localhost. ( 1 3600 900 604800 60 )
	IN	NS	localhost.
SEEDEOF
fi

chown -R "${BIND_USER}:${BIND_GROUP}" "$RPZDIR" "${WORKDIR}" "$LOGDIR"
chmod 0750 "$RPZDIR" "$WORKDIR" "${WORKDIR}/slave" "$LOGDIR"
chmod 0640 "${RPZDIR}/"db.*

# ---------------------------------------------------------------------------
# 5. Konfigurasi named.conf
# ---------------------------------------------------------------------------

[ ! -f "${NAMEDB}/named.root" ] && fetch -q -T 30 -o "${NAMEDB}/named.root" https://www.internic.net/domain/named.root || true

LOCAL_ZONES=""
[ -f "${NAMEDB}/named.root" ] && LOCAL_ZONES="zone \".\" { type hint; file \"${NAMEDB}/named.root\"; };"
for _d in primary master; do
	[ -f "${NAMEDB}/${_d}/localhost-forward.db" ] && LOCAL_ZONES="${LOCAL_ZONES}
zone \"localhost\"        { type primary; file \"${NAMEDB}/${_d}/localhost-forward.db\"; };"
	[ -f "${NAMEDB}/${_d}/localhost-reverse.db" ] && LOCAL_ZONES="${LOCAL_ZONES}
zone \"127.in-addr.arpa\" { type primary; file \"${NAMEDB}/${_d}/localhost-reverse.db\"; };"
done

TSIG_BLOCK=""
TSIG_REF=""
if [ -n "$KOMDIGI_TSIG_NAME" ] && [ -n "$KOMDIGI_TSIG_SECRET" ]; then
	TSIG_BLOCK="key \"${KOMDIGI_TSIG_NAME}\" { algorithm ${KOMDIGI_TSIG_ALGO}; secret \"${KOMDIGI_TSIG_SECRET}\"; };"
	TSIG_REF=" key ${KOMDIGI_TSIG_NAME}"
fi

RP_KOMDIGI=""
ZONE_KOMDIGI=""
if [ -n "$KOMDIGI_PRIMARIES" ]; then
	PRIMARIES_PLAIN="$(echo "$KOMDIGI_PRIMARIES" | tr ',' '\n' | grep -v '^$' | sed 's/$/;/' | sed 's/^/\t\t/')"
	PRIMARIES_LIST="$(echo "$KOMDIGI_PRIMARIES" | tr ',' '\n' | grep -v '^$' | sed "s/\$/${TSIG_REF};/" | sed 's/^/\t\t/')"
	RP_KOMDIGI="		zone \"${KOMDIGI_ZONE}\" policy cname ${LANDING_FQDN}.;"
	ZONE_KOMDIGI="zone \"${KOMDIGI_ZONE}\" {
	type secondary; file \"${WORKDIR}/slave/db.rpz-komdigi\";
	primaries { ${PRIMARIES_LIST} };
	allow-query { localhost; }; allow-transfer { none; };
	allow-notify { ${PRIMARIES_PLAIN} };
	max-transfer-time-in 60; check-names ignore;
};"
fi

msg "Menulis ${NAMEDB}/named.conf"
cat > "${NAMEDB}/named.conf" <<NCEOF
// Digenerate oleh ${PROG} v${VERSION} pada $(date '+%Y-%m-%d %H:%M:%S %Z')
acl "pelanggan" { localhost; localnets; ${ACL_CLIENTS} };
acl "admin" { 127.0.0.1; ::1; };

${TSIG_BLOCK}
options {
	directory "${WORKDIR}";
	pid-file "/var/run/named/pid";

	listen-on port 53 { 127.0.0.1; ${ACL_LISTEN4} };
$(if [ -n "$ACL_LISTEN6" ]; then echo "	listen-on-v6 port 53 { ::1; ${ACL_LISTEN6} };"; else echo "	listen-on-v6 port 53 { ::1; };"; fi)

	recursion yes;
	allow-query { pelanggan; };
	allow-query-cache { pelanggan; };
	allow-recursion { pelanggan; };
	allow-transfer { none; };

	dnssec-validation auto;
	minimal-responses yes;
	querylog $( [ "$QUERY_LOG" = "yes" ] && echo yes || echo no );

	max-cache-size ${CACHE_SIZE};
	max-cache-ttl 86400; max-ncache-ttl 3600; prefetch 2 9;
	recursive-clients ${RECURSIVE_CLIENTS}; tcp-clients 1000;
	clients-per-query 10; max-clients-per-query 100;

	stale-answer-enable yes; stale-answer-ttl 30;
	max-stale-ttl 86400; stale-cache-enable yes; zone-statistics yes;

	// ---- Response Policy Zone -------------------------------------
	response-policy {
		zone "rpz-whitelist.local"    policy passthru;
		zone "rpz-custom.local";
		zone "rpz-blacklist.local"    policy cname ${LANDING_FQDN}.;
${RP_KOMDIGI}		zone "rpz-trustpositif.local" policy cname ${LANDING_FQDN}.;
	} qname-wait-recurse no nsip-enable no nsdname-enable no break-dnssec yes max-policy-ttl 60 recursive-only yes;
};

logging {
	channel "default_log" { file "${LOGDIR}/named.log" versions 7 size 50m; severity info; print-time yes; print-category yes; };
	channel "rpz_log" { file "${LOGDIR}/rpz.log" versions 7 size 100m; severity info; print-time yes; };
	category default { default_log; }; category rpz { rpz_log; };
	category lame-servers { null; }; category edns-disabled { null; };
};

statistics-channels { inet ${STATS_ADDR} port ${STATS_PORT} allow { ${STATS_ADDR}; }; };
include "${NAMEDB}/rndc.key";
controls { inet 127.0.0.1 port 953 allow { admin; } keys { "rndc-key"; }; };

zone "${LANDING_FQDN}" { type primary; file "${RPZDIR}/db.landing"; allow-query { any; }; notify no; };
zone "rpz-whitelist.local" { type primary; file "${RPZDIR}/db.rpz-whitelist"; allow-query { localhost; }; notify no; check-names ignore; };
zone "rpz-custom.local" { type primary; file "${RPZDIR}/db.rpz-custom"; allow-query { localhost; }; notify no; check-names ignore; };
zone "rpz-blacklist.local" { type primary; file "${RPZDIR}/db.rpz-blacklist"; allow-query { localhost; }; notify no; check-names ignore; };
${ZONE_KOMDIGI}
zone "rpz-trustpositif.local" { type primary; file "${RPZDIR}/db.rpz-trustpositif"; allow-query { localhost; }; notify no; check-names ignore; };
${LOCAL_ZONES}
NCEOF
chown "${BIND_USER}:${BIND_GROUP}" "${NAMEDB}/named.conf"
chmod 0640 "${NAMEDB}/named.conf"

# ---------------------------------------------------------------------------
# 6. Updater Fallback Script
# ---------------------------------------------------------------------------

cat > "$CONF" <<CFGEOF
TP_URL="${TP_URL}"
TP_MIN_DOMAINS="${TP_MIN_DOMAINS}"
RPZ_WILDCARD="${RPZ_WILDCARD}"
RPZDIR="${RPZDIR}"
LANDING_FQDN="${LANDING_FQDN}"
BIND_USER="${BIND_USER}"
BIND_GROUP="${BIND_GROUP}"
KOMDIGI_ZONE="${KOMDIGI_PRIMARIES:+${KOMDIGI_ZONE}}"
LOGFILE="${LOGDIR}/rpz-update.log"
CFGEOF
chmod 0640 "$CONF"

cat > "$UPDATER" <<'UPDEOF'
#!/bin/sh
set -eu
export LC_ALL=C
export PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
CONF="/usr/local/etc/rpz-komdigi.conf"
. "$CONF"
: "${RPZDIR:?}" "${LANDING_FQDN:?}" "${LOGFILE:=/var/log/named/rpz-update.log}"
: "${TP_MIN_DOMAINS:=50000}" "${RPZ_WILDCARD:=yes}"
MODE="${1:-full}"

TMPDIR_RPZ="$(mktemp -d /tmp/rpz.XXXXXXXX)"
trap 'rm -rf "$TMPDIR_RPZ"' EXIT INT TERM
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE"; [ -t 1 ] && printf '%s\n' "$*"; }

normalize() {
	tr -d '\r' | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
	| sed 's/^\.//; s/\.$//' | grep -v '^[#;]' | grep -v '^$' | awk '{print $NF}' \
	| grep -E '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' | sort -u
}

gen_zone() {
	_list="$1"; _out="$2"; _action="$3"; _serial="$(date +%s)"
	[ "$_action" = "passthru" ] && _rdata="rpz-passthru." || _rdata="${LANDING_FQDN}."
	{
		printf '$TTL 60\n@\tIN\tSOA\tlocalhost. root.localhost. ( %s 3600 900 604800 60 )\n\tIN\tNS\tlocalhost.\n' "$_serial"
		awk -v rd="$_rdata" -v wc="$RPZ_WILDCARD" '{ print $0 "\tCNAME\t" rd; if (wc == "yes") print "*." $0 "\tCNAME\t" rd }' "$_list"
	} > "$_out"
}

install_zone() {
	_zone="$1"; _new="$2"; _dst="$3"
	named-checkzone -q "$_zone" "$_new" >/dev/null 2>&1 || return 1
	install -o "$BIND_USER" -g "$BIND_GROUP" -m 0640 "$_new" "$_dst"
	rndc reload "$_zone" >/dev/null 2>&1 || return 1
}

# Local Whitelist & Blacklist
: > "${TMPDIR_RPZ}/wl"
[ -f "${RPZDIR}/whitelist.txt" ] && normalize < "${RPZDIR}/whitelist.txt" > "${TMPDIR_RPZ}/wl"
gen_zone "${TMPDIR_RPZ}/wl" "${TMPDIR_RPZ}/z.wl" passthru
install_zone "rpz-whitelist.local" "${TMPDIR_RPZ}/z.wl" "${RPZDIR}/db.rpz-whitelist" || true

: > "${TMPDIR_RPZ}/bl"
[ -f "${RPZDIR}/blacklist.txt" ] && normalize < "${RPZDIR}/blacklist.txt" > "${TMPDIR_RPZ}/bl"
gen_zone "${TMPDIR_RPZ}/bl" "${TMPDIR_RPZ}/z.bl" cname
install_zone "rpz-blacklist.local" "${TMPDIR_RPZ}/z.bl" "${RPZDIR}/db.rpz-blacklist" || true

[ "$MODE" = "--local-only" ] && exit 0

# TrustPositif Fallback
fetch -q -T 120 -o "${TMPDIR_RPZ}/raw" "$TP_URL" || exit 1
normalize < "${TMPDIR_RPZ}/raw" > "${TMPDIR_RPZ}/tp.all"
COUNT="$(wc -l < "${TMPDIR_RPZ}/tp.all" | tr -d ' ')"
[ "$COUNT" -lt "$TP_MIN_DOMAINS" ] && exit 1

[ -s "${TMPDIR_RPZ}/wl" ] && comm -23 "${TMPDIR_RPZ}/tp.all" "${TMPDIR_RPZ}/wl" > "${TMPDIR_RPZ}/tp" || cp "${TMPDIR_RPZ}/tp.all" "${TMPDIR_RPZ}/tp"
gen_zone "${TMPDIR_RPZ}/tp" "${TMPDIR_RPZ}/z.tp" cname
install_zone "rpz-trustpositif.local" "${TMPDIR_RPZ}/z.tp" "${RPZDIR}/db.rpz-trustpositif"
log "Update TP selesai (${COUNT} domain)"
UPDEOF
chmod 0750 "$UPDATER"

# ---------------------------------------------------------------------------
# 7. Finishing & Restart
# ---------------------------------------------------------------------------

if ! grep -Fq "rpz-komdigi-update" /etc/crontab 2>/dev/null; then
	printf '\n# rpz-komdigi-update (dikelola %s)\n%s\troot\t%s >/dev/null 2>&1\n' "$PROG" "$UPDATE_CRON" "$UPDATER" >> /etc/crontab
fi

mkdir -p /usr/local/etc/newsyslog.conf.d
echo "${LOGDIR}/rpz-update.log ${BIND_USER}:${BIND_GROUP} 640 7 1000 * JC" > /usr/local/etc/newsyslog.conf.d/rpz-komdigi.conf
touch "${LOGDIR}/rpz-update.log"; chown "${BIND_USER}:${BIND_GROUP}" "${LOGDIR}/rpz-update.log"

if [ "$TUNE_SYSCTL" = "yes" ] && ! grep -Fq "kern.maxdsiz" /etc/sysctl.conf 2>/dev/null; then
	cat >> /etc/sysctl.conf <<SYSEOF
kern.ipc.maxsockbuf=16777216
net.inet.udp.recvspace=1048576
net.inet.ip.portrange.first=1024
net.inet.ip.portrange.last=65535
kern.maxdsiz=4294967296
SYSEOF
	sysctl kern.maxdsiz=4294967296 >/dev/null 2>&1 || true
fi

sysrc named_enable="YES" >/dev/null
sysrc named_conf="${NAMEDB}/named.conf" >/dev/null
named-checkconf "${NAMEDB}/named.conf" || die "Konfigurasi named.conf tidak valid!"

"$UPDATER" || true
service named restart

cat <<SUMMARY

==============================================================================
 Selesai.

 Konfigurasi   : ${NAMEDB}/named.conf
 Whitelist     : ${RPZDIR}/whitelist.txt   (edit, lalu: ${UPDATER} --local-only)
 Blacklist     : ${RPZDIR}/blacklist.txt   (idem)
 Custom CNAME  : ${RPZDIR}/db.rpz-custom   (edit, lalu: rndc reload rpz-custom.local)
==============================================================================
SUMMARY