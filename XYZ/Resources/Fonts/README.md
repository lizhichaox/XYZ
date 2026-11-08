# Fixed bilingual typography

XYZ bundles unmodified Sarasa Gothic SC and Sarasa Mono SC 1.0.43 (unhinted TTF)
from https://github.com/be5invis/Sarasa-Gothic/releases/tag/v1.0.43 .
The full SIL Open Font License 1.1 and copyright notices are in OFL.txt.
Archive SHA-256 digests were checked against the upstream release metadata;
sources.json records those digests, archive members, and extracted-file hashes.

Prose: Gothic SC Regular, SemiBold, Italic, SemiBoldItalic.
Code: Mono SC Regular, SemiBold.
Both Latin and Chinese come from the same face. System UI stays native.
Fonts are registered per process, not installed into Font Book.

Reading loads the same TTFs through an exact-name xyz-font://bundled allowlist.
No network, no note-folder access, and no megabytes of base64 injected into HTML.

There are no font or line-spacing choices. Legacy Latin/CJK/monospaced/spacing
preferences are ignored; saved text size is retained. Reading uses 1.75 line height,
the full pane width with original insets and 0.3em list-item spacing. Source uses 1.7 for prose and
1.55 for code, subject to natural glyph height (never a clipping maximum).
