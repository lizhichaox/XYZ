/**
 * Dependency-free smoke test for the open-in-xyz bundle.
 *
 *   node test/smoke.mjs
 *
 * It never touches the network, never launches an application, and needs no
 * build step. The Host half is loaded for real against a fake Cordis context
 * and driven through its HTTP handlers (trust fence, methods, media types,
 * body ceiling, path validation). The Client half is loaded for
 * real through a stubbed `window.__ModuleLoader__` and driven through a minimal
 * React hook runtime, so the slot registrations, the official-entry shadow, the
 * fallback selector, and the button's click paths are all exercised headlessly.
 */
import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

import { ROUTES, apply as applyHost, inject as hostInject, internals } from '../index.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const readText = (relative) => readFileSync(path.join(root, relative), 'utf8');

const SLOT = 'conversation.session.header.utilities';
const SHIPPED_ENTRY_ID = 'open-in-app';
const PLUGIN_ID = 'dsh-open-in-xyz';

// ---------------------------------------------------------------- manifest --
{
  const manifest = JSON.parse(readText('package.json'));
  assert.equal(manifest.name, PLUGIN_ID, 'package name');
  assert.equal(manifest.type, 'module', 'ESM package');
  assert.equal(manifest.dsh?.bundle?.patch, './cordis.patch.yml', 'bundle patch declared');
  assert.equal(manifest.dsh?.client?.platform, 'web', 'web client half declared');
  assert.equal(manifest.dsh?.client?.immediately, true, 'client bundle prefetched');
  assert.ok(manifest.exports?.['.'], 'host entry exported');
  assert.ok(manifest.exports?.['./client'], './client export declared');
  assert.ok(manifest.exports?.['./locale/*.json'], 'locale export declared');
  assert.ok(manifest.exports?.['./icon'], 'plugin icon export declared');
  assert.ok(manifest.files?.includes('client.js') && manifest.files?.includes('index.js'), 'runtime files listed');
  assert.ok(statSync(path.join(root, manifest.exports['./icon'])).size > 1000, 'plugin icon present');

  /** Read a PNG's pixel dimensions straight from its IHDR chunk. */
  const pngSize = (relative) => {
    const bytes = readFileSync(path.join(root, relative));
    assert.deepEqual([...bytes.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], `${relative} is a PNG`);
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  };
  assert.deepEqual(pngSize(manifest.exports['./icon']), { width: 256, height: 256 }, 'the inventory icon stays high resolution');
  assert.ok(manifest.engines?.dsh, 'dsh compatibility declared');

  const patch = readText('cordis.patch.yml');
  assert.match(patch, /- insert:/, 'bundle patch inserts a plugin row');
  assert.match(patch, new RegExp(`id: open-in-xyz`), 'patch inserts this plugin id');
  assert.match(patch, new RegExp(`name: '${PLUGIN_ID}'`), 'patch resolves this package');

  const locales = {};
  for (const lang of ['en', 'zh', 'ja', 'es', 'fr', 'de', 'ru', 'pt']) {
    locales[lang] = JSON.parse(readText(`locale/${lang}.json`));
    assert.ok(locales[lang].meta?.title, `locale/${lang}.json has a title`);
    assert.ok(locales[lang].meta?.description, `locale/${lang}.json has a description`);
  }
  assert.equal(locales.zh.meta.title, '在 XYZ 中打开', 'Chinese plugin title');
}

// -------------------------------------------------------------- host half --
assert.deepEqual([...hostInject].sort(), ['connection', 'webServer'], 'host injects the route carrier and the trust fence');
assert.deepEqual(ROUTES, internals.ROUTES, 'route table is shared');
assert.equal(internals.MAX_BODY_BYTES, 64 * 1024, 'bounded body ceiling');

/** Fake Cordis host context: captures routes and the connection rejection stub. */
function createHostHarness() {
  const routes = new Map();
  const effects = [];
  let rejection;
  const ctx = {
    effect(fn, label) {
      const dispose = fn();
      effects.push({ label, dispose });
      return dispose;
    },
    webServer: {
      register(entry) {
        routes.set(entry.path, entry);
        return () => routes.delete(entry.path);
      }
    },
    connection: {
      requestRejection: () => rejection
    }
  };
  return {
    routes,
    effects,
    ctx,
    setRejection(status) {
      rejection = status;
    }
  };
}

