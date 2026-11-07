# Releasing XYZ

A checklist plus the record of what has been run. On 2026-11-07 the full signing and
notarization path was run on the owner's Mac: a Developer ID certificate exists, a
notary credential is in the keychain, and a signed, notarized, stapled DMG was accepted
by Gatekeeper. Nothing is tagged or published yet. The cloud check is still unsigned on
purpose (`CODE_SIGNING_ALLOWED=NO`), so it cannot replace the checks below.

## What the cloud check does not cover

The Debug/Release build, the package tests, the CLI tests, and the launch checks pass,
but the app there is ad-hoc signed with no entitlements. The sandbox, iCloud,
security-scoped bookmarks, the quit alert, and the tab restore are not exercised. The
acceptance gate has never passed (0/7); the failures are recorded in `CHANGELOG.md`
0.5.28.

## One-time setup on the release Mac

1. Xcode → Settings… → Accounts has the team (`Z4FMG2KTPM`) signed in.
2. A `Developer ID Application` certificate is in the login keychain. Check:

   ```sh
   security find-identity -v -p codesigning
   # Developer ID Application: Zhichao Li (Z4FMG2KTPM)
   ```

   It was created 2026-11-07 through developer.apple.com (Certificates, Identifiers &
   Profiles → Certificates → + → Developer ID Application) with a CSR made in Keychain
   Access → Certificate Assistant. Xcode's Manage Certificates pane refused with
   "This operation can only be performed by the Account Holder." before the updated
   Program License Agreement was accepted; the web path worked after that.
3. A notary credential is in the keychain:

   ```sh
   xcrun notarytool store-credentials "xyz-notary" \
     --apple-id "x@lizhichao.com" --team-id Z4FMG2KTPM
   ```

   The app-specific password comes from appleid.apple.com → Sign-In and Security →
   App-Specific Passwords. The profile name used here is `xyz-notary`.
4. `Config/Local.xcconfig` holds `DEVELOPMENT_TEAM = Z4FMG2KTPM` (not committed).

## Steps

1. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in `Config/Base.xcconfig`
   only; the cloud check reads them out of the built `Info.plist`.
2. Push the branch and get the cloud check green, or record which acceptance cases
   fail. Do not tag a red build.
3. Archive and export:

   ```sh
   xcodebuild -project XYZ.xcodeproj -scheme XYZ -configuration Release \
     -destination 'platform=macOS' -archivePath build/XYZ.xcarchive \
     -allowProvisioningUpdates archive

   xcodebuild -exportArchive -archivePath build/XYZ.xcarchive \
     -exportPath build/export -exportOptionsPlist tools/ExportOptions.plist \
     -allowProvisioningUpdates
   ```

   `tools/ExportOptions.plist` uses `method = developer-id`, automatic signing, and the
   team id.
4. Inspect the exported app:

   ```sh
   codesign -dv --verbose=4 build/export/XYZ.app
   #   Authority=Developer ID Application: Zhichao Li (Z4FMG2KTPM)
   #   CodeDirectory flags=0x10000(runtime)
   codesign -d --entitlements :- build/export/XYZ.app
   #   app-sandbox, network.client, user-selected read-write, app-scope bookmarks,
   #   iCloud CloudDocuments; get-task-allow is absent in this build
   ```

5. Zip and notarize the app (the zip is what gets submitted; the app is what gets
   stapled):

   ```sh
   ditto -c -k --keepParent build/export/XYZ.app "build/XYZ-<version>.zip"
   xcrun notarytool submit "build/XYZ-<version>.zip" --keychain-profile xyz-notary --wait
   xcrun stapler staple build/export/XYZ.app
   xcrun stapler validate build/export/XYZ.app
   spctl -a -vv --type execute build/export/XYZ.app   # accepted, source=Notarized Developer ID
   ```

6. Optional but nicer to download: sign the DMG, notarize it, staple it.

   ```sh
   hdiutil create -volname XYZ -srcfolder build/export/XYZ.app -ov -format UDZO \
     "build/XYZ-<version>.dmg"
   codesign --force --sign "Developer ID Application: Zhichao Li (Z4FMG2KTPM)" \
     --timestamp "build/XYZ-<version>.dmg"
   xcrun notarytool submit "build/XYZ-<version>.dmg" --keychain-profile xyz-notary --wait
   xcrun stapler staple "build/XYZ-<version>.dmg"
   xcrun stapler validate "build/XYZ-<version>.dmg"
   spctl -a -t open --context context:primary-signature -vv "build/XYZ-<version>.dmg"
   ```

