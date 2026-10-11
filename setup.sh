#!/data/data/com.termux/files/usr/bin/bash
# ==========================================================
#  Android TV Stick - Termux otomatik kurulum betiği
#  SSH (8022) + wake-lock + Termux:Boot otomatik başlatma
#  + Python / Node.js / FFmpeg / (opsiyonel Go) + cron
# ==========================================================
set -u

R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;36m'; N='\033[0m'
ok()   { echo -e "${G}[✓]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*"; }
step() { echo -e "\n${B}==== $* ====${N}"; }

# Betik "bash <(curl ...)" ile de çalışsın diye girdiler doğrudan terminalden okunur
TTY=/dev/tty

if [ ! -d /data/data/com.termux/files/usr ]; then
  err "Bu betik Termux içinde çalıştırılmalı."; exit 1
fi
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}

# ---------------------------------------------------------
step "1/8 Kurulum bilgileri"
# ---------------------------------------------------------
read -rp "SSH kullanıcı adı [tvstick]: " SSH_USER < "$TTY"
SSH_USER=${SSH_USER:-tvstick}

while true; do
  read -rsp "SSH şifresi (en az 8 karakter): " P1 < "$TTY"; echo
  read -rsp "Şifre (tekrar): " P2 < "$TTY"; echo
  if [ ${#P1} -lt 8 ]; then warn "Şifre en az 8 karakter olmalı."; continue; fi
  if [ "$P1" != "$P2" ]; then warn "Şifreler eşleşmedi, tekrar dene."; continue; fi
  break
done

read -rp "Go (golang) da kurulsun mu? ~300 MB+ yer kaplar [e/H]: " WANT_GO < "$TTY"
case "$WANT_GO" in e|E|y|Y) WANT_GO=1 ;; *) WANT_GO=0 ;; esac

# ---------------------------------------------------------
step "2/8 İşlemciyi uyanık tutma"
# ---------------------------------------------------------
if termux-wake-lock 2>/dev/null; then ok "termux-wake-lock aktif"
else warn "wake-lock alınamadı (bildirim izni kapalı olabilir)"; fi

# ---------------------------------------------------------
step "3/8 Paket listesi ve güncelleme"
# ---------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef)
apt-get update || { err "Depo güncellenemedi. 'termux-change-repo' ile ayna değiştirip tekrar dene."; exit 1; }
apt-get "${APT_OPTS[@]}" upgrade || warn "Bazı paketler güncellenemedi, devam ediliyor."
ok "Sistem güncel"

# ---------------------------------------------------------
step "4/8 Gerekli paketler"
# ---------------------------------------------------------
PKGS=(openssh termux-auth python nodejs-lts ffmpeg git curl wget jq tmux nano net-tools iproute2 cronie termux-api)
[ "$WANT_GO" = 1 ] && PKGS+=(golang)

for p in "${PKGS[@]}"; do
  if apt-get "${APT_OPTS[@]}" install "$p" >/dev/null 2>&1; then ok "$p"
  else warn "$p kurulamadı (sonra elle dene: pkg install $p)"; fi
done

if command -v pip >/dev/null 2>&1; then
  pip install --quiet requests aiohttp >/dev/null 2>&1 && ok "Python: requests, aiohttp" \
    || warn "pip paketleri kurulamadı"
fi

# ---------------------------------------------------------
step "5/8 SSH yapılandırması"
# ---------------------------------------------------------
if printf '%s\n%s\n' "$P1" "$P1" | passwd >/dev/null 2>&1; then
  ok "Şifre ayarlandı"
else
  warn "Şifre otomatik ayarlanamadı, şimdi elle gir:"
  passwd < "$TTY"
fi
unset P1 P2

CFG="$PREFIX/etc/ssh/sshd_config"
mkdir -p "$(dirname "$CFG")"; touch "$CFG"
sed -i -E '/^[#[:space:]]*(Port|PasswordAuthentication|PrintMotd|ClientAliveInterval|ClientAliveCountMax)[[:space:]]/d' "$CFG"
cat >> "$CFG" <<EOF
Port 8022
PasswordAuthentication yes
PrintMotd yes
ClientAliveInterval 60
ClientAliveCountMax 3
EOF

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"

pkill sshd 2>/dev/null; sleep 1
if sshd; then ok "sshd 8022 portunda çalışıyor"; else err "sshd başlatılamadı"; fi

# ---------------------------------------------------------
step "6/8 Klasör yapısı"
# ---------------------------------------------------------
mkdir -p "$HOME/iptv/scripts" "$HOME/iptv/playlists" "$HOME/iptv/logs" \
         "$HOME/autostart" "$HOME/logs"
ok "~/iptv, ~/autostart, ~/logs hazır"

# ---------------------------------------------------------
step "7/8 Açılışta otomatik başlatma (Termux:Boot)"
# ---------------------------------------------------------
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/00-start.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot tarafından cihaz açılışında çalıştırılır
P=/data/data/com.termux/files/usr/bin
H=/data/data/com.termux/files/home
$P/termux-wake-lock
$P/sshd
[ -x $P/crond ] && $P/crond
# ~/autostart içindeki çalıştırılabilir her .sh dosyasını arka planda başlat
for f in $H/autostart/*.sh; do
  [ -x "$f" ] || continue
  nohup "$f" > "$H/logs/$(basename "$f").log" 2>&1 &
done
EOF
chmod +x "$HOME/.termux/boot/00-start.sh"
ok "Açılış betiği: ~/.termux/boot/00-start.sh"

command -v crond >/dev/null 2>&1 && { pgrep crond >/dev/null || crond; ok "cron servisi çalışıyor"; }

# ---------------------------------------------------------
step "8/8 Bağlantı bilgileri"
# ---------------------------------------------------------
IP=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -vE '^127\.' | head -n1)
[ -z "$IP" ] && IP=$(ip -4 addr 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2);print $2}' | grep -vE '^127\.' | head -n1)
[ -z "$IP" ] && IP="<TV_IP_ADRESI>"

cat > "$HOME/.tvstick-info" <<EOF
SSH_USER=$SSH_USER
SSH_PORT=8022
LAST_IP=$IP
INSTALLED=$(date '+%Y-%m-%d %H:%M')
EOF

echo
echo -e "${G}Kurulum tamamlandı.${N}"
echo "--------------------------------------------------"
echo "  Bağlan:  ssh -p 8022 ${SSH_USER}@${IP}"
echo "--------------------------------------------------"
warn "ELLE YAPMAN GEREKENLER (betik bunları yapamaz):"
echo "  1) Termux:Boot uygulamasını Termux'u indirdiğin yerden (F-Droid/GitHub) kur"
echo "     ve BİR KEZ aç. Açılmazsa otomatik başlatma çalışmaz."
echo "  2) Ayarlar > Uygulamalar > Termux ve Termux:Boot > Pil: 'Kısıtlama yok'."
echo "  3) Router'da TV Stick'e sabit IP (DHCP rezervasyonu) ver."
echo "  4) Kendi betiklerini ~/autostart/ içine koy ve 'chmod +x' ver;"
echo "     açılışta otomatik başlarlar. Periyodik işler için: crontab -e"
