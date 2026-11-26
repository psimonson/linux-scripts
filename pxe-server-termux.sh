#!/bin/sh
# pxe-server-termux.sh - PXE server for Termux (rooted) - BIOS + UEFI - eth0 / rndis0 / wlan0
# Run: tsu -c 'sh pxe-server-termux.sh --iso /sdcard/Download/systemrescue.iso --interface rndis0'
#      tsu -c 'sh pxe-server-termux.sh --iso ~/ubuntu.iso --interface auto'
set -eu
INTERFACE=""
ISO_FILE=""; IMG_FILE=""; HTTP_PORT=8000
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
PXE_ROOT="$HOME_DIR/pxe"; TFTP_ROOT="$PXE_ROOT/tftp"; HTTP_ROOT="$PXE_ROOT/www"
DNSMASQ_CONF="$PXE_ROOT/dnsmasq.conf"; DNSMASQ_PID="$PXE_ROOT/dnsmasq.pid"
HTTP_PID="$PXE_ROOT/http.pid"; HTTP_LOG="$PXE_ROOT/http.log"
DHCP_RANGE=""; GATEWAY=""; DNS_SERVER="8.8.8.8"; KERNEL_URL=""; INITRD_URL=""
MODE="ipxe"; DHCP_MODE="auto"; FORCE_FULL=""; ACTION=""
log()  { printf '\033[1;32m[pxe]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage (Termux, ROOT REQUIRED):
  tsu -c 'sh pxe-server-termux.sh --iso FILE.iso --interface auto'
  tsu -c 'sh pxe-server-termux.sh --iso FILE.iso --interface eth0'     # USB-Ethernet: full DHCP
  tsu -c 'sh pxe-server-termux.sh --iso FILE.iso --interface rndis0'   # USB tether: proxy DHCP
  tsu -c 'sh pxe-server-termux.sh --iso FILE.iso --interface wlan0'    # hotspot/Wi-Fi: proxy DHCP
  tsu -c 'sh pxe-server-termux.sh --list-interfaces'
  tsu -c 'sh pxe-server-termux.sh --stop' / '--status'
Options:
  --iso/--img FILE  --interface IFACE|auto  --port PORT  --dhcp-range RANGE
  --gateway IP  --dns IP  --kernel FILE|URL  --initrd FILE|URL
  --mode ipxe|pxelinux  --dhcp-mode auto|full|proxy  --force-full-dhcp
  --list-interfaces  --stop  --status  -h/--help
DHCP modes: eth0 -> full (this script is the DHCP server).
  rndis0/wlan0/ap0 -> proxy (Android/router already does DHCP; this script only
  answers PXE clients with boot file + next-server, hands out NO IPs).
EOF
  exit 0
}
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO_FILE="$2"; shift 2;; --img) IMG_FILE="$2"; shift 2;;
    --interface) INTERFACE="$2"; shift 2;; --port) HTTP_PORT="$2"; shift 2;;
    --dhcp-range) DHCP_RANGE="$2"; shift 2;; --gateway) GATEWAY="$2"; shift 2;;
    --dns) DNS_SERVER="$2"; shift 2;; --kernel) KERNEL_URL="$2"; shift 2;;
    --initrd) INITRD_URL="$2"; shift 2;; --mode) MODE="$2"; shift 2;;
    --dhcp-mode) DHCP_MODE="$2"; shift 2;; --force-full-dhcp) FORCE_FULL=1; shift;;
    --list-interfaces) ACTION="list"; shift;; --stop) ACTION="stop"; shift;;
    --status) ACTION="status"; shift;; -h|--help) usage;;
    *) err "Unknown arg: $1. See --help";;
  esac
