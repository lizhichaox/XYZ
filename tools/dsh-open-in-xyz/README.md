# dsh-open-in-xyz

> A local DSH plugin inside the XYZ repository (`tools/dsh-open-in-xyz/`). **Not
> published**: the npm package is marked `private`, it is not in the plugin market, and
> it is installed only from this checkout; licensed MIT, the same as the XYZ repository root.

A local plugin for DeepSeek Harness (DSH): it adds an "Open in XYZ" split button to the
**session header** and opens the current Session's working directory in the XYZ app
installed on this machine. Its look, size, and hover behavior match the official Open In
button; the menu also offers "Open in VS Code" (hidden when VS Code is not detected) and
"Reveal in Finder".

- Zero setup: no settings page, no user preferences written; the Host half detects where
  XYZ is installed by itself.
- Keeps the official `@deepseek-ai/dsh-host-open-in-app` / `@deepseek-ai/dsh-client-ui-open-in-app`:
  the file-level "Open With", document preview controls, and context menu all stay as
  they were; only the one button in the session header is replaced.
- Localization: `en` + `zh` (other languages fall back to English).

## Installation (keeping the official Open In plugin)

1. **Install the dependency** (in the profile directory): `~/.dsh/profiles/desktop/package.json`

   ```json
   {
     "dsh": { "profile": { "bundles": [ "...", "dsh-open-in-xyz" ] } },
     "dependencies": {
       "dsh-open-in-xyz": "link:/Users/lizhichao/Developer/XYZ/tools/dsh-open-in-xyz"
     }
   }
   ```

   Then run `pnpm install` in `~/.dsh/profiles/desktop` (using the pnpm that ships with
   DSH), so that `node_modules/dsh-open-in-xyz` points at `tools/dsh-open-in-xyz/` in the
   XYZ repository.

2. This package's `cordis.patch.yml` inserts the Host half into the plugin tree
   automatically through `dsh.bundle.patch`:

   ```yaml
   - insert:
       - id: open-in-xyz
         name: 'dsh-open-in-xyz'
   ```

3. **Restart DSH** (Host plugins load only at startup).

> Alternatively you can insert it directly: still point `dependencies` at this checkout
> and run `pnpm install` as in step 1, but do not add `dsh-open-in-xyz` to
> `dsh.profile.bundles`; instead add the same `- insert:` line to
> `~/.dsh/profiles/desktop/cordis.patch.yml`. Both ways produce the same plugin tree.

## How the official button steps aside

Two mechanisms work at the same time and back each other up (both affect only the official
`open-in-app` entry in the single list slot `conversation.session.header.utilities`):

1. **Lower-priority shadow at the same slot id (primary)**: for the same id in a list slot,
   `SlotCore` renders only one winner, picking the lowest priority in ascending order. This
   plugin registers an entry that renders `null` with `id: 'open-in-app', priority: -1`, so
   the official header component no longer renders. This is replacement semantics
   documented by the slot registration API itself (the registration-conflict error text
   verbatim: *"register at a different priority to shadow it (lowest renders)"*), not a DOM
   hack, and the official plugin's other registrations (file-level Open In) are unaffected.
2. **Very narrow CSS fallback**: should DSH ever reject same-id registration, the stylesheet
   still has two complementary `display:none` rules: one matches the split container inside
   that slot carrying the official `data-open-target="directory"` marker, the other matches
   the slot cell whose direct child `span` wraps that marker
   (`[data-slot="conversation.session.header.utilities"] [data-open-target="directory"]`
   and the same-prefixed `>span:has(>[data-open-target="directory"])`). Both match only the
   official entry; neither matches this plugin's own button, other slots, or other header
   utility buttons.

## Security boundary

The Host half mounts only 3 routes on `webServer`, and all of them first pass composition's
`connection.requestRejection()` trust fence (Host/Origin protection against DNS rebinding
plus browser login state):

| Route | Description |
|---|---|
| `GET /open-in-xyz/state` | `{ ok, available, platform, appPath, cliPath }` availability probe |
| `POST /open-in-xyz/open` | open the working directory: JSON body `{ "path": "<absolute path>" }` |
| `POST /open-in-xyz/reveal` | reveal that directory in Finder: same body as above |

Beyond the fence, the POST routes also perform wire-level validation: `application/json`,
a 64 KiB cap, exactly one `path` field (extra fields are rejected outright), an absolute
path (≤4096 characters, no NUL), and a `stat` confirmation that it is an existing
directory; the program is fixed to the XYZ that the Host half detected
(`/Applications/XYZ.app`, `~/Applications/XYZ.app`, or the `/opt/homebrew/bin/xyz`,
`/usr/local/bin/xyz` CLI fallback), so **the browser cannot specify which executable to
open or any extra arguments**. Processes are always started through `execFile`'s argv
array, never through a shell: the app bundle goes via `/usr/bin/open -a <app> <dir>`, when
only the `xyz` CLI is available it goes directly via `xyz <dir>`, and `reveal` goes via
`/usr/bin/open -R <dir>`.

## Behavior details

- Button: `<mark 9px ink height> + <chevron 10px>`, 24px tall, `.5px` hairline border,
  `--dsw-radius-sm` radius, 11px font size; hover/focus match the official button.
