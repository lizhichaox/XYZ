# Bundled fonts

XYZ includes unmodified JetBrains Mono 2.304 from
https://github.com/JetBrains/JetBrainsMono/tree/v2.304 .

Copyright 2020 The JetBrains Mono Project Authors.
The fonts are distributed under the SIL Open Font License 1.1; see OFL.txt.
Exact download URLs and SHA-256 hashes are recorded in sources.json.

Included styles: Regular, Medium, SemiBold, Bold, Italic, BoldItalic.
TTF files serve the native editor. WOFF2 files serve Reading through embedded
CSS data URLs, without network requests or access to the note's folder.

Fonts are registered only within the XYZ process, not installed system-wide.
Automatic typography uses JetBrains Mono for code and the system font for prose.
Chinese uses the selected CJK fallback (PingFang SC by default); Apple fonts are
provided by macOS and are not redistributed in this bundle.

Explicit font, size, spacing and CJK preferences are not migrated or overwritten.
To use the recommended combination, choose Automatic + PingFang SC in Settings.
Choosing JetBrains Mono explicitly also applies it to prose.
