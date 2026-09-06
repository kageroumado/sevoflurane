// greenworks, answered from outside the bottle.
//
// The game is running in native macOS NW.js; its Steamworks connection lives
// in sevo-steamstub.exe, still inside the wine prefix. This module presents
// greenworks' API and forwards each call to the stub over loopback.
//
// preload.js installs it as the answer to every require of greenworks.

'use strict';

const fs = require('fs');
const net = require('net');
const EventEmitter = require('events').EventEmitter;

const DEFAULT_PORT = 27060;
const CONNECT_RETRY_MS = 250;
const CONNECT_ATTEMPTS = 40;
const REQUEST_TIMEOUT_MS = 5000;

function port() {
  const fromEnv = parseInt(process.env.SEVO_STEAM_STUB_PORT, 10);
  if (fromEnv > 0) return fromEnv;
  const file = process.env.SEVO_STEAM_STUB_PORT_FILE;
  if (file) {
    try {
      const written = parseInt(fs.readFileSync(file, 'utf8').trim(), 10);
      if (written > 0) return written;
    } catch (e) { /* the stub has not written it yet */ }
  }
  return DEFAULT_PORT;
}

function log(message) {
  if (process.env.SEVO_GREENWORKS_QUIET === '1') return;
  console.log('[sevo greenworks] ' + message);
}

// Sleeping without yielding the loop: the synchronous transport below has to
// wait for the stub without letting the game run in between.
const parkingSpot = typeof SharedArrayBuffer === 'function'
  ? new Int32Array(new SharedArrayBuffer(4)) : null;
function idle(ms) {
  if (parkingSpot) {
    try { Atomics.wait(parkingSpot, 0, 0, ms); return; } catch (e) { /* fall through */ }
  }
  const until = Date.now() + ms;
  while (Date.now() < until) { /* spin */ }
}

// ------------------------------------------------------------------ channel

// greenworks' getters are synchronous — getAchievementNames() returns an
// array, getStatInt() a number — so the transport has to be synchronous too.
// net.connect is used only to get a connected descriptor; every request after
// that is fs.writeSync/fs.readSync on it, spinning past EAGAIN.
const channel = {
  socket: null,
  fd: -1,
  connected: false,
  attempts: 0,
  rx: '',

  connect() {
    if (this.socket || this.connected) return;
    this.attempts += 1;
    const socket = net.connect(port(), '127.0.0.1');
    this.socket = socket;
    socket.on('connect', () => {
      socket.pause();
      const fd = socket._handle && socket._handle.fd;
      if (typeof fd !== 'number' || fd < 0) {
        log('the socket exposes no descriptor; Steam calls will report failure');
        socket.destroy();
        return;
      }
      this.fd = fd;
      this.connected = true;
      log('connected to the stub on port ' + port());
      greenworks.emit('steam-servers-connected');
    });
    socket.on('error', () => this.drop());
    socket.on('close', () => this.drop());
    // The stub outlives nothing: let the game exit whenever it likes.
    socket.unref();
  },

  // Closes the channel for good: a stub holding the wrong app will still be
  // there on the next attempt, so retrying only reaches it again.
  reject() {
    const socket = this.socket;
    this.attempts = CONNECT_ATTEMPTS;
    this.connected = false;
    this.fd = -1;
    this.socket = null;
    this.rx = '';
    if (socket) socket.destroy();
  },

  drop() {
    const wasConnected = this.connected;
    this.connected = false;
    this.fd = -1;
    this.socket = null;
    this.rx = '';
    if (wasConnected) {
      log('the stub closed the connection');
      greenworks.emit('steam-servers-disconnected');
      return;
    }
    if (this.attempts < CONNECT_ATTEMPTS) setTimeout(() => this.connect(), CONNECT_RETRY_MS).unref();
  },

  write(text) {
    const out = Buffer.from(text, 'utf8');
    let sent = 0;
    const deadline = Date.now() + REQUEST_TIMEOUT_MS;
    while (sent < out.length) {
      try {
        sent += fs.writeSync(this.fd, out, sent, out.length - sent);
      } catch (e) {
        if (e.code !== 'EAGAIN') throw e;
        if (Date.now() > deadline) throw new Error('timed out writing to the Steam stub');
        idle(1);
      }
    }
  },

  readLine() {
    const buf = Buffer.alloc(8192);
    const deadline = Date.now() + REQUEST_TIMEOUT_MS;
    for (;;) {
      const newline = this.rx.indexOf('\n');
      if (newline >= 0) {
        const line = this.rx.slice(0, newline);
        this.rx = this.rx.slice(newline + 1);
        return line;
      }
      let n = 0;
      try {
        n = fs.readSync(this.fd, buf, 0, buf.length, null);
      } catch (e) {
        if (e.code !== 'EAGAIN') throw e;
        if (Date.now() > deadline) throw new Error('timed out reading from the Steam stub');
        idle(1);
        continue;
      }
      if (n === 0) throw new Error('the Steam stub closed the connection');
      this.rx += buf.toString('utf8', 0, n);
    }
  },

  // Returns the stub's reply object. Throws when the channel is unusable.
  request(message) {
    if (!this.connected) throw new Error('not connected to the Steam stub');
    try {
      this.write(JSON.stringify(message) + '\n');
      return JSON.parse(this.readLine());
    } catch (e) {
      this.drop();
      throw e;
    }
  },
};

