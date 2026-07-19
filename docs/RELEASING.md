# Releasing Voxi

Descriptive runbook for shipping a signed, notarised DMG to the marketing site. The invariants live in `CLAUDE.md` and `steering/MACOS_PLATFORM.md` (per-config identity split; never publish an unnotarised artifact); this doc is the procedure.

## Prerequisites (one-time, already done on Colin's Mac)

- "Developer ID Application" certificate in the login keychain (created via Xcode → Settings → Accounts → Manage Certificates).
- notarytool keychain profile `voxi-notary` (`xcrun notarytool store-credentials voxi-notary --apple-id … --team-id F7H963S3B4` with an app-specific password).
- `gh` authenticated; the marketing site repo's Cloudflare secrets configured (see that repo's `docs/DEPLOYMENT.md`).

## Procedure

1. **Bump versions** in `project.yml`: `CFBundleShortVersionString` (X.Y.Z) and `CFBundleVersion` (monotonic integer — bump on every release, including re-releases of the same marketing version). Commit.
2. **Build**: `./Scripts/release.sh X.Y.Z`. Stages: preflight → xcodegen → Release archive → export → signature checks → notarise + staple the .app → DMG (signed) → notarise + staple the DMG → Gatekeeper assessment. Fails closed at every gate. `--skip-notarise` runs only the local stages (useful for shaking out build issues without notarisation round-trips).
3. **Manual verification** (required before publishing; hardened runtime and TCC cannot be verified headlessly):
   - Quarantine-simulate: `xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" dist/Voxi-X.Y.Z.dmg`, open, drag to /Applications, launch. Expect the Gatekeeper "verified" flow, no malware warning.
   - Expect TCC re-prompts on the dev machine (Release presents a different identity than the Debug build — see `steering/MACOS_PLATFORM.md`).
   - End-to-end dictation into another app; a Parakeet transcription (model load under hardened runtime); one card dispatch (subprocess spawn); CLI harness `--dictate` from the installed binary; login-item toggle.
4. **Tag + publish**:
   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   gh release create vX.Y.Z dist/Voxi-X.Y.Z.dmg --repo trickycdm/voxi --title "Voxi X.Y.Z" --generate-notes
   URL=$(gh release view vX.Y.Z --repo trickycdm/voxi --json assets -q '.assets[0].url')
   gh workflow run publish-dmg.yml --repo trickycdm/voxi-marketing-site -F dmg_url="$URL" -F version=X.Y.Z
   ```
   The workflow uploads to R2 as the stable `Voxi.dmg` key plus `Voxi-X.Y.Z.dmg`.
5. **Post-publish gate**: download `https://voxi-site.soft-frost-24fb.workers.dev/download/Voxi.dmg` in a real browser, install, confirm Gatekeeper accepts.

## Rollback

Re-publish the previous versioned DMG to the stable key:
`gh workflow run publish-dmg.yml --repo trickycdm/voxi-marketing-site -F dmg_url=<previous release asset URL> -F version=<prev>` — the stable `Voxi.dmg` key is a moving pointer; versioned keys are immutable history.

## Notes

- The DMG is ~10 MB; ASR models (~600 MB for Parakeet) download on first run to `~/Library/Application Support/Voxi/Models`.
- dSYMs for crash symbolication stay in `dist/Voxi.xcarchive` — keep the archive for released versions (copy aside before the next release wipes `dist/`).
- No auto-updater yet: users re-download the DMG. Sparkle is the natural follow-up (CFBundleVersion is kept monotonic partly for it).
