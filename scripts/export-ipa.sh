#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || ( "$1" != --unsigned && "$1" != --signed ) ]]; then
    printf '%s\n' 'Uso: bash scripts/export-ipa.sh --unsigned CARPETA' \
        '     XUPER_DEVELOPMENT_TEAM=EQUIPO bash scripts/export-ipa.sh --signed CARPETA' >&2
    exit 2
fi

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null; then
    printf '%s\n' 'La exportación requiere macOS con Xcode.' >&2
    exit 1
fi

mode="$1"
destination="$2"
if [[ "$mode" == --signed && -z "${XUPER_DEVELOPMENT_TEAM:-}" ]]; then
    printf '%s\n' 'Indica el identificador de equipo en XUPER_DEVELOPMENT_TEAM.' >&2
    exit 2
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/xuperios.XXXXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
build=(xcodebuild -project "$project_dir/XuperiOS.xcodeproj" -scheme XuperiOS
       -configuration Release -destination 'generic/platform=iOS')
if [[ -n "${XUPER_BUNDLE_IDENTIFIER:-}" ]]; then
    build+=("PRODUCT_BUNDLE_IDENTIFIER=$XUPER_BUNDLE_IDENTIFIER")
fi

if [[ "$mode" == --unsigned ]]; then
    ipa_name=XuperiOS-unsigned.ipa
    "${build[@]}" -derivedDataPath "$work_dir/build" CODE_SIGNING_ALLOWED=NO build
    app="$work_dir/build/Build/Products/Release-iphoneos/XuperiOS.app"
    mkdir "$work_dir/Payload"
    ditto "$app" "$work_dir/Payload/XuperiOS.app"
    (cd "$work_dir" && ditto -c -k --keepParent Payload "$ipa_name")
    source_ipa="$work_dir/$ipa_name"
else
    ipa_name=XuperiOS.ipa
    archive="$work_dir/XuperiOS.xcarchive"
    options="$work_dir/ExportOptions.plist"
    /usr/libexec/PlistBuddy -c 'Add :method string release-testing' \
        -c 'Add :signingStyle string automatic' "$options"
    "${build[@]}" -archivePath "$archive" \
        "DEVELOPMENT_TEAM=$XUPER_DEVELOPMENT_TEAM" -allowProvisioningUpdates archive
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$options" \
        -exportPath "$work_dir/export" -allowProvisioningUpdates
    source_ipa="$work_dir/export/$ipa_name"
fi

unzip -tq "$source_ipa" >/dev/null
ditto -x -k "$source_ipa" "$work_dir/verify"
app="$work_dir/verify/Payload/XuperiOS.app"
lipo -verify_arch arm64 "$app/XuperiOS"
if [[ "$mode" == --signed ]]; then
    test -f "$app/embedded.mobileprovision"
    codesign --verify --strict "$app"
fi
cp "$source_ipa" "$destination/$ipa_name"
printf '%s\n' "$destination/$ipa_name"