done
stop_server() {
  log "Stopping PXE server..."
  if [ -f "$HTTP_PID" ]; then kill "$(cat "$HTTP_PID")" 2>/dev/null || true; fi
  if [ -f "$DNSMASQ_PID" ]; then kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true; fi
  pkill -f "dnsmasq.*$PXE_ROOT" 2>/dev/null || true
  pkill -f "http.server $HTTP_PORT" 2>/dev/null || true
  rm -f "$DNSMASQ_CONF" "$HTTP_PID" "$DNSMASQ_PID"
  log "Stopped. Files left at $PXE_ROOT"; exit 0
}
status_server() {
  echo "=== PXE Server Status (Termux) ==="; echo "PXE root: $PXE_ROOT"
  if command -v ss >/dev/null 2>&1; then ss -tlnp 2>/dev/null | grep -E ":$HTTP_PORT|:67|:69" || echo "No PXE ports listening"; fi
  if [ -f "$DNSMASQ_PID" ]; then echo "dnsmasq pid: $(cat "$DNSMASQ_PID")"; else echo "dnsmasq: not running (via this script)"; fi
  if [ -f "$HTTP_PID" ]; then echo "http pid: $(cat "$HTTP_PID")"; else echo "http: not running"; fi
  ls -lh "$TFTP_ROOT" 2>/dev/null || echo "No TFTP root yet"; exit 0
}
if [ "$ACTION" = "list" ]; then
  echo "Interfaces with IPv4:"; ip -4 addr show 2>/dev/null | grep -E '^[0-9]+:|inet ' || ip addr show
  echo "eth0=USB-Ethernet(full)  rndis0=USB tether(proxy)  wlan0/ap0=hotspot(proxy)"; exit 0
fi
if [ "$ACTION" = "stop" ]; then stop_server; fi
if [ "$ACTION" = "status" ]; then status_server; fi
if [ "$(id -u)" -ne 0 ]; then err "Must run as root: pkg install tsu && tsu -c 'sh pxe-server-termux.sh --iso ... --interface auto'"; fi
# --- Interface resolution: auto / ap0 fallback ---
if [ -z "$INTERFACE" ] || [ "$INTERFACE" = "auto" ]; then
  for _cand in eth0 rndis0 wlan0 ap0 usb0; do
    if ip -4 addr show "$_cand" 2>/dev/null | grep -q 'inet '; then INTERFACE="$_cand"; log "Auto-selected interface: $INTERFACE"; break; fi
  done
  [ -n "$INTERFACE" ] || err "No interface with IPv4. Start hotspot, plug USB-Ethernet, or enable USB tethering. Run --list-interfaces"
fi
if [ "$INTERFACE" = "wlan0" ]; then
  if ! ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '; then
    if ip -4 addr show ap0 2>/dev/null | grep -q 'inet '; then warn "wlan0 has no IP, ap0 (hotspot) does - using ap0"; INTERFACE="ap0"; fi
  fi
fi
case "$DHCP_MODE" in auto|full|proxy) ;; *) err "--dhcp-mode must be auto, full, or proxy";; esac
if [ -z "$ISO_FILE" ] && [ -z "$IMG_FILE" ]; then err "Provide --iso FILE or --img FILE"; fi
if [ -n "$ISO_FILE" ] && [ -n "$IMG_FILE" ]; then err "Provide only one of --iso / --img"; fi
if [ -n "$ISO_FILE" ]; then SOURCE_FILE="$ISO_FILE"; else SOURCE_FILE="$IMG_FILE"; fi
[ -f "$SOURCE_FILE" ] || err "File not found: $SOURCE_FILE"
case "$MODE" in ipxe|pxelinux) ;; *) err "--mode must be ipxe or pxelinux";; esac
log "Checking dependencies..."
if command -v pkg >/dev/null 2>&1; then
  for c in dnsmasq python3 curl; do command -v "$c" >/dev/null 2>&1 || pkg install -y dnsmasq python iproute2 curl wget tar; done
fi
command -v dnsmasq >/dev/null 2>&1 || err "dnsmasq not found: pkg install dnsmasq"
command -v python3 >/dev/null 2>&1 || err "python3 not found: pkg install python"
# ---------- Network: per-interface DHCP mode ----------
IF_IP=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep 'inet ' | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)
[ -n "$IF_IP" ] || err "Interface $INTERFACE has no IPv4. rndis0: enable USB tethering. wlan0: enable hotspot / join Wi-Fi. eth0: plug adapter."
IF_CIDR=$(ip -4 addr show "$INTERFACE" 2>/dev/null | grep 'inet ' | sed -n 's/.*inet \([0-9.]*\/[0-9]*\).*/\1/p' | head -n 1)
IF_LAST_OCTET=$(printf '%s' "$IF_IP" | sed 's/.*\.//')
NET_PREFIX=$(printf '%s' "$IF_IP" | sed 's/\.[0-9]*$//')
if [ -z "$GATEWAY" ]; then GATEWAY="$IF_IP"; fi
DHCP_IN_USE=""
if command -v ss >/dev/null 2>&1; then ss -ulnp 2>/dev/null | grep -q ':67 ' && DHCP_IN_USE=1; fi
case "$INTERFACE" in rndis0|wlan0|ap0) IF_DEFAULT_MODE="proxy";; eth0) IF_DEFAULT_MODE="full";; *) IF_DEFAULT_MODE="proxy";; esac
if [ "$DHCP_MODE" = "auto" ]; then
  DHCP_MODE="$IF_DEFAULT_MODE"
  if [ "$DHCP_MODE" = "full" ] && [ -n "$DHCP_IN_USE" ] && [ -z "$FORCE_FULL" ]; then warn "Port 67 already in use - switching full -> proxy"; DHCP_MODE="proxy"; fi
  if [ "$DHCP_MODE" = "full" ] && [ "$IF_LAST_OCTET" != "1" ] && [ -z "$FORCE_FULL" ]; then warn "$INTERFACE IP $IF_IP is not .1 - looks like a DHCP client, not gateway. Switching full -> proxy"; DHCP_MODE="proxy"; fi
