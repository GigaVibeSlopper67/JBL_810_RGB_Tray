#!/usr/bin/env bash
set -euo pipefail

APP_NAME="jbl-quantum910-tray"

SHARE_DIR="${HOME}/.local/share/${APP_NAME}"
WRAPPER_PATH="${HOME}/.local/bin/${APP_NAME}"
SERVICE_PATH="${HOME}/.config/systemd/user/jbl-quantum910-tray.service"
DESKTOP_PATH="${HOME}/.config/autostart/jbl-quantum910-tray.desktop"
LAUNCHER_PATH="${HOME}/.local/share/applications/jbl-quantum910-tray.desktop"
ICON_PATH="${HOME}/.local/share/icons/hicolor/scalable/apps/jbl-quantum910-tray.svg"

echo "==> Removing ${APP_NAME} (user-level)"

if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^jbl-quantum910-tray\.service'; then
    systemctl --user disable --now jbl-quantum910-tray.service || true
  fi
  rm -f "${SERVICE_PATH}" || true
  systemctl --user daemon-reload || true
fi

rm -f "${DESKTOP_PATH}" || true
rm -f "${LAUNCHER_PATH}" || true
rm -f "${ICON_PATH}" || true
rm -f "${WRAPPER_PATH}" || true
rm -rf "${SHARE_DIR}" || true

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
fi

# On XDG-autostart systems there is no service to stop the running tray.
pkill -f jbl_quantum910_tray.py 2>/dev/null || true

echo "OK. Removed."

