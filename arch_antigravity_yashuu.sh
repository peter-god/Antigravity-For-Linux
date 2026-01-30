#!/usr/bin/env bash
set -euo pipefail

# =============================
# GOOGLE ANTIGRAVITY INSTALLER
# Arch / Garuda / Manjaro
# Fully automated (dunst included)
# =============================

APT_BASE="https://us-central1-apt.pkg.dev/projects/antigravity-auto-updater-dev"
PKG_INDEX_URL="${APT_BASE}/dists/antigravity-debian/main/binary-amd64/Packages"

APP_DIR="/opt/antigravity"
BIN_LINK="/usr/local/bin/antigravity"
DESKTOP1="/usr/share/applications/antigravity.desktop"
DESKTOP2="/usr/share/applications/antigravity-url-handler.desktop"
ICON_PATH="/usr/share/pixmaps/antigravity.png"

# =============================
# UNINSTALL
# =============================
if [[ "${1-}" == "--uninstall" ]]; then
  echo "[*] Uninstalling Antigravity..."
  sudo rm -rf "$APP_DIR" "$BIN_LINK" "$DESKTOP1" "$DESKTOP2" "$ICON_PATH"
  rm -f ~/.config/autostart/dunst.desktop || true
  echo "[+] Removed."
  exit 0
fi

# =============================
# SYSTEM UPDATE (NEW)
# =============================
echo "[*] Updating system packages..."
sudo pacman -Syu --noconfirm
echo "[+] System updated successfully."

# =============================
# DEPENDENCIES (with dunst)
# =============================
echo "[*] Installing required dependencies (libnotify + dunst + chromium libs)..."
sudo pacman -Sy --needed --noconfirm \
  curl bsdtar libnotify dunst nss gtk3 libcups libxss || true

# =============================
# DUNST AUTOSTART FIX
# (solves the Antigravity freeze)
# =============================
echo "[*] Setting up notification daemon (dunst)..."

mkdir -p ~/.config/autostart

cat > ~/.config/autostart/dunst.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Dunst
Exec=dunst
StartupNotify=false
Terminal=false
EOF

# Start dunst instantly if not running
if ! pgrep -x dunst >/dev/null; then
  echo "[*] Starting dunst..."
  dunst &
  sleep 1
fi

echo "[+] Dunst enabled and running"

# =============================
# FETCH PACKAGE INDEX
# =============================
echo "[*] Fetching APT package index..."
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

curl -fsSL "$PKG_INDEX_URL" -o Packages

# =============================
# PARSE LATEST VERSION
# =============================
mapfile -t candidates < <(
  awk '
    function emit() {
      if (in_pkg && ver != "" && file != "" && sha != "") {
        print ver "\t" file "\t" sha
      }
      ver=""; file=""; sha=""
    }

    {
      sub(/\r$/, "", $0)   # CRLF safe
    }

    # nový záznam balíka: ak sme boli v antigravity, emitni pred resetom
    /^Package:[[:space:]]*/ {
      emit()
      in_pkg = ($2 == "antigravity")
      next
    }

    in_pkg && /^Version:[[:space:]]*/  { sub(/^Version:[[:space:]]*/,  "", $0); ver=$0; next }
    in_pkg && /^Filename:[[:space:]]*/ { sub(/^Filename:[[:space:]]*/, "", $0); file=$0; next }
    in_pkg && /^SHA256:[[:space:]]*/   { sub(/^SHA256:[[:space:]]*/,   "", $0); sha=$0; next }

    # koniec stanza (prázdny alebo whitespace-only riadok)
    in_pkg && /^[[:space:]]*$/ { emit(); next }

    END { emit() }
  ' Packages
)

if ((${#candidates[@]} == 0)); then
  echo "[-] Failed to parse any antigravity entries."
  exit 1
fi

latest_ver=""
latest_file=""
latest_sha=""

for line in "${candidates[@]}"; do
  IFS=$'\t' read -r ver file sha <<< "$line"
  if [[ -z "$latest_ver" ]] || dpkg --compare-versions "$ver" gt "$latest_ver"; then
    latest_ver="$ver"
    latest_file="$file"
    latest_sha="$sha"
  fi
done

DEBVER="$latest_ver"
DEBFILENAME="$latest_file"
DEBSHA256="$latest_sha"

echo "[+] Latest version: $DEBVER"
echo "[+] File: $DEBFILENAME"
echo "[+] SHA256: $DEBSHA256"

# =============================
# DOWNLOAD + VERIFY
# =============================
DEB_URL="${APT_BASE}/${DEBFILENAME}"
echo "[*] Downloading package..."
curl -fsSL "$DEB_URL" -o antigravity.deb

echo "[*] Verifying SHA256 checksum..."
echo "${DEBSHA256}  antigravity.deb" | sha256sum -c -

# =============================
# EXTRACT + INSTALL
# =============================
echo "[*] Extracting package..."
bsdtar -xf antigravity.deb
bsdtar -xf data.tar.xz

echo "[*] Installing to $APP_DIR..."
sudo rm -rf "$APP_DIR"
sudo mkdir -p "$APP_DIR"
sudo cp -r usr/share/antigravity/* "$APP_DIR/"

# =============================
# SANDBOX FIX
# =============================
if [[ -f "$APP_DIR/chrome-sandbox" ]]; then
  echo "[*] Fixing sandbox permissions..."
  sudo chown root:root "$APP_DIR/chrome-sandbox"
  sudo chmod 4755 "$APP_DIR/chrome-sandbox"
fi

# =============================
# BINARY LINK
# =============================
echo "[*] Creating launcher..."
sudo ln -sf "$APP_DIR/antigravity" "$BIN_LINK"

# =============================
# DESKTOP FILES
# =============================
echo "[*] Installing desktop entries..."

if [[ -f usr/share/applications/antigravity.desktop ]]; then
  sed 's|^Exec=.*|Exec=/usr/local/bin/antigravity %U|g' \
    usr/share/applications/antigravity.desktop | sudo tee "$DESKTOP1" >/dev/null
fi

if [[ -f usr/share/applications/antigravity-url-handler.desktop ]]; then
  sed 's|^Exec=.*|Exec=/usr/local/bin/antigravity %U|g' \
    usr/share/applications/antigravity-url-handler.desktop | sudo tee "$DESKTOP2" >/dev/null
fi

# =============================
# ICON
# =============================
[[ -f usr/share/pixmaps/antigravity.png ]] && sudo cp usr/share/pixmaps/antigravity.png "$ICON_PATH"

# =============================
# DONE
# =============================
echo
echo "[+] Antigravity $DEBVER installed successfully!"
echo "[+] Notification daemon fixed (dunst auto-start enabled)"
echo "[*] Run app using: antigravity"
echo "[*] Uninstall using: ./antigravity-installer.sh --uninstall"

# =============================
# RESTART PROMPT (NEW)
# =============================
echo
echo "======================================================="
echo "  Installation completed!"
echo "  It is recommended to RESTART your system now "
echo "  to ensure all sandbox + notification services load."
echo "======================================================="
echo
read -p "Do you want to restart now? (y/N): " ans
if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
  echo "[*] Restarting system..."
  sudo reboot
else
  echo "[*] Restart skipped. You can reboot later."
fi