fi
if [ "$DHCP_MODE" = "full" ] && [ -n "$DHCP_IN_USE" ] && [ -z "$FORCE_FULL" ]; then err "Port 67 in use + --dhcp-mode full. Use --dhcp-mode proxy or --force-full-dhcp"; fi
if [ "$DHCP_MODE" = "full" ] && [ -z "$DHCP_RANGE" ]; then DHCP_RANGE="$NET_PREFIX.100,$NET_PREFIX.200,12h"; fi
log "Interface $INTERFACE IP: $IF_IP ($IF_CIDR) | DHCP mode: $DHCP_MODE | Gateway: $GATEWAY"
if [ "$DHCP_MODE" = "proxy" ]; then log "PROXY DHCP: Android/router hands out IPs, this script only hands out PXE boot file + next-server $IF_IP"; else log "FULL DHCP: this script hands out IPs $DHCP_RANGE"; fi
# ---------- Layout ----------
log "Setting up $PXE_ROOT ..."
mkdir -p "$TFTP_ROOT" "$HTTP_ROOT" "$TFTP_ROOT/pxelinux.cfg"
BASENAME=$(basename "$SOURCE_FILE")
if command -v realpath >/dev/null 2>&1; then SRC_ABS=$(realpath "$SOURCE_FILE"); else SRC_ABS=$(readlink -f "$SOURCE_FILE"); fi
ln -sf "$SRC_ABS" "$HTTP_ROOT/$BASENAME"
chmod -R a+rX "$TFTP_ROOT" "$HTTP_ROOT" 2>/dev/null || true
# ---------- Download bootloaders ----------
# THE BUG IN THE PREVIOUS VERSION (your log proves it):
#   ipxeboot.tar.gz (12 MB) downloaded OK, but extraction looked ONLY at the
#   tarball top level:  $tmp/ipxe.efi , $tmp/efi/ipxe.efi ...
#   Real layout is ONE FOLDER DEEP:  ipxeboot/ipxe.efi , ipxeboot/snponly.efi ,
#   ipxeboot/arm64-sb/...  (see ipxe.net secboot page). So it never found the file,
#   deleted the tarball, and then failed verification with "Missing ipxe.efi"
#   even though the file WAS inside the download.
# FIX: never guess paths. Use `find` to locate the file ANYWHERE in the extract dir.
cd "$TFTP_ROOT"
try_urls() {
  _dest="$1"; shift
  for _u in "$@"; do
    rm -f "$_dest.tmp"
    if curl -fsSL -o "$_dest.tmp" "$_u" 2>/dev/null; then
      _sz=$(wc -c < "$_dest.tmp" 2>/dev/null || echo 0)
      if [ "$_sz" -gt 10000 ]; then mv "$_dest.tmp" "$_dest"; log "Downloaded $_dest (${_sz} bytes) from $_u"; return 0; fi
      warn "Downloaded $_dest from $_u but only ${_sz} bytes - bad/HTML, trying next mirror"
    else warn "Failed: $_u"; fi
  done
  rm -f "$_dest.tmp"; return 1
}
# find_first DIR NAME -> prints first match, e.g. find_first tmp ipxe.efi
find_first() { find "$1" -type f -name "$2" 2>/dev/null | head -n 1; }
try_urls undionly.kpxe "https://boot.ipxe.org/undionly.kpxe" "http://boot.ipxe.org/undionly.kpxe" || warn "Could not download undionly.kpxe - BIOS boot will fail"
if [ ! -f ipxe.efi ] || [ ! -f snponly.efi ] || [ ! -f ipxe-arm64.efi ]; then
  log "Downloading iPXE UEFI binaries (ipxeboot.tar.gz)..."
  if try_urls ipxeboot.tar.gz "https://github.com/ipxe/ipxe/releases/latest/download/ipxeboot.tar.gz"; then
    _tmp=$(mktemp -d)
    # List what is actually inside, so a future layout change is visible in the log
    log "ipxeboot.tar.gz contents (first 30):"; tar -tzf ipxeboot.tar.gz 2>/dev/null | head -n 30 || true
    if tar -xzf ipxeboot.tar.gz -C "$_tmp" 2>/dev/null; then
      _f=$(find_first "$_tmp" "ipxe.efi");        if [ -n "$_f" ]; then cp "$_f" ipxe.efi; log "Extracted ipxe.efi from $_f"; fi
      _f=$(find_first "$_tmp" "snponly.efi");     if [ -n "$_f" ]; then cp "$_f" snponly.efi; log "Extracted snponly.efi from $_f"; fi
      # ARM64: any ipxe.efi under an arm64* dir wins; else any snponly.efi under arm64*
      _f=$(find "$_tmp" -type f -path "*arm64*" -name "ipxe.efi" 2>/dev/null | head -n 1)
      if [ -n "$_f" ]; then cp "$_f" ipxe-arm64.efi; log "Extracted ipxe-arm64.efi from $_f"; fi
      _f=$(find "$_tmp" -type f -path "*arm64*" -name "snponly.efi" 2>/dev/null | head -n 1)
      if [ -n "$_f" ]; then cp "$_f" snponly-arm64.efi; log "Extracted snponly-arm64.efi from $_f"; fi
    else warn "Could not extract ipxeboot.tar.gz"; fi
    rm -rf "$_tmp" ipxeboot.tar.gz
  else warn "Could not download ipxeboot.tar.gz"; fi
