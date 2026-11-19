// NW.js `node-main` for native runs: before the page loads, every require of
// greenworks (module, .node binding, or vendored path) returns greenworks.js.

'use strict';

const path = require('path');
const Module = require('module');

const shimPath = path.join(__dirname, 'greenworks.js');

if (!process.env.SEVO_STEAM_STUB_PORT) process.env.SEVO_STEAM_STUB_PORT = '27060';

// `greenworks`, `greenworks.js`, `greenworks-win32.node`, `greenworks-osx64.node`,
// `lib/greenworks-win64`, and `…/greenworks/index.js` all name the same module.
const NAMES = /^greenworks(-[a-z0-9_]+)?(\.js|\.node)?$/i;

function isGreenworks(request) {
  if (typeof request !== 'string' || request.indexOf('greenworks') < 0) return false;
  const parts = request.replace(/\\/g, '/').split('/').filter((p) => p && p !== '.' && p !== '..');
  const last = parts[parts.length - 1];
  if (!last) return false;
  if (NAMES.test(last)) return true;
  return /^index\.(js|node)$/i.test(last) && parts[parts.length - 2] === 'greenworks';
}

const shim = require(shimPath);

const loadModule = Module._load;
Module._load = function (request, parent, isMain) {
  if (isGreenworks(request)) return shim;
  return loadModule.apply(this, arguments);
};

// Anything that resolves a path of its own before loading it — a bundler
// shim, a plugin doing require.resolve — lands on the same file.
const resolveFilename = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  if (isGreenworks(request)) return shimPath;
  return resolveFilename.apply(this, arguments);
};

Module._cache[shimPath] = Module._cache[shimPath] || { id: shimPath, filename: shimPath, loaded: true, exports: shim };

module.exports = shim;