- Both the header mark and the menu mark are the **inline vector `_xyz` wordmark** (no
  longer a scaled-down square app icon): its glyphs come from the "small style" variant
  that the XYZ icon uses at small sizes (Finder list / Open With menu) — Inter ExtraBold
  with heavier, wider letters and wider tracking — and stay vector-sharp at any DPR; the
  letters use `currentColor` to follow the theme (dark letters on light / light letters on
  dark), while the underline keeps the brand blue `#0078D4`.
  - Header: 9px ink height (about 28px wide, matching the visual mass of the original
    version); the viewBox reserves extra `y` descender height above, so that the **x-height
    band lands exactly at the center of the box** and reads as centered once flex-centered
    (without this the letters would sit about 1.7px too high).
  - Menu row: the same SVG is drawn at **6.3px ink height (about 20px wide)**. The menu's
    native 14px icon slot cannot fit a legible "xyz" (with a square icon scaled to 14px the
    text is only about 2–3px high), so the mark overrides the primitive's
    `svg{width:14px;height:14px}` rule with an inline style, overflowing about 3px on each
    side and exactly using up the gap between icon and text; row height and text position
    stay unchanged.
  Rationale: scaled down to 13px, the full app icon leaves the "xyz" inside the tile only
  ~3px high, so it unavoidably becomes a blur; the official button's "app icon" approach
  cannot produce legible text at this miniature size — only the wordmark stays readable. The
  `./icon` export used by the plugin manifest is a separate 256px app icon image, used only
  for display in the Plugins list.
- Primary button = open the current working directory in XYZ (`useSessions` reads the
  current Session's `cwd`).
- Dropdown = "Open in XYZ" / "Open in VS Code" / "Reveal in Finder".
- The VS Code item reuses the official host's installed-app catalog: it probes
  `/open-in-app/apps`, gets the icon from `/open-in-app/icon/vscode`, and launches via POST
  `/open-in-app/open` (body `{ "app": "vscode", "path": "<absolute path>" }`). There is
  therefore no need to reimplement app probing/launch mapping; when VS Code is not
  installed or the official catalog probe fails, the item hides itself (zero setup, no
  configuration needed). The cost: the VS Code item depends on the official
  `@deepseek-ai/dsh-host-open-in-app` staying enabled (as it is in the default
  installation; the XYZ / Finder items do not depend on it).
- When probing finds that XYZ is not present: **the entire button is hidden** (consistent
  with the official "no resolvable app, no button rendered" behavior), and `console.warn`
  fires once. Before the probe returns, the button first renders optimistically once — the
  local probe is fast, so with XYZ installed the header neither flickers nor shifts; only
  when it is not installed does it briefly hide. Rationale: a disabled button receives no
  hover events under Chromium, so its tooltip is unreliable; a button that can never be
  clicked is just noise.
- Request failures (including concurrent clicks) are reported in the current language via
  `contextMenus.notify()`; repeated clicks during the same gesture are ignored.
- Language: full `zh` / `en`; other languages fall back to English.
- Activation: changing only `client.js` does not require a DSH restart — `client-hmr` in
  the web composition stat-polls each client bundle every 500ms and, on detecting a change,
  pushes a rebuilt frame so the page's module is hot-replaced; if hot replacement does not
  take effect, refresh the page (Cmd+R). Changing the Host half (`index.js` etc.) does
  require a DSH restart.

## Rollback

1. Remove `dsh-open-in-xyz` from `dsh.profile.bundles` and `dependencies` in
   `~/.dsh/profiles/desktop/package.json`;
2. run `pnpm install` in the profile directory;
3. restart DSH and the official Open In button returns (this plugin no longer loads, and the
   shadow entry disappears with the plugin unload).

You can also just disable the plugin temporarily: add `- id: open-in-xyz` /
`disabled: true` to the profile's `cordis.patch.yml` (keeping the dependency, effective
after restart).

## Local self-check

Run inside `tools/dsh-open-in-xyz/`:

```sh
npm test          # node --check + headless smoke
```

`test/smoke.mjs` uses no network and launches no application: it first validates the
manifest contract and the 256px plugin icon, then exercises the Host routes with a fake
Cordis ctx (trust fence, method, body validation, launch argv), and finally exercises the
Client half with minimal React/module-loader stubs (slot registration parameters, shadow
priority, CSS selectors, component rendering, plus paths such as the busy state, error
notification, stylesheet reuse, and probe failure).

## Icon legibility (2026-11-09 improvement)

User feedback: "The XYZ logo is unreadable, too blurry." Root cause and handling:

| Approach | Actual result | Verdict |
|---|---|---|
| 256px full-size app icon scaled to 13px (original approach) | text inside the tile only ~3px high, a blurry color blob | dropped |
| the app's own 32/64px small-style icon | larger and heavier letters, but still hard to make out at 13px | dropped |
| app icon enlarged to 16px | still cannot make out "xyz" | not adopted |
| vector wordmark (final approach) | `_xyz` is clearly readable at both 6.3px (menu) and 9px (header) ink heights, and adapts to light and dark | used for both header and menu |

The wordmark is generated from the "small style" font parameters in `tools/make_icons.py`
in this repository and then inlined into `client.js` (it does not read the XYZ repository or
font files at runtime).

## Known limitations

- The official button stepping aside relies on DSH's slot semantics; if a major DSH redesign
  breaks both mechanisms at the same time, two Open In buttons may appear (official + this
  plugin). In that case follow "Rollback" above, or switch to the approach that does not
  keep the official plugin: disable `@deepseek-ai/dsh-client-ui-open-in-app` (at the cost of
  losing file-level Open In as well).
- Verified on macOS only; `reveal` goes through `/usr/bin/open -R`, and non-macOS returns
  501.
- Not published: `private: true`, maintained together with the XYZ repository, installed
  only from this checkout; no plugin-market index.

## License

MIT, the same as the XYZ repository (see `LICENSE` at the repository root).