fi
if [ ! -f ipxe-arm64.efi ]; then
  if [ -f snponly-arm64.efi ]; then cp snponly-arm64.efi ipxe-arm64.efi;
  else try_urls ipxe-arm64.efi "https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi" "https://boot.netboot.xyz/ipxe/netboot.xyz-arm64-snponly.efi" || warn "No ARM64 iPXE - ARM UEFI will not boot (x86_64 unaffected)"; fi
fi
if [ ! -f snp.efi ] && [ -f snponly.efi ]; then cp snponly.efi snp.efi; fi
if [ ! -f ipxe.efi ] && [ -f snponly.efi ]; then cp snponly.efi ipxe.efi; warn "ipxe.efi not in tarball, using snponly.efi as ipxe.efi"; fi
if [ ! -f memdisk ] || [ ! -f pxelinux.0 ]; then
  log "Downloading Syslinux tarball (for memdisk + pxelinux.0)..."
  if try_urls syslinux.tar.xz "https://www.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.xz" "https://cdn.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.xz" "https://mirrors.kernel.org/pub/linux/utils/boot/syslinux/syslinux-6.03.tar.xz"; then
    _tmp=$(mktemp -d)
    if tar -xJf syslinux.tar.xz -C "$_tmp" 2>/dev/null || tar -xf syslinux.tar.xz -C "$_tmp" 2>/dev/null; then
      _f=$(find_first "$_tmp" "memdisk");     if [ -n "$_f" ]; then cp "$_f" memdisk; log "Extracted memdisk from $_f"; fi
      _f=$(find_first "$_tmp" "pxelinux.0");  if [ -n "$_f" ]; then cp "$_f" pxelinux.0; log "Extracted pxelinux.0 from $_f"; fi
      _f=$(find_first "$_tmp" "ldlinux.c32"); if [ -n "$_f" ]; then cp "$_f" ldlinux.c32; fi
      _f=$(find_first "$_tmp" "menu.c32");    if [ -n "$_f" ]; then cp "$_f" menu.c32; fi
    else warn "Could not extract syslinux tarball - pkg install tar"; fi
    rm -rf "$_tmp" syslinux.tar.xz
  else warn "Could not download Syslinux tarball"; fi