7. Open the stapled app and run the manual check that CI cannot: open a folder through
   the panel, quit with unsaved edits, reopen and look for the restored tabs, open a
   note with a relative picture and one with a bad remote picture, switch the app
   language to 简体中文, and type Chinese through a real input method.
8. Leave one app on the machine. Quit the running app, replace
   `/Applications/XYZ.app` with `ditto build/export/XYZ.app /Applications/XYZ.app`,
   then delete the other bundles (`find build -name XYZ.app -type d -exec rm -rf {} +`,
   plus any mounted DMG, `/tmp`, Desktop, Downloads), and check that
   `mdfind "kMDItemCFBundleIdentifier == 'com.lizhichao.XYZ'"` prints only
   `/Applications/XYZ.app`. Keep the current DMG/ZIP and delete older versions.
   `AGENTS.md` states this rule for agents.
9. Tag the commit that was archived: `git tag -a v<version> -m "XYZ <version>"`, push
   the tag, and attach the notarized DMG to the release. The `CHANGELOG.md` entry for
   that version is the release note.
10. iOS goes through TestFlight with the same team. The document browser needs the iCloud
    container entitlement, which an unsigned build does not carry.

## What still blocks a release

- No tag, no GitHub release, and no release workflow: everything above is run by hand.
- The acceptance gate has not passed, so the window checks are evidence, not a pass.
- The installed build is 0.5.27 (build 43), signed with an Apple Development
  certificate; the notarized 0.5.29 build exists only as a local artifact.
- No manual verification on a real screen has been recorded for this build.

## Record: 2026-11-07

Run on the owner's Mac, macOS 27.2, Xcode 27.2, team `Z4FMG2KTPM`.

The same path was run again later that day for 0.5.30 (build 46), a sidebar-toggle
performance fix: archive and `developer-id` export succeeded, the app zip was notarized
(`91461877-697d-4be0-8b9b-642c19195825`, Accepted) and stapled, the DMG was signed,
notarized (`239efb06-f903-4ce5-8f2a-9424dae80c2d`, Accepted), stapled, and accepted by
`spctl`. 0.5.30 is the installed build; it was launched hidden once with no crash report.
The sidebar toggle itself was not exercised by a harness, so its feel is the owner's
check.

- Certificate: `Developer ID Application: Zhichao Li (Z4FMG2KTPM)`, created
  2026-11-07; `security find-identity -v -p codesigning` lists it.
- Archive: `build/XYZ.xcarchive`, version 0.5.29 (build 45).
- Export: `method = developer-id`, automatic signing; embedded profile
  `Mac Team Direct Provisioning Profile: com.lizhichao.XYZ`, expiration 2044-11-02;
  iCloud container environment `Production`.
- Notarization of the app zip: submission `0e54a40b-e359-4159-9fbf-e9c066ed37ff`,
  status **Accepted**.
- `xcrun stapler staple` and `validate` on `build/export/XYZ.app`: worked.
- `spctl -a -vv --type execute build/export/XYZ.app`: **accepted**,
  `source=Notarized Developer ID`, `origin=Developer ID Application: Zhichao Li (Z4FMG2KTPM)`.
- DMG `build/XYZ-0.5.29.dmg`: code-signed with the Developer ID identity, notarized
  (submission `a0e37293-3755-4566-908b-f48ac56616ed`, **Accepted**), stapled;
  `spctl -a -t open --context context:primary-signature -vv` reports **accepted**,
  `source=Notarized Developer ID`.
- Installed: the notarized build was copied over `/Applications/XYZ.app` on 2026-11-07.
  The previous 0.5.27 was moved aside for the swap and deleted once this build passed
  its launch check, so the machine keeps one app and no rollback copy. It was launched
  hidden once: the process came up and stayed up, with no crash report, then quit. No
  window was used.
- Not touched: the sandbox/iCloud/quit behaviour and the
  Chinese UI are still unverified in an interactive session. No tag, no upload.
