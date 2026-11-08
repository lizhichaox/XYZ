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

There are no font choices. Legacy Latin/CJK/monospaced preferences are ignored.
Text size and line spacing are settings (spacing 1.0–2.0, default 1.7); code renders
0.15 tighter than prose. Reading uses the full pane width with its original insets and
0.3em list-item spacing.