fi
log "Verifying boot files in $TFTP_ROOT ..."
ls -lh "$TFTP_ROOT" || true
_missing=""
for _f in undionly.kpxe ipxe.efi memdisk; do
  if [ ! -f "$_f" ]; then _missing="$_missing $_f"; else log "  OK $_f ($(wc -c < "$_f") bytes)"; fi
done
if [ -n "$_missing" ]; then err "Missing required boot files:$_missing - re-run, or manually place them in $TFTP_ROOT"; fi
if [ "$MODE" = "pxelinux" ] && [ ! -f pxelinux.0 ]; then err "pxelinux mode needs pxelinux.0"; fi
# ---------- Kernel/initrd (explicit only) ----------
if [ -n "$ISO_FILE" ]; then warn "Termux cannot loop-mount ISOs reliably - ISO boots via memdisk (needs RAM > ISO size) unless you pass --kernel/--initrd."; fi
if [ -n "$KERNEL_URL" ]; then if [ -f "$KERNEL_URL" ]; then cp "$KERNEL_URL" "$HTTP_ROOT/vmlinuz"; else curl -fsSL -o "$HTTP_ROOT/vmlinuz" "$KERNEL_URL" || err "Failed to download kernel"; fi; fi
if [ -n "$INITRD_URL" ]; then if [ -f "$INITRD_URL" ]; then cp "$INITRD_URL" "$HTTP_ROOT/initrd"; else curl -fsSL -o "$HTTP_ROOT/initrd" "$INITRD_URL" || err "Failed to download initrd"; fi; fi
# ---------- Boot configs ----------
HTTP_URL="http://$IF_IP:$HTTP_PORT"
cat > "$HTTP_ROOT/boot.ipxe" <<'IPXE_EOF'
#!ipxe
dhcp || goto failed
echo Booting from HTTP...
IPXE_EOF
cat >> "$HTTP_ROOT/boot.ipxe" <<EOF
set base-url $HTTP_URL
echo Booting $BASENAME from \${base-url}
EOF
if [ -n "$IMG_FILE" ]; then
cat >> "$HTTP_ROOT/boot.ipxe" <<'IPXE_EOF'
imgstat || goto memdisk
sanboot --no-describe --drive 0x80 ${base-url}/IMG_PLACEHOLDER || goto memdisk
goto done
:memdisk
echo sanboot failed, falling back to memdisk...
kernel ${base-url}/memdisk iso raw
initrd ${base-url}/IMG_PLACEHOLDER
boot || goto failed
:done
boot
:failed
echo Boot failed - press any key
prompt
shell
IPXE_EOF
sed -i "s|IMG_PLACEHOLDER|$BASENAME|g" "$HTTP_ROOT/boot.ipxe"
elif [ -f "$HTTP_ROOT/vmlinuz" ] && [ -f "$HTTP_ROOT/initrd" ]; then
cat >> "$HTTP_ROOT/boot.ipxe" <<'IPXE_EOF'
kernel ${base-url}/vmlinuz boot=casper netboot=http ip=dhcp iso-url=${base-url}/ISO_PLACEHOLDER toram ---
initrd ${base-url}/initrd
boot || goto failed
:failed
echo Boot failed
prompt
shell
IPXE_EOF
sed -i "s|ISO_PLACEHOLDER|$BASENAME|g" "$HTTP_ROOT/boot.ipxe"
else
cat >> "$HTTP_ROOT/boot.ipxe" <<'IPXE_EOF'
kernel ${base-url}/memdisk iso raw
initrd ${base-url}/ISO_PLACEHOLDER
boot || goto failed
:failed
echo Boot failed - image may be too large for RAM or not memdisk-bootable
prompt
shell
IPXE_EOF
sed -i "s|ISO_PLACEHOLDER|$BASENAME|g" "$HTTP_ROOT/boot.ipxe"
fi
cp "$HTTP_ROOT/boot.ipxe" "$TFTP_ROOT/boot.ipxe"
cat > "$TFTP_ROOT/pxelinux.cfg/default" <<EOF
DEFAULT menu.c32
PROMPT 0
TIMEOUT 50
LABEL pxe-boot
  MENU LABEL Boot $BASENAME
  KERNEL memdisk
  APPEND iso raw initrd=$BASENAME
