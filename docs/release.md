# Releasing XYZ

A checklist plus the record of what has been run. The full signing and notarization path
runs on the owner's Mac: a Developer ID certificate exists, a notary credential is in the
keychain, and the app plus DMG are signed, notarized, stapled, and accepted by Gatekeeper.
The releases from 0.5.36 on are published; see the dated records at the end. The cloud
check is unsigned on purpose (`CODE_SIGNING_ALLOWED=NO`), so it cannot replace the checks
below.

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
   language to Simplified Chinese, and type Chinese through a real input method.
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

## Current state

- Direct download is Developer ID plus notarization. There is no Mac App Store build: the
  sandbox temporary exception for the two bin folders would have to be removed first.
- Everything above is still run by hand. GitHub Actions stays disabled at the owner's
  request, so a push starts no workflow.
- `-XYZCheckGutter` passes its functional cases (typography, fonts, folding, gutter,
  sidebar arrows, refresh, file creation). The five older window-gesture cases
  (`nested-file`, `collapse-header`, `dividers`, `mode-labels`, `empty-line-prefs`) still
  fail on this Mac because the window is inactive while the harness runs, and the
  window-picture OCR probes (`window-switch`, `dark-nowrap-body`) misread the mixed
  Chinese/emoji fixture on some runs. Those checks are evidence, not a pass.
- Step 7 (folder panel, quit alert, iCloud, real input method) still needs the owner.
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

0.5.31 (build 47) went through the same path on the same day after the sidebar-animation
work: archive and export succeeded, the app zip was notarized
(`ae1b56da-b042-46ac-a983-55daece1822e`, Accepted) and stapled, the DMG was signed,
notarized (`3229b1fa-6c13-41a9-b203-6d9f3c347156`, Accepted), stapled, and `spctl`
accepted both. 0.5.31 replaces 0.5.30 in `/Applications` and is the only `XYZ.app` on
the machine; it was launched hidden once with no crash report. The owner confirmed the
slide and the sidebar text on the running app ("done").

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

## 0.5.35 on 2026-11-07

The sidebar round (folder clicks, selection, rapid clicking, disclosure drawing) ended at
0.5.35 (build 51). It went through the whole path:

- Archive `build/XYZ.xcarchive` (51) and Developer ID export to `build/export/XYZ.app`.
- App zip notarized: submission `110ef669-88d7-4554-8819-1a0117cedf8a`, **Accepted**;
  `stapler staple` and `validate` worked; `spctl -a -vv --type execute` reports
  **accepted**, `source=Notarized Developer ID`.
- DMG `build/XYZ-0.5.35.dmg`: code-signed with the Developer ID identity, notarized
  (submission `70cdb64f-4af1-478b-86ea-29cc7b2456b2`, **Accepted**), stapled;
  `spctl -a -t open --context context:primary-signature -vv` reports **accepted**.
- Installed over `/Applications/XYZ.app`; `mdfind` lists only that bundle. The hidden
  launch check was used after earlier builds; the owner then ran the interactive checks
  (open/close folders, rapid clicking, selection, open-file marker, scoped
  Collapse/Expand button) and confirmed the sidebar is "much smoother".
- Not touched: tag, upload, GitHub release. Everything unverified in 0.5.29 stays
  unverified (sandbox/iCloud/quit behaviour, Chinese UI).

## 0.5.36 on 2026-11-07

The performance follow-up to 0.5.35 (background index scan no longer rebuilds the sidebar;
opening a folder patches the index in place instead of walking the vault). Same path:

- Archive `build/XYZ.xcarchive` (52) and Developer ID export to `build/export/XYZ.app`.
- App zip notarized: submission `eb83c100-89a4-4706-bb03-514d743f7294`, **Accepted**;
  stapled and validated; `spctl -a -vv --type execute` **accepted**,
  `source=Notarized Developer ID`.
- DMG `build/XYZ-0.5.36.dmg`: signed with the Developer ID identity, notarized
  (submission `1339a0e1-7c43-4194-8a9d-9c7e48674d3d`, **Accepted**), stapled;
  `spctl -a -t open --context context:primary-signature -vv` **accepted**.
- Installed over `/Applications/XYZ.app`; `mdfind` lists only that bundle. The owner had
  already tried the equivalent test build and called the performance "good enough".

## 0.5.37 on 2026-11-08

The title-bar, sidebar-toggle and width-memory round. Same path:

