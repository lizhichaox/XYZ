/**
 * Host half — "Open in XYZ" for the Session workspace directory.
 *
 * The browser half (`./client.js`) renders a split button in the conversation
 * Session header. It cannot spawn a local application, so this half owns the
 * launch and registers three routes on the composition's `webServer`:
 *
 *   GET  /open-in-xyz/state        -> { ok: true, available, platform, appPath, cliPath }
 *   POST /open-in-xyz/open         -> { ok: true } | { ok: false, code }
 *   POST /open-in-xyz/reveal       -> { ok: true } | { ok: false, code }
 *
 * Security is borrowed from the shipped `open-in-app` host: every route asks
 * the composition's `connection` service for a rejection first
 * (`requestRejection`), whose Host/Origin fence defeats DNS rebinding and
 * cross-site calls and whose browser authentication gates every caller. On top
 * of that fence the two POST routes validate their body at the wire: an
 * `application/json` media type, a 64 KiB ceiling, one string `path` field and
 * no other field, an absolute path, and an existing directory. Nothing else
 * leaves the Host: the application (or its CLI fallback) is auto-detected
 * here, never supplied by the browser, and every process is spawned with an
 * argv array through `execFile` — no shell, no interpolation.
 *
 * Detection is deliberately zero-config: `/Applications/XYZ.app` (or the
 * per-user Applications folder) is preferred; when only the `xyz` CLI is
 * installed, that CLI is used instead.
 */