/** Fake res: records status, headers, and body. */
function createResponse() {
  return {
    statusCode: 200,
    headers: {},
    body: undefined,
    writableEnded: false,
    setHeader(name, value) {
      this.headers[String(name).toLowerCase()] = value;
    },
    end(chunk) {
      this.writableEnded = true;
      if (chunk !== undefined) this.body = Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk));
    }
  };
}

/** Fake req: a Readable stream carrying the body, with method/url/headers attached. */
function createRequest({ method = 'GET', url = '/', headers = {}, body } = {}) {
  const stream = body === undefined ? Readable.from([]) : Readable.from([Buffer.from(body)]);
  stream.method = method;
  stream.url = url;
  stream.headers = headers;
  return stream;
}

/** Invoke one captured route handler and settle its (possibly async) response. */
async function callRoute(handler, options) {
  const req = createRequest(options);
  const res = createResponse();
  await handler(req, res);
  return res;
}

/** Parse one JSON response body. */
function jsonBody(res) {
  assert.ok(res.body !== undefined, 'JSON response has a body');
  return JSON.parse(res.body.toString('utf8'));
}

const host = createHostHarness();
applyHost(host.ctx);

assert.deepEqual([...host.routes.keys()].sort(), Object.values(ROUTES).sort(), 'all three routes registered');
for (const route of host.routes.values()) assert.equal(route.kind, 'exact', `${route.path} is an exact route`);

const route = (key) => host.routes.get(ROUTES[key]).handler;

// Trust fence: an untrusted request is answered with the connection's status and no payload.
{
  host.setRejection(403);
  const res = await callRoute(route('state'), { method: 'GET' });
  assert.equal(res.statusCode, 403, 'untrusted request rejected');
  assert.equal(res.body, undefined, 'untrusted request gets no payload');
  host.setRejection(undefined);
}

// State: availability probe.
{
  const res = await callRoute(route('state'), { method: 'GET', headers: { host: '127.0.0.1:63420' } });
  assert.equal(res.statusCode, 200, 'state answers GET');
  assert.equal(res.headers['content-type'], 'application/json; charset=utf-8');
  assert.equal(res.headers['cache-control'], 'no-store');
  const body = jsonBody(res);
  assert.equal(body.ok, true);
  assert.equal(typeof body.available, 'boolean', 'availability is reported as a boolean');
  assert.equal(body.platform, process.platform);
  assert.equal(body.available, internals.resolveLauncher() !== null, 'availability mirrors Host detection');
  assert.ok(body.available === false || typeof body.appPath === 'string' || typeof body.cliPath === 'string', 'a resolved launcher is named');

  const wrongMethod = await callRoute(route('state'), { method: 'POST' });
  assert.equal(wrongMethod.statusCode, 405, 'state refuses non-GET');
  assert.equal(wrongMethod.headers.allow, 'GET');
}