EOF
ln -sf "$HTTP_ROOT/$BASENAME" "$TFTP_ROOT/$BASENAME" 2>/dev/null || true
# ---------- dnsmasq config: BIOS+UEFI, proxy vs full ----------
log "Writing dnsmasq config to $DNSMASQ_CONF ..."
if [ -f "$DNSMASQ_PID" ]; then kill "$(cat "$DNSMASQ_PID")" 2>/dev/null || true; sleep 1; fi
pkill -f "dnsmasq.*$PXE_ROOT" 2>/dev/null || true; sleep 1
cat > "$DNSMASQ_CONF" <<EOF
# Auto-generated - iface=$INTERFACE mode=$DHCP_MODE
interface=$INTERFACE
bind-interfaces
port=0
EOF
if [ "$DHCP_MODE" = "proxy" ]; then
cat >> "$DNSMASQ_CONF" <<EOF
dhcp-range=$IF_IP,proxy
EOF
else
cat >> "$DNSMASQ_CONF" <<EOF
dhcp-range=$DHCP_RANGE
dhcp-option=option:router,$GATEWAY
dhcp-option=option:dns-server,$DNS_SERVER
dhcp-authoritative
EOF
fi
cat >> "$DNSMASQ_CONF" <<EOF
enable-tftp
tftp-root=$TFTP_ROOT
dhcp-match=set:ipxe,175
dhcp-boot=tag:ipxe,http://$IF_IP:$HTTP_PORT/boot.ipxe
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-match=set:efi-x86_64,option:client-arch,9
dhcp-boot=tag:efi-x86_64,ipxe.efi
dhcp-match=set:efi-aarch64,option:client-arch,11
dhcp-match=set:efi-aarch64,option:client-arch,15
dhcp-match=set:efi-aarch64,option:client-arch,16
dhcp-boot=tag:efi-aarch64,ipxe-arm64.efi
EOF
if [ "$MODE" = "pxelinux" ]; then echo "dhcp-boot=pxelinux.0" >> "$DNSMASQ_CONF"; else echo "dhcp-boot=undionly.kpxe" >> "$DNSMASQ_CONF"; fi
printf 'log-dhcp\nlog-queries\n' >> "$DNSMASQ_CONF"
# ---------- Start services ----------
log "Starting dnsmasq..."
dnsmasq --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID" --no-daemon > "$PXE_ROOT/dnsmasq.log" 2>&1 &
DNSMASQ_BG_PID=$!; sleep 1
if ! kill -0 "$DNSMASQ_BG_PID" 2>/dev/null; then cat "$PXE_ROOT/dnsmasq.log" 2>/dev/null || true; err "dnsmasq failed - see $PXE_ROOT/dnsmasq.log"; fi
log "Starting Python HTTP server on $HTTP_URL ..."
cd "$HTTP_ROOT"
nohup python3 -m http.server "$HTTP_PORT" --bind "$IF_IP" > "$HTTP_LOG" 2>&1 &
echo $! > "$HTTP_PID"; sleep 1
if ! kill -0 "$(cat "$HTTP_PID")" 2>/dev/null; then cat "$HTTP_LOG" 2>/dev/null || true; err "HTTP server failed"; fi
echo ""
echo "=================================================="
echo "  PXE SERVER RUNNING (Termux, BIOS + UEFI)"
echo "=================================================="
echo "  Interface : $INTERFACE ($IF_IP)"
echo "  DHCP mode : $DHCP_MODE${DHCP_RANGE:+ / range: $DHCP_RANGE}"
echo "  Image     : $SOURCE_FILE"
echo "  HTTP      : $HTTP_URL/$BASENAME"
echo "  iPXE script: $HTTP_URL/boot.ipxe"
echo "  TFTP root : $TFTP_ROOT"
echo "  Mode      : $MODE"
echo "  Logs      : $HTTP_LOG , $PXE_ROOT/dnsmasq.log"
echo ""
echo "  CLIENT: BIOS=Legacy/PXE, UEFI=UEFI Network Boot / PXE IPv4"
echo "  Stop: tsu -c 'sh \$0 --stop'"
echo "=================================================="
trap 'log "Shutting down..."; kill $(cat "$HTTP_PID" 2>/dev/null) 2>/dev/null || true; kill $DNSMASQ_BG_PID 2>/dev/null || true; kill $(cat "$DNSMASQ_PID" 2>/dev/null) 2>/dev/null || true; exit 0' INT TERM
wait
