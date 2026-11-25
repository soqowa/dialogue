#!/bin/zsh
set -euo pipefail
dialog_root="${0:A:h:h}"
dialog_output="$dialog_root/build/Диалог.app"
dialog_signing_identity="${DIALOG_CODESIGN_IDENTITY:-}"
if [[ -z "$dialog_signing_identity" ]]; then
  dialog_signing_identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$dialog_signing_identity" ]]; then
  dialog_signing_identity="-"
  print -u2 -r -- "Нет сертификата Apple Development: используется ad-hoc подпись. После изменения сборки разрешения macOS могут потребовать повторной выдачи."
fi
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build --package-path "$dialog_root/native" -c release
mkdir -p "$dialog_output/Contents/MacOS" "$dialog_output/Contents/Resources"
cp "$dialog_root/native/.build/release/Dialog" "$dialog_output/Contents/MacOS/Dialog"
cp "$dialog_root/native/.build/release/DialogSpeech" "$dialog_output/Contents/MacOS/DialogSpeech"
cp "$dialog_root/native/Info.plist" "$dialog_output/Contents/Info.plist"
# Distribution builds drop debug maps, which list this machine's build paths.
if [[ -n "${DIALOG_DISTRIBUTION:-}" ]]; then
  strip -S -x "$dialog_output/Contents/MacOS/Dialog" "$dialog_output/Contents/MacOS/DialogSpeech"
fi
ditto "$dialog_root/third-party" "$dialog_output/Contents/Resources/ThirdParty"
print -r -- "$dialog_root" > "$dialog_output/Contents/Resources/project-root.txt"
# Redraw when the icon is missing or make-icon.swift changed since the last build.
if [[ ! -f "$dialog_output/Contents/Resources/Dialog.icns" || "$dialog_root/scripts/make-icon.swift" -nt "$dialog_output/Contents/Resources/Dialog.icns" ]]; then
  dialog_icons="$dialog_root/build/Dialog.iconset"
  mkdir -p "$dialog_icons"
  swift "$dialog_root/scripts/make-icon.swift" "$dialog_root/build/icon-1024.png"
  for dialog_size in 16 32 128 256 512; do
    sips -z "$dialog_size" "$dialog_size" "$dialog_root/build/icon-1024.png" --out "$dialog_icons/icon_${dialog_size}x${dialog_size}.png" >/dev/null
    dialog_double=$((dialog_size * 2))
    sips -z "$dialog_double" "$dialog_double" "$dialog_root/build/icon-1024.png" --out "$dialog_icons/icon_${dialog_size}x${dialog_size}@2x.png" >/dev/null
  done
  iconutil -c icns "$dialog_icons" -o "$dialog_output/Contents/Resources/Dialog.icns"
fi
codesign --force --deep --sign "$dialog_signing_identity" --timestamp=none "$dialog_output"
codesign --verify --deep --strict "$dialog_output"
print -r -- "Готово: $dialog_output"