// POST routes: method, media type, bounded one-field body, absolute existing directory.
for (const key of ['open', 'reveal']) {
  const post = route(key);

  const wrongMethod = await callRoute(post, { method: 'GET' });
  assert.equal(wrongMethod.statusCode, 405, `${key} refuses non-POST`);
  assert.equal(wrongMethod.headers.allow, 'POST');

  const wrongType = await callRoute(post, {
    method: 'POST',
    headers: { 'content-type': 'text/plain' },
    body: JSON.stringify({ path: tmpdir() })
  });
  assert.equal(wrongType.statusCode, 415, `${key} requires JSON`);
  assert.equal(jsonBody(wrongType).code, 'unsupported_media_type');

  const badJson = await callRoute(post, {
    method: 'POST',
    headers: { 'content-type': 'application/json; charset=utf-8' },
    body: '{not json'
  });
  assert.equal(badJson.statusCode, 400, `${key} refuses malformed JSON`);
  assert.equal(jsonBody(badJson).code, 'invalid_path');

  for (const body of [
    { path: '' },
    { path: 'relative/dir' },
    { path: 42 },
    { path: `${tmpdir()}\u0000trailer` },
    { path: 'x'.repeat(internals.MAX_PATH_LENGTH + 1) },
    { other: tmpdir() },
    { path: tmpdir(), app: 'vscode' },
    { path: tmpdir(), extra: true },
    [tmpdir()]
  ]) {
    const res = await callRoute(post, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    });
    assert.equal(res.statusCode, 400, `${key} refuses ${JSON.stringify(body).slice(0, 60)}`);
    assert.equal(jsonBody(res).code, 'invalid_path');
  }

  const missing = await callRoute(post, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ path: path.join(tmpdir(), 'dsh-open-in-xyz-does-not-exist') })
  });
  assert.equal(missing.statusCode, 404, `${key} refuses a path that is not a directory`);
  assert.equal(jsonBody(missing).code, 'no_directory');

  const oversized = await callRoute(post, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ path: tmpdir(), padding: 'x'.repeat(internals.MAX_BODY_BYTES) })
  });
  assert.equal(oversized.statusCode, 413, `${key} refuses an oversized body`);
  assert.equal(jsonBody(oversized).code, 'payload_too_large');
}

// Success paths with a stubbed handoff runner (never launches a real app).
{
  const launches = [];
  const originalRunHandoff = internals.runHandoff;
  internals.runHandoff = async (command, args) => {
    launches.push([command, args]);
  };
  const workspace = path.join(tmpdir(), 'dsh open-in-xyz 测试 目录');
  mkdirSync(workspace, { recursive: true });
  try {
    const launcher = internals.resolveLauncher();
    const res = await callRoute(route('open'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ path: workspace })
    });
    if (launcher === null) {
      assert.equal(res.statusCode, 409, 'open reports a missing application');
      assert.equal(jsonBody(res).code, 'app_missing');
      assert.equal(launches.length, 0, 'nothing launches without an application');
    } else {
      assert.equal(res.statusCode, 200, 'open acknowledges the handoff');
      assert.deepEqual(jsonBody(res), { ok: true });
      assert.equal(launches.length, 1, 'one handoff per gesture');
      const [command, args] = launches[0];
      if (launcher.kind === 'app') {
        assert.equal(command, '/usr/bin/open', 'application bundles go through LaunchServices');
        assert.deepEqual(args, ['-a', launcher.bundle, workspace], 'argv keeps the spaced/CJK path intact');
      } else {
        assert.equal(command, launcher.command, 'CLI fallback is used verbatim');
        assert.deepEqual(args, [workspace], 'CLI receives the directory as one argv element');
      }
    }

    launches.length = 0;
    const reveal = await callRoute(route('reveal'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ path: workspace })
    });
    if (process.platform === 'darwin') {
      assert.equal(reveal.statusCode, 200, 'reveal acknowledges the handoff');
      assert.deepEqual(launches, [['/usr/bin/open', ['-R', workspace]]], 'reveal selects the folder in Finder');
    } else {
      assert.equal(reveal.statusCode, 501, 'reveal is macOS-only');
      assert.equal(launches.length, 0, 'nothing launches on an unsupported platform');
    }
  } finally {
    internals.runHandoff = originalRunHandoff;
    rmSync(workspace, { recursive: true, force: true });
  }
}

// ------------------------------------------------------------ client half --
const clientSource = readText('client.js');

/** Minimal React hook runtime: one state slot per hook call, effects on first render. */
function createReactStub() {
  const hooks = [];
  let cursor = 0;
  let effects = [];
  const stub = {
    Fragment: Symbol('Fragment'),
    createElement(type, props, ...children) {
      const normalized = { ...(props ?? {}) };
      if (children.length === 1) normalized.children = children[0];
      else if (children.length > 1) normalized.children = children;
      return { type, props: normalized };
    },
    useState(initial) {
      const index = cursor++;
      if (!(index in hooks)) hooks[index] = typeof initial === 'function' ? initial() : initial;
      const set = (next) => {
        hooks[index] = typeof next === 'function' ? next(hooks[index]) : next;
      };
      return [hooks[index], set];
    },
    useEffect(fn) {
      const index = cursor++;
      if (!(index in hooks)) {
        hooks[index] = true;
        effects.push(fn);
      }
    },
    useRef(value) {
      const index = cursor++;
      if (!(index in hooks)) hooks[index] = { current: value };
      return hooks[index];
    },
    /** Render one component with this stub's hooks; run newly collected effects. */
    __render(component, props) {
      cursor = 0;
      effects = [];
      const tree = component(props);
      for (const effect of effects) effect();
      return tree;
    }
  };
  return stub;
}

