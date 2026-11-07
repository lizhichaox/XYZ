# AGENTS.md

Instructions for agents working in this repository. The owner has stated the machine
rules below more than once; follow them without being asked.

## One XYZ.app on this Mac (standing rule)

- Exactly one copy of `XYZ.app` may exist on this computer: `/Applications/XYZ.app`,
  and it must be the newest build. Do not keep a rollback copy of an older version.
- After every build, test install, or release:
  1. quit the running app (`osascript -e 'tell application "XYZ" to quit'`, or kill the
     process if it will not quit),
  2. replace the installed app: `rm -rf /Applications/XYZ.app` then
     `ditto <built path>/XYZ.app /Applications/XYZ.app`,
  3. delete every other `XYZ.app` bundle: `build/**` products (DerivedData, `export`,
     `*.xcarchive`), any mounted DMG, `/tmp`, Desktop, Downloads, Trash,
  4. verify with `mdfind "kMDItemCFBundleIdentifier == 'com.lizhichao.XYZ'"`; only
     `/Applications/XYZ.app` may be listed.
- Release artifacts (DMG/ZIP) live under `build/` for the current version only. Delete
  older versions, and unmount a DMG after inspecting it (a mounted DMG shows a second
  `XYZ.app` in Finder).
- When the build under test is signed with Apple Development instead of Developer ID,
  say so; replace it with a signed, notarized build before calling the install final.

## Project facts

- Version lives only in `Config/Base.xcconfig` (`MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`). The cloud check reads it back out of `Info.plist`.
- Tests: `swift test --package-path XYZCore` and `sh Scripts/xyz-test.sh`.
- Unsigned builds (what CI does):
  `xcodebuild -project XYZ.xcodeproj -scheme XYZ -configuration Debug -destination 'platform=macOS' -derivedDataPath build/dev-macos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- build`,
  and the same with `-destination 'generic/platform=iOS Simulator'`.
- Signing and notarization: `docs/release.md`, `tools/ExportOptions.plist`. Team
  `Z4FMG2KTPM`, Developer ID Application certificate in the login keychain, notary
  profile `xyz-notary` (`xcrun notarytool ... --keychain-profile xyz-notary`).
- Do not launch the GUI app unless the owner asks; a hidden launch
  (`open -j -a /Applications/XYZ.app`, then `pgrep -x XYZ`, then quit) is the quick
  check. Toggling sidebars and other interaction still needs the owner.
- The app is sandboxed with iCloud and security-scoped bookmarks; the unsigned CI build
  has no entitlements, so a green cloud run does not prove the sandboxed app works.