- Archive `build/XYZ.xcarchive` (53) and Developer ID export to `build/export/XYZ.app`.
- App zip notarized: submission `c0ccb3e8-322e-4793-8d2a-0e6304527be3`, **Accepted**;
  stapled and validated; `spctl -a -vv --type execute` **accepted**,
  `source=Notarized Developer ID`, `origin=Developer ID Application: Zhichao Li (Z4FMG2KTPM)`.
- DMG `build/XYZ-0.5.37.dmg`: signed with the Developer ID identity, notarized
  (submission `4e609d87-c848-420a-a141-4bcc7e7a00c3`, **Accepted**), stapled;
  `spctl -a -t open --context context:primary-signature -vv` **accepted**.
- Installed over `/Applications/XYZ.app`; `mdfind` lists only that bundle. Hidden launch
  (`open -j`), process up, quit — clean.
- Tests before the build: `swift test --package-path XYZCore` 220/0 and
  `sh Scripts/xyz-test.sh` 8/8. `-XYZCheckGutter`: `refresh` passes; the other five cases
  still fail on this Mac for the inactive-window reason.
- Tagged `v0.5.37` (annotated, on commit `55d5ccb`) and published:
  <https://github.com/lizhichaox/XYZ/releases/tag/v0.5.37> with `XYZ-0.5.37.dmg` and
  `XYZ-0.5.37.zip` as assets. The branch `fix/priority-fixes` was pushed, then merged
  fast-forward into `main`; the GitHub Actions workflow was disabled (and then removed)
  at the owner's request, so pushes no longer start a run.

## 0.5.38 on 2026-11-08

The editor reading aids, code folding and product-boundary round. Local install, then
tagged `v0.5.38`; no GitHub release page (the owner chose B).

- Archive `build/XYZ.xcarchive` (54) and Developer ID export to `build/export/XYZ.app`.
- App zip notarized: submission `8fa6f52b-6de1-45ce-be4e-2dc4b64d6b03`, **Accepted**;
  stapled and validated; `spctl -a -vv --type execute` **accepted**,
  `source=Notarized Developer ID`, `origin=Developer ID Application: Zhichao Li (Z4FMG2KTPM)`.
- Installed over `/Applications/XYZ.app`; `mdfind` lists only that bundle. Hidden launch
  (`open -j`), process up, quit — clean.
- Tests before the build: `swift test --package-path XYZCore` 246/0 and
  `sh Scripts/xyz-test.sh` 8/8. `-XYZCheckGutter`: the new editor/folding/sidebar cases
  pass; the five older cases still fail on this Mac for the inactive-window reason.
- Merged `feat/editor-code-viewing` fast-forward into `main`; old DMG/ZIP artifacts
  removed, `build/` holds only `XYZ-0.5.38.zip`. GitHub Actions stays disabled.

## 0.5.39 on 2026-11-08

The theme, fixed bilingual typography, settings/About/Help, new icon, linked notes and
`xyz` command round.

- Archive `build/XYZ.xcarchive` (55) and Developer ID export to `build/export/XYZ.app`.
- App zip notarized: submission `d8d57e96-0f65-4790-a592-c6c3e987c43e`, **Accepted**;
  stapled and validated; `spctl -a -vv --type execute` **accepted**,
  `source=Notarized Developer ID`, `origin=Developer ID Application: Zhichao Li (Z4FMG2KTPM)`.
- DMG `build/XYZ-0.5.39.dmg`: signed with the Developer ID identity, notarized
  (submission `9e5757e6-58d0-43d8-b459-4ace7df99fac`, **Accepted**), stapled;
  `spctl -a -t open --context context:primary-signature -vv` **accepted**.
  SHA-256 `0094bf7f019f51948f28dfd13dbdcb9902f9c9e6597a6f7378ec7c5853e60690`.
- Zip asset `build/XYZ-0.5.39.zip` (stapled app), SHA-256
  `53a13c71b4d8730e5080a7f090c0a5a41da07c0436a7e792322b0f28e8f6489a`.
- Installed over `/Applications/XYZ.app`; `mdfind` lists only that bundle. Hidden launch
  (`open -j`), process up, quit — clean.
- Tests before the build: `swift test --package-path XYZCore` 259/0 and
  `sh Scripts/xyz-test.sh` 8/8. `-XYZCheckGutter` on the exported build: every functional
  case passes; two release runs misread the window-picture probes as described above.
- Merged `fix/editor-typography` fast-forward into `main`; tagged `v0.5.39` (annotated,
  on `d9f1557`) and published:
  <https://github.com/lizhichaox/XYZ/releases/tag/v0.5.39> with `XYZ-0.5.39.dmg` and
  `XYZ-0.5.39.zip` as assets.