// A request that reports rather than throws, for the many greenworks getters
// that answer with a value and no error path.
function ask(message) {
  try {
    return channel.request(message);
  } catch (e) {
    log(message.op + ': ' + e.message);
    return { ok: false, error: e.message };
  }
}

// ---------------------------------------------------------------- SteamID

// Steam ids exceed 2^53, so the 64-bit value is kept as its decimal string and
// the halves are recovered by long division rather than by parsing it.
function splitSteamId(text) {
  let high = 0;
  let low = 0;
  for (let i = 0; i < text.length; ++i) {
    const digit = text.charCodeAt(i) - 48;
    if (digit < 0 || digit > 9) continue;
    const lowScaled = low * 10 + digit;
    high = high * 10 + Math.floor(lowScaled / 4294967296);
    low = lowScaled % 4294967296;
  }
  return { high: high % 4294967296, low: low };
}

const AccountType = {
  Invalid: 0, Individual: 1, Multiseat: 2, GameServer: 3, AnonGameServer: 4,
  Pending: 5, ContentServer: 6, Clan: 7, Chat: 8, ConsoleUser: 9, AnonUser: 10,
};

function makeSteamID(raw, personaName) {
  const text = String(raw || '0');
  const parts = splitSteamId(text);
  const accountType = (parts.high >>> 20) & 0xf;
  const instance = parts.high & 0xfffff;
  const universe = parts.high >>> 24;
  const is = (type) => accountType === type;

  return {
    // Plain fields for callers that read the object rather than call it.
    steamId: text,
    accountId: parts.low,
    screenName: personaName || '',
    isAnonymous: () => is(AccountType.AnonUser) || is(AccountType.AnonGameServer),
    isAnonymousGameServer: () => is(AccountType.AnonGameServer),
    isAnonymousGameServerLogin: () => is(AccountType.AnonGameServer) && instance === 0,
    isAnonymousUser: () => is(AccountType.AnonUser),
    isChatAccount: () => is(AccountType.Chat),
    isClanAccount: () => is(AccountType.Clan),
    isConsoleUserAccount: () => is(AccountType.ConsoleUser),
    isContentServerAccount: () => is(AccountType.ContentServer),
    isGameServerAccount: () => is(AccountType.GameServer) || is(AccountType.AnonGameServer),
    isIndividualAccount: () => is(AccountType.Individual) || is(AccountType.ConsoleUser),
    isPersistentGameServerAccount: () => is(AccountType.GameServer),
    isLobby: () => is(AccountType.Chat) && (instance & 0x40000) !== 0,
    isValid: () => accountType !== AccountType.Invalid && parts.low !== 0,
    getAccountID: () => parts.low,
    getRawSteamID: () => text,
    getAccountType: () => accountType,
    getStaticAccountKey: () => text,
    getPersonaName: () => personaName || '',
    getNickname: () => '',
    getRelationship: () => 0,
    getSteamLevel: () => 0,
    getUniverse: () => universe,
  };
}

// ------------------------------------------------------------- the module

const greenworks = new EventEmitter();

const state = {
  ready: false,
  steamId: null,
  appId: 0,
  language: '',
  personaName: '',
  achievementNames: null,
};

function unsupported(name, errorCallback) {
  log(name + ' is not carried across the bridge');
  if (typeof errorCallback === 'function') {
    process.nextTick(() => errorCallback(new Error(name + ' is unavailable when the game runs natively')));
  }
}

// Wraps a stub round trip in greenworks' success/error callback pair.
function relay(message, errorCallback, onSuccess) {
  let reply;
  try {
    reply = channel.request(message);
  } catch (e) {
    reply = { ok: false, error: e.message };
  }
  process.nextTick(() => {
    if (reply.ok) onSuccess(reply);
    else if (typeof errorCallback === 'function') errorCallback(new Error(reply.error || (message.op + ' failed')));
    else log(message.op + ': ' + (reply.error || 'failed'));
  });
}

