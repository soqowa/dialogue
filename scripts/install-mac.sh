#!/bin/zsh
set -euo pipefail
dialog_root="${0:A:h:h}"
dialog_destination="/Applications/Диалог.app"
if pgrep -f '^(/Applications/Диалог.app|.*/build/Диалог.app)/Contents/MacOS/Dialog$' >/dev/null; then
  print -u2 -r -- "Сначала завершите «Диалог» через ⌘Q, затем повторите установку."
  exit 1
fi
if [[ -e "$dialog_destination" ]]; then
  dialog_installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dialog_destination/Contents/Info.plist")"
  if [[ "$dialog_installed_id" != "dev.dialog.mac" ]]; then
    print -u2 -r -- "В /Applications уже есть другое приложение с именем «Диалог». Оно не изменено."
    exit 1
  fi
fi
zsh "$dialog_root/scripts/build-mac.sh"
ditto "$dialog_root/build/Диалог.app" "$dialog_destination"
codesign --verify --deep --strict "$dialog_destination"
print -r -- "Установлено: $dialog_destination"
