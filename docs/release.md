# Releasing XYZ

This is a checklist, not a record of a release. Nothing below has been run for a
tagged build in this tree: there is no Developer ID certificate and no notary
credential here, and `git tag` is empty. The cloud check builds unsigned on purpose
(`CODE_SIGNING_ALLOWED=NO` plus an ad-hoc signature added one step later), so it does
not show what a signed, sandboxed build does.

## What the cloud check does and does not prove

It proves that the Swift package tests, the `xyz` command tests, a Debug and a Release
macOS build, an iOS Simulator build, and the window self-checks finish. It does not
prove that iCloud, security-scoped bookmarks, the sandbox, or the app's entitlements
work: the ad-hoc signed build has no entitlements. The acceptance gate has never passed
(0/7); the failures are recorded in `CHANGELOG.md` 0.5.28.

## Steps

1. Let the change set settle. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` live in
   `Config/Base.xcconfig` only; the cloud check reads them back out of the built
   `Info.plist`, so a mismatch fails the build before a tag exists.
2. Push the branch and get the cloud check green, or record which cases fail and why.
   Do not tag a red build.
3. On a Mac with a Developer ID Application certificate, write a local
   `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <team id>`. `Base.xcconfig` includes
   it when it exists and the file is not committed. Do not also set the team in the
   target's build settings: the project file wins over the xcconfig.
4. Turn Hardened Runtime on for the signed build. It is off in the project today so the
   unsigned cloud build succeeds; notarization requires it on.
5. Archive and export:

   ```sh
   xcodebuild -project XYZ.xcodeproj -scheme XYZ -configuration Release \
     -destination 'platform=macOS' -archivePath build/XYZ.xcarchive archive
   xcodebuild -exportArchive -archivePath build/XYZ.xcarchive \
     -exportPath build/export -exportOptionsPlist <export options with Developer ID>
   ```
6. Check the result before notarizing:

   ```sh
   codesign -dv --verbose=4 build/export/XYZ.app        # Developer ID, Runtime flag
   codesign -d --entitlements :- build/export/XYZ.app   # sandbox, network.client,
                                                        # user-selected files, bookmarks, iCloud
   spctl -a -vv --type execute build/export/XYZ.app
   ```

   The entitlements must match `XYZ/XYZ-macOS.entitlements`. A build that lacks the
   network client entitlement starts but its web content process cannot fetch anything;
   a build without the bookmark entitlement cannot reopen a folder without asking.
7. Notarize and staple:

   ```sh
   xcrun notarytool submit build/XYZ-notarize.zip --apple-id <id> --team-id <team> \
     --password <app-specific password> --wait
   xcrun stapler staple build/export/XYZ.app
   xcrun stapler validate build/export/XYZ.app
   ```
8. Open the stapled app and run the manual check that CI cannot: open a folder through
   the panel, quit with unsaved edits, reopen the app and look for the restored tabs,
   open a note with a relative picture, install the `xyz` command, switch the app
   language to 简体中文, and type Chinese through a real input method.
9. Tag the commit that was archived: `git tag -a v<version> -m "XYZ <version>"` and push
   the tag with the release notes. The `CHANGELOG.md` entry for that version is the
   release note.
10. iOS goes through TestFlight with the same signing team; the document browser needs
    the iCloud container entitlement, which a `CODE_SIGNING_ALLOWED=NO` build does not
    carry.

## What still blocks a release

- `ENABLE_HARDENED_RUNTIME = NO` in `XYZ.xcodeproj/project.pbxproj`.
- No release workflow: the cloud job builds, but nothing archives or notarizes.
- The acceptance gate has not passed, so the window checks are evidence, not a pass.
- The installed 0.5.27 build is signed with an Apple Development certificate, not a
  Developer ID, so it cannot be notarized or distributed.