greenworks.initAPI = function () {
  if (state.ready) return true;
  if (!channel.connected) {
    channel.connect();
    return false;
  }
  const reply = ask({ op: 'init' });
  if (!reply.ok) return false;
  // Every game dials the same default port, so a second game running at once
  // reaches the first one's stub, whose Steamworks connection is holding a
  // different app. Unlocking into it would credit the wrong game.
  const expected = parseInt(process.env.SEVO_STEAM_APPID, 10);
  if (expected > 0 && reply.appId !== expected) {
    log('the stub on port ' + port() + ' holds app ' + reply.appId + ', not ' + expected + '; refusing it');
    channel.reject();
    return false;
  }
  state.ready = true;
  state.steamId = makeSteamID(reply.steamId, reply.personaName);
  state.appId = reply.appId || 0;
  state.language = reply.language || '';
  state.personaName = reply.personaName || '';
  log('Steamworks ready for app ' + state.appId + ' as ' + state.personaName);
  return true;
};

greenworks.init = function () {
  if (this.initAPI()) return true;
  throw new Error('Steam initialization failed. The Sevoflurane Steam stub did not answer on port ' + port() + '.');
};

greenworks.isSteamRunning = function () {
  return channel.connected;
};

greenworks.isSteamRunningOnSteamDeck = function () { return false; };

greenworks.restartAppIfNecessary = function () { return false; };

greenworks.getSteamId = function () {
  return state.steamId || makeSteamID('0', '');
};

greenworks.getAppId = function () { return state.appId; };

greenworks.getAppBuildId = function () { return 0; };

greenworks.getCurrentGameLanguage = function () { return state.language; };

greenworks.getCurrentUILanguage = function () { return state.language; };

greenworks.getCurrentGameInstallDir = function () { return process.env.SEVO_NWJS_DIR || ''; };

greenworks.getAppInstallDir = function () { return process.env.SEVO_NWJS_DIR || ''; };

greenworks.getIPCountry = function () { return ''; };

greenworks.getLaunchCommandLine = function () { return ''; };

greenworks.isSubscribedApp = function (appId) { return Number(appId) === state.appId; };

greenworks.isAppInstalled = function (appId) { return Number(appId) === state.appId; };

// -------------------------------------------------------- achievements

greenworks.activateAchievement = function (achievement, successCallback, errorCallback) {
  relay({ op: 'activateAchievement', name: achievement }, errorCallback, () => {
    if (typeof successCallback === 'function') successCallback();
  });
};

greenworks.getAchievement = function (achievement, successCallback, errorCallback) {
  relay({ op: 'getAchievement', name: achievement }, errorCallback, (reply) => {
    if (typeof successCallback === 'function') successCallback(!!reply.achieved);
  });
};

greenworks.clearAchievement = function (achievement, successCallback, errorCallback) {
  relay({ op: 'clearAchievement', name: achievement }, errorCallback, () => {
    if (typeof successCallback === 'function') successCallback();
  });
};

greenworks.getAchievementNames = function () {
  if (state.achievementNames) return state.achievementNames;
  const reply = ask({ op: 'getAchievementNames' });
  if (!reply.ok) return [];
  state.achievementNames = reply.names || [];
  return state.achievementNames;
};

greenworks.getNumberOfAchievements = function () {
  const reply = ask({ op: 'getNumberOfAchievements' });
  return reply.ok ? reply.count : 0;
};

// Steam draws the progress toast, and Steam is on the other side of the
// bridge with no window to draw into.
greenworks.indicateAchievementProgress = function () { return false; };

// --------------------------------------------------------------- stats

greenworks.setStat = function (name, value) {
  return ask({ op: 'setStat', name: name, value: value }).ok;
};

greenworks.getStatInt = function (name) {
  const reply = ask({ op: 'getStat', name: name });
  return reply.ok ? reply.value : 0;
};

greenworks.getStatFloat = function (name) {
  const reply = ask({ op: 'getStatFloat', name: name });
  return reply.ok ? reply.value : 0;
};

greenworks.storeStats = function (successCallback, errorCallback) {
  relay({ op: 'storeStats' }, errorCallback, () => {
    if (typeof successCallback === 'function') successCallback(state.appId);
  });
};

greenworks.getNumberOfPlayers = function (successCallback, errorCallback) {
  unsupported('getNumberOfPlayers', errorCallback);
  if (!errorCallback && typeof successCallback === 'function') process.nextTick(() => successCallback(0));
};

