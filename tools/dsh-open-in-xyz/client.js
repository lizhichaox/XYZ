/**
 * Client half — "Open in XYZ" split button in the conversation Session header.
 *
 * The button replaces the shipped `open-in-app` header entry (id
 * `open-in-app`, list slot `conversation.session.header.utilities`) while the
 * rest of that plugin keeps running: document-preview and file-level "Open
 * In…" controls are untouched.
 *
 * Replacement uses two independent mechanisms so a DSH update cannot silently
 * leave two buttons on screen:
 *
 *  1. Slot shadowing (primary): `SlotCore` keeps one winner per cell, ordered
 *     by ascending priority. `ctx.slots.register` with the shipped entry's id
 *     at priority -1 therefore puts this plugin in that very cell; the
 *     official header component never renders. The shipped register error
 *     itself documents this contract: "register at a different priority to
 *     shadow it (lowest renders)". This is not a DOM hack.
 *  2. Stylesheet fallback (defence in depth): if a future DSH rejects the
 *     same-id registration, a deliberately narrow rule hides only the
 *     official header element — a direct child of this one slot anchor that
 *     carries the official `data-open-target="directory"` marker. It cannot
 *     match this plugin's own markup, other slots, or other header utilities.
 *
 * Everything is zero-config: the Host half auto-detects the local XYZ install
 * and the button hides itself when XYZ is absent. No settings page, no user
 * configuration, no host route that accepts an arbitrary path or program.
 */
