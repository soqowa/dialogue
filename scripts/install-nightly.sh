#!/bin/zsh
# Installs the current working copy as a separate app, «Диалог Nightly»,
# next to the regular /Applications/Диалог.app without touching it.
set -euo pipefail
dialog_root="${0:A:h:h}"
nightly_name="Диалог Nightly"
nightly_id="dev.dialog.mac.nightly"
nightly_destination="/Applications/$nightly_name.app"

if pgrep -f "^$nightly_destination/Contents/MacOS/Dialog\$" >/dev/null; then
  print -u2 -r -- "Сначала завершите «$nightly_name» через ⌘Q, затем повторите установку."
  exit 1
fi

zsh "$dialog_root/scripts/build-mac.sh"

nightly_stage="$dialog_root/build/$nightly_name.app"
rm -rf "$nightly_stage"
ditto "$dialog_root/build/Диалог.app" "$nightly_stage"
plist="$nightly_stage/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $nightly_id" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $nightly_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $nightly_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$plist"

dialog_signing_identity="${DIALOG_CODESIGN_IDENTITY:-}"
if [[ -z "$dialog_signing_identity" ]]; then
  dialog_signing_identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
fi
codesign --force --deep --sign "${dialog_signing_identity:--}" --timestamp=none "$nightly_stage"

rm -rf "$nightly_destination"
ditto "$nightly_stage" "$nightly_destination"
codesign --verify --deep --strict "$nightly_destination"

# First install: start from the regular app's settings (model, shortcut, microphone…).
if ! defaults read "$nightly_id" dialog.preferences >/dev/null 2>&1 \
   && defaults read dev.dialog.mac dialog.preferences >/dev/null 2>&1; then
  defaults export dev.dialog.mac - | defaults import "$nightly_id" -
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$nightly_destination"
print -r -- "Установлено: $nightly_destination"