// -------------------------------------------------------------- overlay

// The Steam overlay belongs to the wine process the game replaced; Sevoflurane
// draws its own over the bottle's client instead.
greenworks.isGameOverlayEnabled = function () { return false; };
greenworks.isSteamInBigPictureMode = function () { return false; };
greenworks.activateGameOverlay = function () { log('activateGameOverlay ignored'); };
greenworks.activateGameOverlayToWebPage = function () { log('activateGameOverlayToWebPage ignored'); };
greenworks.activateGameOverlayToStore = function () { log('activateGameOverlayToStore ignored'); };
greenworks.showFloatingGamepadTextInput = function () { return false; };
greenworks.FloatingGamepadTextInputMode = { SingleLine: 0, MultipleLines: 1, Email: 2, Numeric: 3 };

// ---------------------------------------------------------------- cloud

// Steam Cloud writes must reach Steam's own cloud directory or the save is
// lost, and the bridge carries no file transport. A game that stores progress
// through these belongs on the wine runner.
['saveTextToFile', 'saveFilesToCloud', 'fileShare'].forEach((name) => {
  greenworks[name] = function () {
    const errorCallback = arguments[arguments.length - 1];
    unsupported(name, typeof errorCallback === 'function' ? errorCallback : null);
  };
});
greenworks.readTextFromFile = function (fileName, successCallback, errorCallback) {
  unsupported('readTextFromFile', errorCallback);
};
greenworks.isCloudEnabled = function () { return false; };
greenworks.isCloudEnabledForUser = function () { return false; };
greenworks.enableCloud = function () { return false; };
greenworks.getCloudQuota = function (successCallback, errorCallback) {
  unsupported('getCloudQuota', errorCallback);
};

// ------------------------------------------------------------- friends

greenworks.getFriendCount = function () { return 0; };
greenworks.getFriends = function () { return []; };
greenworks.getFriendsAccount = function () { return 0; };
greenworks.requestUserInformation = function () { return false; };
greenworks.setListenForFriendsMessage = function () { return false; };
greenworks.getSmallFriendAvatar = function () { return 0; };
greenworks.getMediumFriendAvatar = function () { return 0; };
greenworks.getLargeFriendAvatar = function () { return 0; };
greenworks.getImageSize = function () { return { width: 0, height: 0 }; };
greenworks.getImageRGBA = function () { return Buffer.alloc(0); };

greenworks.FriendFlags = {
  None: 0x00, Blocked: 0x01, FriendshipRequested: 0x02, Immediate: 0x04,
  ClanMember: 0x08, OnGameServer: 0x10, RequestingFriendship: 0x80,
  RequestingInfo: 0x100, Ignored: 0x200, IgnoredFriend: 0x400,
  ChatMember: 0x1000, All: 0xffff,
};
greenworks.FriendRelationship = {
  None: 0, Blocked: 1, RequestRecipient: 2, Friend: 3, RequestInitiator: 4,
  Ignored: 5, IgnoredFriend: 6,
};
greenworks.AccountType = AccountType;
greenworks.PersonaChange = {
  Name: 0x001, Status: 0x002, ComeOnline: 0x004, GoneOffline: 0x008,
  GamePlayed: 0x010, GameServer: 0x020, Avatar: 0x040, JoinedSource: 0x080,
  LeftSource: 0x100, RelationshipChanged: 0x200, NameFirstSet: 0x400,
  FacebookInfo: 0x800, Nickname: 0x1000, SteamLevel: 0x2000,
};

// ----------------------------------------------------------------- utils

greenworks.Utils = {
  move(sourceDir, targetDir, successCallback, errorCallback) {
    fs.rename(sourceDir, targetDir, (err) => {
      if (err) {
        if (typeof errorCallback === 'function') errorCallback(err);
        return;
      }
      if (typeof successCallback === 'function') successCallback();
    });
  },
  createArchive(zipPath, sourceDir, password, level, successCallback, errorCallback) {
    unsupported('Utils.createArchive', errorCallback);
  },
  extractArchive(zipPath, extractDir, password, successCallback, errorCallback) {
    unsupported('Utils.extractArchive', errorCallback);
  },
};

greenworks.ui = {};

greenworks._version = 'sevoflurane-bridge';
try { process.versions.greenworks = greenworks._version; } catch (e) { /* frozen in some builds */ }

// Connecting takes an event loop turn, and preload.js runs long before the
// page does, so the channel is up by the time the game asks for it.
channel.connect();

module.exports = greenworks;