import { execFile } from 'node:child_process';
import { accessSync, constants, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { isAbsolute } from 'node:path';
import { promisify } from 'node:util';

/** Cordis function-plugin name. */
export const name = 'open-in-xyz';
/** Required services: the route carrier and the connection trust fence. */
export const inject = ['webServer', 'connection'];

/** Browser-visible route table; the Client half hard-codes the same paths. */
export const ROUTES = Object.freeze({
  state: '/open-in-xyz/state',
  open: '/open-in-xyz/open',
  reveal: '/open-in-xyz/reveal'
});

/** macOS `open` binary: LaunchServices handoff, always spawned with an argv array. */
const OPEN_BIN = '/usr/bin/open';
/** POST bodies are tiny JSON objects; anything larger is hostile. */
const MAX_BODY_BYTES = 64 * 1024;
/** Longest absolute path the routes accept. */
const MAX_PATH_LENGTH = 4096;
/** How long one launch handoff may take before the route reports failure. */
const LAUNCH_TIMEOUT_MS = 15_000;

/** Application bundles searched in order; the first existing directory wins. */
const APP_BUNDLE_CANDIDATES = ['/Applications/XYZ.app', `${homedir()}/Applications/XYZ.app`];
/** CLI fallbacks used only when no application bundle resolves. */
const CLI_CANDIDATES = ['/opt/homebrew/bin/xyz', '/usr/local/bin/xyz'];

/** Whether `path` names an existing directory. */
function isDirectory(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

/** Whether `path` names an existing executable file. */
function isExecutable(path) {
  try {
    if (!statSync(path).isFile()) return false;
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * One resolved launch handoff: an application bundle for LaunchServices, or the
 * resolved CLI fallback.
 * @typedef {{ kind: 'app', bundle: string } | { kind: 'cli', command: string }} Launcher
 */

/**
 * Resolve how to open a directory in XYZ, auto-detecting the local install.
 * @returns {Launcher | null} the preferred launch handoff, or null when XYZ is
 *   not installed.
 */
export function resolveLauncher() {
  for (const bundle of APP_BUNDLE_CANDIDATES) {
    if (isDirectory(bundle)) return { kind: 'app', bundle };
  }
  for (const command of CLI_CANDIDATES) {
    if (isExecutable(command)) return { kind: 'cli', command };
  }
  return null;
}

/** JSON response (no-store: availability and launch outcomes are live facts). */
function sendJson(res, status, payload) {
  if (res.writableEnded === true) return;
  res.statusCode = status;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.setHeader('cache-control', 'no-store');
  res.end(JSON.stringify(payload));
}

/** 405 with the route's one supported method. */
function sendMethodNotAllowed(res, allow) {
  res.statusCode = 405;
  res.setHeader('allow', allow);
  res.end();
}

/**
 * Collect a bounded request body as UTF-8 text.
 * @returns the body, or null when it exceeds {@link MAX_BODY_BYTES} (stream drained).
 */
export async function readBoundedBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.byteLength;
    if (size > MAX_BODY_BYTES) {
      req.resume();
      return null;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, size).toString('utf8');
}

/**
 * Validate one POST body at the wire: a JSON object carrying one non-empty
 * absolute `path` string and no other field. Everything else is refused before
 * any filesystem or process work happens.
 * @param {string} text - the raw UTF-8 request body.
 * @returns {{ path: string } | null} the accepted path, or null when invalid.
 */
export function parsePathBody(text) {
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) return null;
  const fields = Object.keys(body);
  if (fields.length !== 1 || fields[0] !== 'path') return null;
  const path = body.path;
  if (typeof path !== 'string') return null;
  if (path === '' || path.length > MAX_PATH_LENGTH) return null;
  if (path.includes('\u0000')) return null;
  if (!isAbsolute(path)) return null;
  return { path };
}

const execFileAsync = promisify(execFile);

/**
 * Run one handoff process with a fixed argv array (never a shell).
 * @param {string} command - absolute executable path.
 * @param {string[]} args - argv array.
 * @returns {Promise<void>} resolves on exit 0; rejects on spawn error or nonzero exit.
 */
async function runHandoff(command, args) {
  await execFileAsync(command, args, {
    timeout: LAUNCH_TIMEOUT_MS,
    maxBuffer: MAX_BODY_BYTES,
    windowsHide: true
  });
}

/**
 * Open one existing directory in XYZ.
 * @param {string} directory - absolute path to an existing directory.
 * @param {Launcher} launcher - the request's one detection result.
 */
async function launchInXyz(directory, launcher) {
  if (launcher.kind === 'app') await internals.runHandoff(OPEN_BIN, ['-a', launcher.bundle, directory]);
  else await internals.runHandoff(launcher.command, [directory]);
}

/** Reveal one existing directory in Finder. */
async function revealInFinder(directory) {
  await internals.runHandoff(OPEN_BIN, ['-R', directory]);
}

/**
 * Register the state and launch routes behind the connection trust fence.
 * @param ctx - Host plugin context carrying `webServer` and `connection`.
 */
export function apply(ctx) {
  /** Answer an untrusted/unauthenticated request; true when it was rejected. */
  const rejected = (req, res) => {
    let rejection;
    try {
      rejection = Reflect.get(ctx, 'connection')?.requestRejection?.(req);
    } catch {
      rejection = 403;
    }
    if (rejection === undefined) return false;
    res.statusCode = typeof rejection === 'number' ? rejection : 403;
    res.end();
    return true;
  };

  const stateHandler = async (req, res) => {
    if (rejected(req, res)) return;
    if (req.method !== 'GET') {
      sendMethodNotAllowed(res, 'GET');
      return;
    }
    const launcher = resolveLauncher();
    sendJson(res, 200, {
      ok: true,
      available: launcher !== null,
      platform: process.platform,
      appPath: launcher !== null && launcher.kind === 'app' ? launcher.bundle : null,
      cliPath: launcher !== null && launcher.kind === 'cli' ? launcher.command : null
    });
  };

  /** Shared body pipeline for the two POST routes: fence, method, media type, bounded JSON. */
  const readActionPath = async (req, res) => {
    if (rejected(req, res)) return null;
    if (req.method !== 'POST') {
      sendMethodNotAllowed(res, 'POST');
      return null;
    }
    const mediaType = String(req.headers['content-type'] ?? '')
      .split(';', 1)[0]
      .trim()
      .toLowerCase();
    if (mediaType !== 'application/json') {
      sendJson(res, 415, { ok: false, code: 'unsupported_media_type' });
      return null;
    }
    let text;
    try {
      text = await readBoundedBody(req);
    } catch {
      sendJson(res, 400, { ok: false, code: 'body_unreadable' });
      return null;
    }
    if (text === null) {
      sendJson(res, 413, { ok: false, code: 'payload_too_large' });
      return null;
    }
    const parsed = parsePathBody(text);
    if (parsed === null) {
      sendJson(res, 400, { ok: false, code: 'invalid_path' });
      return null;
    }
    if (!isDirectory(parsed.path)) {
      sendJson(res, 404, { ok: false, code: 'no_directory' });
      return null;
    }
    return parsed.path;
  };

  const openHandler = async (req, res) => {
    const directory = await readActionPath(req, res);
    if (directory === null) return;
    const launcher = resolveLauncher();
    if (launcher === null) {
      sendJson(res, 409, { ok: false, code: 'app_missing' });
      return;
    }
    try {
      await launchInXyz(directory, launcher);
      sendJson(res, 200, { ok: true });
    } catch (error) {
      console.error('[open-in-xyz] could not open the workspace in XYZ:', error?.code ?? error?.message);
      sendJson(res, 502, { ok: false, code: 'launch_failed' });
    }
  };

  const revealHandler = async (req, res) => {
    const directory = await readActionPath(req, res);
    if (directory === null) return;
    if (process.platform !== 'darwin') {
      sendJson(res, 501, { ok: false, code: 'unsupported_platform' });
      return;
    }
    try {
      await revealInFinder(directory);
      sendJson(res, 200, { ok: true });
    } catch (error) {
      console.error('[open-in-xyz] could not reveal the workspace in Finder:', error?.code ?? error?.message);
      sendJson(res, 502, { ok: false, code: 'reveal_failed' });
    }
  };

  ctx.effect(
    () => ctx.webServer.register({ kind: 'exact', path: ROUTES.state, handler: stateHandler }),
    `open-in-xyz: GET ${ROUTES.state}`
  );
  ctx.effect(
    () => ctx.webServer.register({ kind: 'exact', path: ROUTES.open, handler: openHandler }),
    `open-in-xyz: POST ${ROUTES.open}`
  );
  ctx.effect(
    () => ctx.webServer.register({ kind: 'exact', path: ROUTES.reveal, handler: revealHandler }),
    `open-in-xyz: POST ${ROUTES.reveal}`
  );
}

/**
 * Dependency-free seams used by the smoke test; not part of the plugin
 * contract. `runHandoff` is the one mutable member: the smoke test replaces it
 * so the success paths are exercised without launching a real application,
 * exactly like the test hooks of the shipped bundles. Production never
 * mutates it.
 */
export const internals = {
  APP_BUNDLE_CANDIDATES,
  CLI_CANDIDATES,
  MAX_BODY_BYTES,
  MAX_PATH_LENGTH,
  ROUTES,
  isDirectory,
  isExecutable,
  readBoundedBody,
  runHandoff,
  parsePathBody,
  resolveLauncher
};