window.__ModuleLoader__.load({
  id: 'dsh-open-in-xyz',
  factory(require) {
    var module = { exports: {} };
    var exports = module.exports;

    const React = require('react');
    const primitives = require('@deepseek-ai/dsh-client-ui-primitives');
    const Menu = primitives.Menu;
    const Tooltip = primitives.Tooltip;
    const IconChevronDownOutlineRegular = primitives.IconChevronDownOutlineRegular;
    const IconCodeOutlineRegular = primitives.IconCodeOutlineRegular;
    const IconFolderOpenOutlineRegular = primitives.IconFolderOpenOutlineRegular;
    const h = React.createElement;

    /** This plugin's locale namespace. */
    const NS = 'openInXyz';
    /** The list slot rendered at the right edge of the conversation Session header. */
    const SLOT = 'conversation.session.header.utilities';
    /** Shipped cell key of the official "Open In…" header entry. */
    const OFFICIAL_ENTRY_ID = 'open-in-app';
    /** Lower than the shipped entry's default priority (0), so this plugin wins the cell. */
    const SHADOW_PRIORITY = -1;
    /** Routes owned by this plugin's Host half. */
    const ROUTES = Object.freeze({
      state: '/open-in-xyz/state',
      open: '/open-in-xyz/open',
      reveal: '/open-in-xyz/reveal'
    });
    /**
     * Routes owned by the shipped `open-in-app` Host half. That plugin stays
     * enabled (this plugin only replaces its header entry), so its resolved
     * application catalog and launch route are reused for VS Code instead of
     * duplicating detection, argv mapping, and icon extraction here.
     */
    const OFFICIAL_ROUTES = Object.freeze({
      apps: '/open-in-app/apps',
      open: '/open-in-app/open',
      vscodeIcon: '/open-in-app/icon/vscode'
    });
    /** The one extra application this menu offers besides XYZ. */
    const VSCODE_APP_ID = 'vscode';
    /** Availability answers older than this are re-read on the next mount. */
    const STATUS_TTL_MS = 30_000;
    /** Unique stylesheet key, mirroring the shipped plugins' data-plugin-css convention. */
    const CSS_KEY = 'dsh-open-in-xyz';

    /**
     * Split-button, icon, and the narrow official-button fallback. The metric
     * rules are copied from the shipped OpenTargetButton stylesheet so the
     * replacement is visually interchangeable: 24px tall, hairline border,
     * theme radius, 13px application icon, 10px chevron, identical hover.
     */
    const CSS = [
      '.doix-menuAnchor{flex:none;align-self:center;display:inline-flex}',
      '.doix-split{box-sizing:border-box;border:.5px solid var(--dsw-alias-border-l4);border-radius:var(--dsw-radius-sm);height:24px;font-family:var(--dsw-font-family);align-items:stretch;display:inline-flex;overflow:hidden}',
      '.doix-main,.doix-chevron{color:var(--dsw-alias-label-primary);white-space:nowrap;cursor:pointer;background:0 0;border:0;justify-content:center;align-items:center;font-size:11px;line-height:16px;display:inline-flex}',
      '.doix-main{gap:4px;padding:3px 5px}',
      '.doix-chevron{border-left:.5px solid var(--dsw-alias-border-l4);color:var(--dsw-alias-label-secondary);padding:3px 4px 3px 3px}',
      '.doix-main:focus-visible,.doix-chevron:focus-visible{background:var(--dsw-alias-interactive-bg-hover)}',
      '@media (hover:hover){.doix-main:hover:not(:disabled),.doix-chevron:hover:not(:disabled){background:var(--dsw-alias-interactive-bg-hover)}}',
      '.doix-main:disabled,.doix-chevron:disabled{cursor:default}',
      '.doix-wordmark{flex:none;display:block}',
      '.doix-icon{object-fit:contain;flex:none;display:block}',
      /* Fallback only: the shipped header entry normally never renders (shadowed above). */
      '[data-slot="conversation.session.header.utilities"] [data-open-target="directory"]{display:none!important}',
      '[data-slot="conversation.session.header.utilities"]>span:has(>[data-open-target="directory"]){display:none!important}'
    ].join('');

    /** Simplified Chinese dictionary (the key-set source of truth). */
    const zh = {
      'tooltip.open': '在 XYZ 中打开',
      'tooltip.more': '更多打开方式',
      'menu.openInXyz': '在 XYZ 中打开',
      'menu.openInVscode': '在 VS Code 中打开',
      'menu.revealInFinder': '在 Finder 中显示',
      'error.openFailed': '打不开该工作目录，请重试',
      'error.vscodeFailed': '无法在 VS Code 中打开该工作目录，请重试',
      'error.revealFailed': '无法在 Finder 中显示该目录，请重试',
      'error.appMissing': '未检测到已安装的 XYZ.app',
      'error.noDirectory': '工作目录不存在或已被移动'
    };

    /** English dictionary, key-identical to the Chinese source of truth. */
    const en = {
      'tooltip.open': 'Open in XYZ',
      'tooltip.more': 'More ways to open',
      'menu.openInXyz': 'Open in XYZ',
      'menu.openInVscode': 'Open in VS Code',
      'menu.revealInFinder': 'Show in Finder',
      'error.openFailed': 'Could not open this workspace. Try again.',
      'error.vscodeFailed': 'Could not open this workspace in VS Code. Try again.',
      'error.revealFailed': 'Could not show this folder in Finder. Try again.',
      'error.appMissing': 'XYZ.app is not installed',
      'error.noDirectory': 'The workspace folder no longer exists'
    };

    /** Page-lifetime environment probe; a failed read fails open for XYZ and is retried on the next mount. */
    let environmentRead;
    let environmentReadAt = 0;

    /** GET one JSON route, rejecting on transport or status failure. */
    function readJson(route) {
      return fetch(route, { credentials: 'same-origin', headers: { accept: 'application/json' } }).then((response) =>
        response.ok ? response.json() : Promise.reject(new Error(`HTTP ${response.status}`))
      );
    }

    /**
     * Read the local environment, at most once per {@link STATUS_TTL_MS}:
     * whether XYZ is installed (this plugin's own Host) and whether VS Code is
     * installed (the shipped Host's resolved application catalog).
     * @returns {Promise<{ xyz: boolean, vscode: boolean }>} the detected
     *   applications. A failed XYZ probe fails open so a launch attempt (and its
     *   localized error) still happens instead of silently disabling the button;
     *   an unavailable catalog probe simply leaves VS Code out of the menu.
     */
    function readEnvironment() {
      const now = Date.now();
      if (environmentRead === undefined || now - environmentReadAt > STATUS_TTL_MS) {
        environmentReadAt = now;
        const xyz = readJson(ROUTES.state)
          .then((data) => (data !== null && typeof data === 'object' && data.available === true ? true : false))
          .catch((error) => {
            console.warn('[open-in-xyz] availability probe failed; assuming XYZ is installed:', error);
            return true;
          });
        const vscode = readJson(OFFICIAL_ROUTES.apps)
          .then((data) => (data !== null && typeof data === 'object' && Array.isArray(data.apps) ? data.apps.includes(VSCODE_APP_ID) : false))
          .catch(() => false);
        environmentRead = Promise.all([xyz, vscode]).then(([xyzAvailable, vscodeAvailable]) => ({
          xyz: xyzAvailable,
          vscode: vscodeAvailable
        }));
      }
      return environmentRead;
    }

    /**
     * `_xyz` wordmark geometry, extracted from the XYZ app icon's small-size
     * style (Inter ExtraBold, word width 800/1024, extra tracking): the same
     * artwork the app itself draws for Finder lists and Open With menus, so the
     * mark stays legible when the button renders it tiny.
     *
     * The viewBox extends upward by the y-descender so that the x-height band
     * (the part the eye reads) is the box centre: flex centring then looks
     * optically centred instead of pushing the letters high.
     */
    const WORDMARK = Object.freeze({
      viewBox: '109.0 330.07 806 331.85',
      aspect: 2.4288,
      inkRatio: 0.7696,
      bar: { x: 112.0, y: 530.78, width: 190.32, height: 57.68 },
      path:
        'M321.40497628663104 588.462386843781 392.33799154036825 471.0432837444484 392.29829552983244 515.9945130260106 324.8321998045991 403.537613156219H386.0925935694381L400.2843817348883 430.0025758995647Q407.8335291464575 444.3995879974085 414.1785305863465 459.2399193258342Q420.5235320262355 474.0802506542598 426.84206272868175 487.9678373473131H406.6425276828438Q413.3778866871726 474.2059614180421 419.8155256124828 459.3027747077253Q426.2531645377931 444.3995879974085 434.2191402512449 430.0025758995647L449.15857026721363 403.537613156219H509.25449387965153L440.20047696795973 516.1863703465148V471.55933188141375L511.72897276224717 588.462386843781H450.8854072992907L433.0612928310186 556.3735937736222Q425.1747091386385 541.9302629330678 418.55512679982974 526.9377501034171Q411.9355444610209 511.94523727376645 405.2795774777637 498.17673861232055H425.5188085341375Q419.2399738422271 511.94523727376645 412.94789368596696 526.9377501034171Q406.6558135297068 541.9302629330678 398.9809553543553 556.3735937736222L381.45458115635836 588.462386843781ZM539.7088451080749 653.3150474582868 552.5974088055584 611.1691913729827 559.8885927224148 613.1276221186131Q570.3687837115114 615.8204492504123 578.1892208471695 614.6195944535627Q586.0096579828278 613.4187396567133 590.2043511653258 608.7675221617972Q594.3990443478236 604.1163046668809 593.9623074669033 596.5407470916388L593.8497614024443 588.826273670778L524.8553086978128 403.537613156219H585.7253650894687L613.4010763454128 493.9685576703934Q618.9322691868047 512.5536806010736 622.1643038269245 531.2479776563555Q625.3963384670444 549.9422747116373 629.8160026309207 571.352598652587H618.0191801794548Q622.4388443433311 549.9422747116373 626.8849792446501 531.1024188873052Q631.3311141459692 512.2625630629733 637.1997432681719 493.9685576703934L666.8405080019212 403.537613156219H726.9166038003478L649.4732005236602 607.9141185090473Q643.8493701968471 622.8867429509169 634.672585397027 634.4090046947197Q625.4958005972069 645.9312664385224 611.3667062835948 652.428469570893Q597.2376119699827 658.9256727032634 576.3764094443593 658.9256727032634Q565.7969582376667 658.9256727032634 555.984976695504 657.3906929916905Q546.1729951533413 655.8557132801176 539.7088451080749 653.3150474582868ZM753.9106582324422 588.462386843781V555.2353318723277L840.1469095641187 449.82526133164873V448.6343406330615H756.715950663674V403.537613156219H908.9432860412038V440.1389905532682L828.9528365055901 542.1747386683513V543.3656593669385H912.0V588.462386843781Z'
    });
    /** Header mark: 9px of ink (about 28px wide), the compact width the header first shipped with. */
    const WORDMARK_HEADER_INK = 9;
    /**
     * Dropdown-row mark: 6.3px of ink, about 20px wide. The menu icon cell is
     * 14px wide, so the mark overflows it by ~3px on each side and uses the
     * natural icon-to-label gap; that is the widest size that still leaves a
     * readable gap before the label.
     */
    const WORDMARK_MENU_INK = 6.3;
    /** Brand blue of the app icon's underscore (sampled from the shipped icon). */
    const WORDMARK_ACCENT = '#0078D4';

    /**
     * Vector `_xyz` wordmark. Inline SVG (not an image) so the strokes stay
     * sharp at any device pixel ratio and `currentColor` follows the theme:
     * dark ink on light, light ink on dark. The underscore keeps the app icon's
     * brand blue in both themes.
     * @param props - `ink` height in px of the visible lettering; the SVG box is
     *   taller than the ink so the x-height band lands on the box centre.
     * @returns the wordmark.
     */
    function Wordmark({ ink }) {
      const height = Math.round((ink / WORDMARK.inkRatio) * 100) / 100;
      const width = Math.round(height * WORDMARK.aspect * 100) / 100;
      return h(
        'svg',
        {
          className: 'doix-wordmark',
          viewBox: WORDMARK.viewBox,
          width,
          height,
          // Inline styles beat the shipped menu primitive's `.itemIcon svg`
          // width/height rule, so the menu-row mark can be wider than its cell.
          style: { width: `${width}px`, height: `${height}px`, flex: 'none', display: 'block' },
          'aria-hidden': 'true',
          focusable: 'false'
        },
        h('rect', {
          x: WORDMARK.bar.x,
          y: WORDMARK.bar.y,
          width: WORDMARK.bar.width,
          height: WORDMARK.bar.height,
          fill: WORDMARK_ACCENT
        }),
        h('path', { d: WORDMARK.path, fill: 'currentColor' })
      );
    }

    /**
     * VS Code application icon, served by the shipped `open-in-app` Host route,
     * with the generic code glyph as a per-image fallback.
     * @param props - `size` in px.
     * @returns the application image, or the code glyph on error.
     */
    function VscodeIcon({ size }) {
      const [failed, setFailed] = React.useState(false);
      if (failed) return h(IconCodeOutlineRegular, { size });
      return h('img', {
        className: 'doix-icon',
        src: OFFICIAL_ROUTES.vscodeIcon,
        width: size,
        height: size,
        alt: '',
        draggable: false,
        onError: () => setFailed(true)
      });
    }

    /**
     * Build the header entry component. It is created inside `apply` so the
     * failure announcer can reach the app-wide context-menu notice seat.
     * @param ctx - Client plugin context.
     * @returns the split-button component.
     */
    function createHeaderButton(ctx) {
      /** @param props - standard Session-slot kit (`sessionId`, `useSessions`) plus the locale seat `t`. */
      function HeaderButton(props) {
        const { sessionId, useSessions, t } = props;
        const cwd = useSessions((state) => (sessionId === undefined ? undefined : state.byId[sessionId]?.cwd));
        const [environment, setEnvironment] = React.useState({ xyz: true, vscode: false });
        const [menuOpen, setMenuOpen] = React.useState(false);
        const [pending, setPending] = React.useState(false);
        const inFlight = React.useRef(false);

        React.useEffect(() => {
          let cancelled = false;
          readEnvironment().then((detected) => {
            if (cancelled) return;
            if (detected.xyz !== true) console.warn('[open-in-xyz] XYZ is not installed; hiding the header button');
            setEnvironment(detected);
          });
          return () => {
            cancelled = true;
          };
        }, []);

        /** Announce one localized failure through the shared notice seat. */
        const notifyFailure = (key) => {
          let message = key;
          try {
            message = t(key);
          } catch (error) {
            console.error('[open-in-xyz] could not localize a failure message:', error);
          }
          try {
            ctx.contextMenus.notify(message, false);
          } catch (error) {
            console.error('[open-in-xyz] could not announce the failure:', error);
          }
        };

        /** @param kind - gesture kind. @returns the localized failure key it reports. */
        const failureKey = (kind) => (kind === 'reveal' ? 'error.revealFailed' : kind === 'vscode' ? 'error.vscodeFailed' : 'error.openFailed');

        /**
         * POST one gesture to the Host half: this plugin's XYZ/reveal routes,
         * or the shipped Host's launch route for VS Code.
         * @param kind - `open` (XYZ), `vscode` (VS Code), or `reveal` (Finder).
         */
        const run = (kind) => {
          if (inFlight.current) return;
          if (typeof cwd !== 'string' || cwd === '') return;
          inFlight.current = true;
          setPending(true);
          const route = kind === 'reveal' ? ROUTES.reveal : kind === 'vscode' ? OFFICIAL_ROUTES.open : ROUTES.open;
          const payload = kind === 'vscode' ? { app: VSCODE_APP_ID, path: cwd } : { path: cwd };
          fetch(route, {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(payload)
          })
            .then(async (response) => {
              let data;
              try {
                data = await response.json();
              } catch {
                data = undefined;
              }
              if (response.ok && data !== null && typeof data === 'object' && data.ok === true) return;
              const code = data !== null && typeof data === 'object' ? data.code : undefined;
              if (code === 'app_missing') notifyFailure('error.appMissing');
              else if (code === 'no_directory') notifyFailure('error.noDirectory');
              else notifyFailure(failureKey(kind));
            })
            .catch((error) => {
              console.error('[open-in-xyz] request failed:', error);
              notifyFailure(failureKey(kind));
            })
            .finally(() => {
              inFlight.current = false;
              setPending(false);
            });
        };

        if (typeof cwd !== 'string' || cwd === '') return null;
        if (!environment.xyz) return null;

        const disabled = pending;
        const primaryLabel = t('tooltip.open');
        const anchor = h(
          'div',
          {
            className: 'doix-split',
            'data-open-in-xyz': 'directory',
            'data-size': 'compact',
            'data-state': disabled ? 'busy' : 'idle'
          },
          h(
            Tooltip,
            { portal: true, label: primaryLabel, side: 'bottom', delayMs: 500 },
            h(
              'button',
              {
                type: 'button',
                className: 'doix-main',
                disabled,
                'aria-label': primaryLabel,
                onClick: () => {
                  setMenuOpen(false);
                  run('open');
                }
              },
              h(Wordmark, { ink: WORDMARK_HEADER_INK })
            )
          ),
          h(
            'button',
            {
              type: 'button',
              className: 'doix-chevron',
              disabled,
              'aria-haspopup': 'menu',
              'aria-expanded': menuOpen && !disabled,
              'aria-label': t('tooltip.more'),
              onClick: () => setMenuOpen((value) => !value)
            },
            h(IconChevronDownOutlineRegular, { size: 10 })
          )
        );

        return h(Menu, {
          className: 'doix-menuAnchor',
          open: menuOpen && !disabled,
          autoFocus: true,
          portal: true,
          dense: true,
          align: 'end',
          onClose: () => setMenuOpen(false),
          items: [
            { id: 'open', icon: h(Wordmark, { ink: WORDMARK_MENU_INK }), label: t('menu.openInXyz') },
            ...(environment.vscode
              ? [{ id: 'vscode', icon: h(VscodeIcon, { size: 14 }), label: t('menu.openInVscode') }]
              : []),
            { id: 'reveal', icon: h(IconFolderOpenOutlineRegular, {}), label: t('menu.revealInFinder') }
          ],
          onSelect: (id) => {
            setMenuOpen(false);
            run(id === 'reveal' ? 'reveal' : id === 'vscode' ? 'vscode' : 'open');
          },
          anchor
        });
      }
      return HeaderButton;
    }

    /** One shadowing cell winner that renders nothing; the shipped header entry is skipped. */
    function OfficialHeaderSlotShadow() {
      return null;
    }

    /** Client plugin body. */
    function apply(ctx) {
      const dictionaries = { zh, en, ja: en, es: en, fr: en, de: en, ru: en, pt: en };
      ctx.effect(() => ctx.locale.register(NS, dictionaries), 'open-in-xyz: dictionaries');

      ctx.effect(() => {
        if (typeof document === 'undefined' || typeof document.createElement !== 'function' || document.head === undefined) {
          return undefined;
        }
        let tag = document.querySelector(`style[data-plugin-css="${CSS_KEY}"]`);
        if (tag === null || tag === undefined) {
          tag = document.createElement('style');
          tag.dataset.plugin = CSS_KEY;
          tag.dataset.pluginCss = CSS_KEY;
          document.head.appendChild(tag);
        }
        if (tag.textContent !== CSS) tag.textContent = CSS;
        return () => {
          if (tag.parentElement !== null) tag.parentElement.removeChild(tag);
        };
      }, 'open-in-xyz: stylesheet');

      ctx.slots.inject(SLOT, () =>
        ctx.slots.register({ name: SLOT, id: 'open-in-xyz', order: -10, locale: NS }, createHeaderButton(ctx))
      );

      try {
        ctx.slots.inject(SLOT, () => {
          try {
            return ctx.slots.register(
              { name: SLOT, id: OFFICIAL_ENTRY_ID, priority: SHADOW_PRIORITY },
              OfficialHeaderSlotShadow
            );
          } catch (error) {
            console.error(
              '[open-in-xyz] the official header entry could not be shadowed; the stylesheet fallback hides it instead:',
              error
            );
            return () => {};
          }
        });
      } catch (error) {
        console.error('[open-in-xyz] could not install the official-entry shadow:', error);
      }
    }

    return { inject: ['slots', 'locale', 'contextMenus'], apply };
  }
});