/** Shared primitive stubs; identity is what the assertions compare against. */
const primitives = {
  Menu() {},
  Tooltip() {},
  IconChevronDownOutlineRegular() {},
  IconFolderOpenOutlineRegular() {}
};

/** The stylesheet tag the client half appends, for one boot. */
const documentStub = {
  tags: [],
  head: {
    appendChild(tag) {
      documentStub.tags.push(tag);
    },
    removeChild() {}
  },
  createElement(tagName) {
    return { tagName, dataset: {}, textContent: '', parentElement: documentStub.head };
  },
  querySelector() {
    return null;
  }
};

/** Swappable fetch implementation for the client half. */
let activeFetch = () => Promise.reject(new Error('no fetch stub installed'));
const capturedEntries = [];
const sandbox = {
  console,
  setTimeout,
  clearTimeout,
  queueMicrotask,
  document: documentStub,
  fetch: (...args) => activeFetch(...args),
  window: {
    __ModuleLoader__: {
      load(entry) {
        capturedEntries.push(entry);
      }
    }
  }
};
vm.createContext(sandbox);
vm.runInContext(clientSource, sandbox, { filename: 'client.js' });
assert.equal(capturedEntries.length, 1, 'the client bundle registers exactly one factory');
const entry = capturedEntries[0];
assert.equal(entry.id, PLUGIN_ID, 'the client module id is the package name');

/** Materialize the client plugin with a fresh React stub. */
function bootClient() {
  const react = createReactStub();
  documentStub.tags.length = 0;
  const moduleExports = entry.factory((specifier) => {
    if (specifier === 'react') return react;
    if (specifier === '@deepseek-ai/dsh-client-ui-primitives') return primitives;
    throw new Error(`unexpected require(${JSON.stringify(specifier)})`);
  });
  return { react, moduleExports };
}

/** Fake client Cordis context capturing slot/locale/style registrations. */
function createClientHarness() {
  const injections = [];
  const registrations = [];
  const localeRegistrations = [];
  const effects = [];
  const notices = [];
  const ctx = {
    effect(fn, label) {
      const dispose = fn();
      effects.push({ label, dispose });
      return dispose;
    },
    locale: {
      register(namespace, dictionaries) {
        localeRegistrations.push({ namespace, dictionaries });
        return () => {};
      },
      bind: () => (key) => key
    },
    slots: {
      inject(key, callback) {
        // The live registry runs the callback as soon as the slot is declared.
        const disposers = injections.push({ key, callback });
        const dispose = callback();
        assert.ok(disposers > 0, 'slot injection recorded');
        return dispose;
      },
      register(options, component) {
        registrations.push({ options, component });
        return () => {};
      }
    },
    contextMenus: {
      notify(text, success) {
        notices.push({ text, success });
      }
    }
  };
  return { ctx, injections, registrations, localeRegistrations, effects, notices };
}

/** JSON response stub. */
function jsonResponse(status, body) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => body
  };
}

/** Settle the client half's promise chain. */
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

/** Materialize, apply, and return one fully registered client plugin. */
function installClient() {
  const { react, moduleExports } = bootClient();
  assert.deepEqual([...moduleExports.inject].sort(), ['contextMenus', 'locale', 'slots'], 'client injects slots, locale, and the notice seat');
  const harness = createClientHarness();
  moduleExports.apply(harness.ctx);
  return { react, moduleExports, ...harness };
}

/** Extract the shipped-Open-In shadow registration from a harness. */
function shadowRegistration(harness) {
  const shadow = harness.registrations.find(({ options }) => options.id === SHIPPED_ENTRY_ID);
  assert.ok(shadow !== undefined, 'the shipped header entry is shadowed');
  return shadow;
}

