#!/bin/zsh
# Compila o DBDeck em Release, instala em /Applications e re-assina o bundle.
# A re-assinatura é obrigatória: com assinatura ad-hoc, app e framework embutido
# precisam da MESMA identidade, senão o dyld recusa o DBDeckCore ("different Team IDs").
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project DBDeck.xcodeproj -scheme DBDeck -configuration Release \
    -destination 'platform=macOS' -quiet build

apps=(~/Library/Developer/Xcode/DerivedData/DBDeck-*/Build/Products/Release/DBDeck.app)
app="${apps[1]}"

pkill -x DBDeck 2>/dev/null || true
rm -rf /Applications/DBDeck.app
ditto "$app" /Applications/DBDeck.app
codesign --force --sign - /Applications/DBDeck.app/Contents/Frameworks/DBDeckCore.framework
codesign --force --sign - /Applications/DBDeck.app

echo "✓ DBDeck instalado em /Applications"
open /Applications/DBDeck.app
