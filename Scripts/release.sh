#!/bin/zsh
# release.sh — build, sign, notarise, and package Voxi for distribution.
#
#   ./Scripts/release.sh X.Y.Z [--skip-notarise]
#
# Produces dist/Voxi-X.Y.Z.dmg: Release build signed "Developer ID Application"
# with hardened runtime, notarised and stapled twice (the .app before the DMG is
# built, then the DMG itself) so installs verify offline. Publishing is a human
# step — the script prints the commands at the end (docs/RELEASING.md).
#
# --skip-notarise stops after the local signature checks (stage 4): everything
# that can be verified without spending a notarisation round-trip.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/export/Voxi.app"
PROFILE="voxi-notary"

log()  { print -P "%F{green}==>%f $1"; }
die()  { print -P "%F{red}error:%f $1" >&2; exit 1; }

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: release.sh X.Y.Z [--skip-notarise]"
SKIP_NOTARISE=false
[[ "${2:-}" == "--skip-notarise" ]] && SKIP_NOTARISE=true

# --- 1. Preflight ------------------------------------------------------------
log "preflight"
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "working tree not clean — commit or stash first"
grep -q "CFBundleShortVersionString: \"$VERSION\"" "$ROOT/project.yml" \
  || die "version $VERSION does not match CFBundleShortVersionString in project.yml"
if git -C "$ROOT" tag -l "v$VERSION" | grep -q .; then
  print -P "%F{yellow}warning:%f tag v$VERSION already exists — re-releasing the same version?"
fi
security find-identity -v -p codesigning | grep -q "Developer ID Application: Colin Mackenzie (F7H963S3B4)" \
  || die "Developer ID Application certificate not in keychain"
if ! $SKIP_NOTARISE; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '$PROFILE' missing or invalid"
fi

# --- 2. Generate + archive + export -----------------------------------------
log "xcodegen generate"
(cd "$ROOT" && xcodegen generate >/dev/null)

log "archive (Release, Developer ID, hardened runtime)"
rm -rf "$DIST"
mkdir -p "$DIST"
xcodebuild -project "$ROOT/Voxi.xcodeproj" -scheme Voxi -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$DIST/Voxi.xcarchive" archive -quiet

log "export archive"
xcodebuild -exportArchive -archivePath "$DIST/Voxi.xcarchive" \
  -exportOptionsPlist "$ROOT/Scripts/exportOptions.plist" -exportPath "$DIST/export" -quiet

# --- 3. Verify signature -----------------------------------------------------
log "verify signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Capture once, grep the variable: `codesign | grep -q` under pipefail dies on
# grep's early exit (SIGPIPE) even when the pattern matched.
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application: Colin Mackenzie (F7H963S3B4)" <<< "$SIGN_INFO" \
  || die "app is not signed with the Developer ID identity"
grep -q "flags=0x10000(runtime)" <<< "$SIGN_INFO" \
  || die "hardened runtime flag missing"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
grep -q "device.audio-input" <<< "$ENTITLEMENTS" \
  || die "entitlements did not survive export"
BUILT="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
[[ "$BUILT" == "$VERSION" ]] || die "built app reports $BUILT, expected $VERSION"
[[ ! -e "$APP/Contents/PlugIns" ]] || die "Debug/test artifacts present in Release bundle"
log "signature ok: Developer ID, hardened runtime, entitlements intact, v$VERSION"

if $SKIP_NOTARISE; then
  log "--skip-notarise: stopping after local verification"
  exit 0
fi

# --- 4. Notarise + staple the app -------------------------------------------
log "notarise app (submission 1/2)"
ditto -c -k --keepParent "$APP" "$DIST/Voxi-$VERSION.zip"
xcrun notarytool submit "$DIST/Voxi-$VERSION.zip" --keychain-profile "$PROFILE" --wait \
  | tee "$DIST/notary-app.log"
grep -q "status: Accepted" "$DIST/notary-app.log" || die "app notarisation not Accepted (see dist/notary-app.log; use 'notarytool log <id>' for detail)"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# --- 5. Build the DMG from the stapled app -----------------------------------
log "build DMG"
STAGING="$DIST/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Voxi.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Voxi" -srcfolder "$STAGING" -ov -format UDZO -quiet \
  "$DIST/Voxi-$VERSION.dmg"

# --- 6. Notarise + staple the DMG --------------------------------------------
log "notarise DMG (submission 2/2)"
xcrun notarytool submit "$DIST/Voxi-$VERSION.dmg" --keychain-profile "$PROFILE" --wait \
  | tee "$DIST/notary-dmg.log"
grep -q "status: Accepted" "$DIST/notary-dmg.log" || die "DMG notarisation not Accepted (see dist/notary-dmg.log)"
xcrun stapler staple "$DIST/Voxi-$VERSION.dmg"
xcrun stapler validate "$DIST/Voxi-$VERSION.dmg"

# --- 7. Gatekeeper assessment ------------------------------------------------
log "Gatekeeper assessment"
APP_ASSESS="$(spctl -a -t exec -vv "$APP" 2>&1 || true)"
grep -q "accepted" <<< "$APP_ASSESS" || die "spctl rejected the app: $APP_ASSESS"
DMG_ASSESS="$(spctl -a -t open --context context:primary-signature -vv "$DIST/Voxi-$VERSION.dmg" 2>&1 || true)"
grep -q "accepted" <<< "$DMG_ASSESS" || die "spctl rejected the DMG: $DMG_ASSESS"

# --- 8. Summary --------------------------------------------------------------
DMG="$DIST/Voxi-$VERSION.dmg"
log "release build complete"
print "  artifact : $DMG"
print "  size     : $(du -h "$DMG" | cut -f1)"
print "  sha256   : $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
print ""
print "Next (after the manual verification checklist in docs/RELEASING.md):"
print "  git tag v$VERSION && git push origin v$VERSION"
print "  gh release create v$VERSION '$DMG' --repo trickycdm/voxi --title 'Voxi $VERSION' --generate-notes"
print "  URL=\$(gh release view v$VERSION --repo trickycdm/voxi --json assets -q '.assets[0].url')"
print "  gh workflow run publish-dmg.yml --repo trickycdm/voxi-marketing-site -F dmg_url=\"\$URL\" -F version=$VERSION"
