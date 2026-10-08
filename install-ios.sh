#!/bin/zsh
# Compila o DBDeck para iOS e instala.
#
#   ./install-ios.sh                 → simulador já aberto (ou "iPhone 17")
#   ./install-ios.sh device TEAMID   → iPhone/iPad conectado, assinado com o seu time
#
# No aparelho, o primeiro uso pede confiar no desenvolvedor em
# Ajustes › Geral › VPN e Gerenciamento de Dispositivos.
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodegen generate

if [[ "${1:-}" == "device" ]]; then
    team="${2:?informe o Team ID: ./install-ios.sh device ABCDE12345}"
    xcodebuild -project DBDeck.xcodeproj -scheme DBDeckMobile -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath build/ios-device \
        -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" -quiet build
    app=build/ios-device/Build/Products/Release-iphoneos/DBDeck.app
    # A listagem do devicectl mistura simuladores e aparelhos: só os físicos pareados servem.
    devices_json=$(mktemp)
    xcrun devicectl list devices --json-output "$devices_json" >/dev/null
    device=$(python3 -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
physical = [d for d in devices if d.get("hardwareProperties", {}).get("reality") == "physical"
            and d.get("connectionProperties", {}).get("pairingState") == "paired"]
print(physical[0]["identifier"] if physical else "")
' "$devices_json")
    rm -f "$devices_json"
    [[ -n "$device" ]] || { echo "Nenhum iPhone/iPad pareado encontrado." >&2; exit 1; }
    xcrun devicectl device install app --device "$device" "$app"
    # Aparelho bloqueado recusa abrir o app — a instalação já valeu, então não é erro.
    xcrun devicectl device process launch --device "$device" br.dev.dbdeck.mobile >/dev/null 2>&1 \
        || echo "Instalado. Desbloqueie o aparelho e abra o DBDeck."
else
    sim=$(xcrun simctl list devices booted | awk -F '[()]' '/iPhone|iPad/ {print $2; exit}')
    if [[ -z "$sim" ]]; then
        sim=$(xcrun simctl list devices available | awk -F '[()]' '/iPhone 17 / {print $2; exit}')
        xcrun simctl boot "$sim"
        open -a Simulator
    fi
    xcodebuild -project DBDeck.xcodeproj -scheme DBDeckMobile -configuration Debug \
        -destination "id=$sim" -derivedDataPath build/ios-sim -quiet build
    xcrun simctl install "$sim" build/ios-sim/Build/Products/Debug-iphonesimulator/DBDeck.app
    xcrun simctl launch "$sim" br.dev.dbdeck.mobile
fi
echo "✓ DBDeck iOS instalado"