// Registration contract: two entries in the same list slot, our button plus the shadow.
{
  const harness = installClient();
  assert.equal(harness.injections.length, 2, 'two slot contributions');
  for (const injection of harness.injections) assert.equal(injection.key, SLOT, 'both target the header utilities slot');

  const button = harness.registrations.find(({ options }) => options.id === 'open-in-xyz');
  assert.ok(button !== undefined, 'our button registers with its own cell id');
  assert.equal(button.options.name, SLOT);
  assert.equal(button.options.order, -10, 'same order as the shipped entry');
  assert.equal(button.options.locale, 'openInXyz', 'locale seat declared');
  assert.equal(typeof button.component, 'function', 'button component is a function');

  const shadow = shadowRegistration(harness);
  assert.equal(shadow.options.name, SLOT);
  assert.equal(shadow.options.priority, -1, 'shadow priority beats the shipped default (0)');
  assert.equal(shadow.component(), null, 'the shadow renders nothing');

  // Dictionaries: zh is the key-set source of truth, every other language falls back to en.
  assert.equal(harness.localeRegistrations.length, 1);
  const { namespace, dictionaries } = harness.localeRegistrations[0];
  assert.equal(namespace, 'openInXyz');
  const zhKeys = Object.keys(dictionaries.zh).sort();
  assert.ok(zhKeys.includes('tooltip.open') && zhKeys.includes('menu.revealInFinder'), 'menu and tooltip strings are localized');
  assert.ok(zhKeys.includes('menu.openInVscode') && zhKeys.includes('error.vscodeFailed'), 'VS Code strings are localized');
  assert.deepEqual(Object.keys(dictionaries.en).sort(), zhKeys, 'en is key-identical to zh');
  for (const lang of ['ja', 'es', 'fr', 'de', 'ru', 'pt']) assert.equal(dictionaries[lang], dictionaries.en, `${lang} falls back to en`);

  // Stylesheet: official metrics, theme-driven dark icon, and the narrow fallback.
  assert.equal(documentStub.tags.length, 1, 'one stylesheet tag');
  const tag = documentStub.tags[0];
  assert.equal(tag.dataset.plugin, PLUGIN_ID);
  assert.equal(tag.dataset.pluginCss, PLUGIN_ID);
  const css = tag.textContent;
  for (const token of ['--dsw-alias-border-l4', '--dsw-radius-sm', '--dsw-alias-interactive-bg-hover']) {
    assert.ok(css.includes(token), `stylesheet reuses the theme token ${token}`);
  }
  // The header/menu mark follows the theme through currentColor instead of a
  // light/dark PNG pair.
  assert.ok(clientSource.includes("fill: 'currentColor'"), 'the wordmark lettering follows the theme colour');
  assert.ok(clientSource.includes("const WORDMARK_ACCENT = '#0078D4'"), 'the underscore keeps the app icon brand blue');
  assert.match(css, /height:24px/, '24px split button');
  assert.ok(css.includes('.doix-wordmark{flex:none;display:block}'), 'inline wordmark layout rule');
  assert.match(css, /\.doix-main,\.doix-chevron\{/, 'shared button reset');
  const fallback = `[data-slot="${SLOT}"] [data-open-target="directory"]{display:none!important}`;
  assert.ok(css.includes(fallback), 'fallback rule is scoped to the one slot anchor');
  assert.ok(
    css.includes(`[data-slot="${SLOT}"]>span:has(>[data-open-target="directory"]){display:none!important}`),
    'fallback also hides the shipped slot item itself'
  );
}

// Render contract: same shape as the shipped split button, localized tooltips, live gesture plumbing.
{
  /** Type of the first menu item's icon element. */
  const items_first_icon_type = (tree) => typeof tree.props.items[0].icon.type;
  const harness = installClient();
  const component = harness.registrations.find(({ options }) => options.id === 'open-in-xyz').component;
  const cwd = '/Users/lizhichao/vc/macos/dsh/dsh-preset/工作 目录';
  const posts = [];
  const stateCalls = [];
  const appsCalls = [];
  let failLaunch = false;
  activeFetch = async (url, init) => {
    if (url === ROUTES.state) {
      stateCalls.push(init);
      return jsonResponse(200, { ok: true, available: true });
    }
    if (url === '/open-in-app/apps') {
      appsCalls.push(init);
      return jsonResponse(200, { apps: ['finder', 'cursor', 'vscode'] });
    }
    if (url === ROUTES.open || url === ROUTES.reveal || url === '/open-in-app/open') {
      posts.push({ url, init });
      return jsonResponse(failLaunch ? 502 : 200, failLaunch ? { ok: false, code: 'launch_failed' } : { ok: true });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
  const t = (key) => harness.localeRegistrations[0].dictionaries.zh[key] ?? key;
  const props = {
    sessionId: 'session-1',
    useSessions: (selector) => selector({ byId: { 'session-1': { cwd } } }),
    t
  };

  let tree = harness.react.__render(component, props);
  await flush();
  tree = harness.react.__render(component, props);
  assert.equal(stateCalls.length, 1, 'XYZ availability is probed once');
  assert.equal(stateCalls[0].credentials, 'same-origin');
  assert.equal(appsCalls.length, 1, 'the shipped application catalog is probed once for VS Code');
  assert.equal(appsCalls[0].credentials, 'same-origin');
  assert.equal(tree.type, primitives.Menu, 'the shipped split-button shell is reused');
  assert.equal(tree.props.className, 'doix-menuAnchor');
  assert.equal(tree.props.dense, true);
  assert.equal(tree.props.align, 'end');
  assert.equal(tree.props.portal, true);

  const anchor = tree.props.anchor;
  assert.equal(anchor.type, 'div');
  assert.equal(anchor.props.className, 'doix-split');
  assert.equal(anchor.props['data-size'], 'compact', 'compact size like the shipped header button');
  assert.equal(anchor.props['data-open-in-xyz'], 'directory');
  assert.equal(anchor.props['data-open-target'], undefined, 'our markup never carries the shipped marker the fallback hides');
  assert.equal(anchor.props.children.length, 2, 'main button plus chevron');

  const tooltip = anchor.props.children[0];
  assert.equal(tooltip.type, primitives.Tooltip);
  assert.equal(tooltip.props.portal, true);
  assert.equal(tooltip.props.label, '在 XYZ 中打开', 'tooltip is localized');
  assert.equal(tooltip.props.side, 'bottom');
  assert.equal(tooltip.props.delayMs, 500);
  const main = tooltip.props.children;
  assert.equal(main.type, 'button');
  assert.equal(main.props['aria-label'], '在 XYZ 中打开');
  assert.equal(main.props.disabled, false);
  assert.equal(typeof main.props.children.type, 'function', 'the header mark is the inline wordmark component');
  assert.notEqual(main.props.children.type, primitives.Menu, 'the header mark is ours, not a primitive');
  assert.equal(main.props.children.props.ink, 9, 'the header mark uses the compact 9px ink height');
  assert.equal(items_first_icon_type(tree), 'function', 'the menu keeps a per-app icon component');

  const chevron = anchor.props.children[1];
  assert.equal(chevron.type, 'button');
  assert.equal(chevron.props['aria-haspopup'], 'menu');
  assert.equal(chevron.props['aria-expanded'], false);
  assert.equal(chevron.props['aria-label'], '更多打开方式');

  const items = tree.props.items;
  assert.deepEqual([...items].map((item) => item.id), ['open', 'vscode', 'reveal'], 'menu offers XYZ, VS Code, and Finder');
  assert.equal(items[0].label, '在 XYZ 中打开');
  assert.equal(items[1].label, '在 VS Code 中打开', 'the VS Code item is localized');
  assert.equal(items[2].label, '在 Finder 中显示');
  assert.equal(typeof items[1].icon.type, 'function', 'the VS Code item carries an icon component');
  assert.equal(items[0].icon.props.ink, 6.3, 'the menu mark uses the small ink height (wider than the 14px icon cell)');

  main.props.onClick();
  await flush();
  assert.equal(posts.length, 1, 'primary click posts once');
  assert.equal(posts[0].url, ROUTES.open);
  assert.equal(posts[0].init.method, 'POST');
  assert.equal(posts[0].init.headers['content-type'], 'application/json');
  assert.equal(posts[0].init.credentials, 'same-origin');
  assert.deepEqual(JSON.parse(posts[0].init.body), { path: cwd }, 'the session cwd travels intact');
  assert.equal(harness.notices.length, 0, 'a successful open is silent');

  tree.props.onSelect('vscode');
  await flush();
  assert.equal(posts.length, 2, 'the VS Code item posts once');
  assert.equal(posts[1].url, '/open-in-app/open', 'VS Code reuses the shipped launch route');
  assert.equal(posts[1].init.method, 'POST');
  assert.deepEqual(JSON.parse(posts[1].init.body), { app: 'vscode', path: cwd }, 'the shipped route receives the app id and cwd');
  assert.equal(harness.notices.length, 0, 'a successful VS Code open is silent');

  tree.props.onSelect('reveal');
  await flush();
  assert.equal(posts.length, 3, 'menu selection posts once');
  assert.equal(posts[2].url, ROUTES.reveal);
  assert.equal(harness.notices.length, 0, 'a successful reveal is silent');

  failLaunch = true;
  tree.props.onSelect('vscode');
  await flush();
  assert.equal(posts.length, 4);
  assert.equal(harness.notices.length, 1, 'a failed VS Code launch is announced');
  assert.equal(harness.notices[0].text, '无法在 VS Code 中打开该工作目录，请重试', 'VS Code failure text is localized');
  assert.equal(harness.notices[0].success, false);

  tree.props.onSelect('open');
  await flush();
  assert.equal(posts.length, 5);
  assert.equal(harness.notices.length, 2, 'a failed XYZ launch is announced');
  assert.equal(harness.notices[1].text, '打不开该工作目录，请重试', 'failure text is localized');
}

// The button stays out of the header without a workspace cwd, and hides when XYZ is missing.
{
  const harness = installClient();
  const component = harness.registrations.find(({ options }) => options.id === 'open-in-xyz').component;
  activeFetch = async () => jsonResponse(200, { ok: true, available: true });
  assert.equal(
    harness.react.__render(component, { sessionId: 's', useSessions: (selector) => selector({ byId: { s: {} } }), t: (key) => key }),
    null,
    'no workspace cwd renders no button'
  );

  const missing = installClient();
  const missingComponent = missing.registrations.find(({ options }) => options.id === 'open-in-xyz').component;
  activeFetch = async (url) => {
    if (url === ROUTES.state) return jsonResponse(200, { ok: true, available: false });
    if (url === '/open-in-app/apps') return jsonResponse(200, { apps: ['finder', 'vscode'] });
    throw new Error(`unexpected fetch ${url}`);
  };
  const missingProps = {
    sessionId: 's',
    useSessions: (selector) => selector({ byId: { s: { cwd: tmpdir() } } }),
    t: (key) => key
  };
  assert.notEqual(missing.react.__render(missingComponent, missingProps), null, 'the button renders optimistically while the probe is in flight');
  await flush();
  assert.equal(missing.react.__render(missingComponent, missingProps), null, 'a missing XYZ install hides the button');

  const noVscode = installClient();
  const noVscodeComponent = noVscode.registrations.find(({ options }) => options.id === 'open-in-xyz').component;
  activeFetch = async (url) => {
    if (url === ROUTES.state) return jsonResponse(200, { ok: true, available: true });
    if (url === '/open-in-app/apps') return jsonResponse(200, { apps: ['finder', 'cursor'] });
    throw new Error(`unexpected fetch ${url}`);
  };
  const noVscodeProps = {
    sessionId: 's',
    useSessions: (selector) => selector({ byId: { s: { cwd: tmpdir() } } }),
    t: (key) => key
  };
  let noVscodeTree = noVscode.react.__render(noVscodeComponent, noVscodeProps);
  await flush();
  noVscodeTree = noVscode.react.__render(noVscodeComponent, noVscodeProps);
  assert.deepEqual([...noVscodeTree.props.items].map((item) => item.id), ['open', 'reveal'], 'VS Code stays out of the menu when the shipped catalog does not resolve it');
}

console.log('open-in-xyz smoke: all assertions passed');
