import Foundation

/// Where things are in Steam's page, on either build of its UI.
///
/// Steam's UI ships as a webpack build or as a build of ES modules (Vite and
/// Rollup). ``source`` defines `steamSurface(ctx)`, which
/// ``SteamCompatBadge``, ``SteamLibraryCompat`` and ``SteamNativeBuilds``
/// each include and ask the same questions of; it detects the build once
/// and answers from whichever the page is:
///
/// | Question | webpack | ES modules |
/// |---|---|---|
/// | `classes` | the class map a module exports, found by its keys | each class read from a chunk's text (``SteamSurface/ClassRecipe``) |
/// | `stripSlot` | the info block's class, then its place in the page | the links bar, found through its component's props |
/// | `libraryFilter` | the export of the module that logs a marker | the class of `uiStore.collectionsAppFilter` |
/// | `observable`, `platformTest` | exports of the modules that carry a marker | exports of the modules the entry script imports |
/// | `pageListers` | the functions around a label in a module's source | the same, in a chunk's text |
///
/// On a build of ES modules the text is fetched from the page's own origin
/// and the modules are the ones the entry script has already run, so
/// nothing of Steam's is run a second time. Both take a moment: until they
/// are in, `ready` is false and `classes` is null, and the scripts wait as
/// they do for Steam's own globals.
enum SteamPageResolver {
    /// `steamSurface(ctx)`, for inclusion at the top of an injected script.
    static let source = #"""
      /* Steam's UI as a webpack build or a build of ES modules. `ctx` is the
         page Steam's scripts run in. What a build of ES modules was read
         for is kept on `ctx` as plain data, shared by every window's copy
         of this code. */
      function steamSurface(ctx) {
        /* A webpack class map: the keys its module's source holds, the
           longest source read, the keys its exports must carry. */
        var MAPS = {
          strip: { has: ["DeckVerifiedInfo"], limit: 4000, needs: ["Container", "DeckVerifiedInfo"] },
          play: { has: ["PlayButtonContainer", "StreamingSelector"], limit: 20000, needs: ["PlayButton"] },
          bar: { has: ["ActionSection", "GameStatsSection"], limit: 20000, needs: ["GameStatsSection"] },
          button: { has: ["AppDetailsButton"], limit: 20000, needs: ["AppDetailsButton"] },
          search: { has: ["AdvancedSearchContainer"], limit: 20000, needs: ["AdvancedSearchContainer"] },
          row: { has: ["GameListEntryContainer"], limit: 20000, needs: ["GameListEntryContainer"] },
          tile: { has: ["LibraryItemBox"], limit: 20000, needs: ["LibraryItemBox"] },
          filters: { has: ["ViewFiltersBar"], limit: 20000, needs: ["ViewFiltersBar"] }
        };
        /* Where each class is written in a build of ES modules. */
        var RECIPES = \#(SteamSurface.classRecipesLiteral);
        var PLATFORMS = ["windows", "macos", "linux"];
        var RETRY_AFTER = 30000;
        var CHUNK_LIMIT = 12;
        var SIZE_LIMIT = 64000000;
    
        var state;
        try { state = ctx.__sevoSteamBuild || (ctx.__sevoSteamBuild = {}); } catch (e) { state = {}; }
    
        // MARK: The build
    
        /* The script a page of ES modules loads first. */
        function entryURL() {
          try {
            var scripts = ctx.document.scripts;
            for (var i = 0; i < scripts.length; i++) {
              if (scripts[i].type === "module" && scripts[i].src) return scripts[i].src;
            }
          } catch (e) {}
          return null;
        }
    
        function build() {
          if (state.build) return state.build;
          var chunks = ctx.webpackChunksteamui;
          if (chunks && typeof chunks.push === "function") state.build = "webpack";
          else if (entryURL()) state.build = "modules";
          return state.build || null;
        }
    
        // MARK: webpack
    
        var req = null;
    
        /* webpack's require, handed to a chunk that carries no modules. */
        function registry() {
          if (req) return req;
          var chunks = ctx.webpackChunksteamui;
          if (!chunks || typeof chunks.push !== "function") return null;
          var found = null;
          try { chunks.push([["sevo-surface-" + Date.now()], {}, function (r) { found = r; }]); } catch (e) { return null; }
          if (!found || !found.m) return null;
          req = found;
          return req;
        }
    
        /* The first module whose source carries the marker and whose exports
           `pick` accepts. Only modules Steam has already loaded carry these
           markers, so requiring them runs nothing. */
        function find(marker, pick) {
          var r = registry();
          if (!r) return null;
          for (var id in r.m) {
            if (String(r.m[id]).indexOf(marker) === -1) continue;
            try {
              var found = pick(r(id));
              if (found) return found;
            } catch (e) {}
          }
          return null;
        }
    
        var maps = {};
    
        /* The class maps of `groups`, each found by its semantic keys. Class
           modules are pure `e.exports = {…}` objects, so requiring one has
           no side effect; every other module is left alone. */
        function webpackMaps(groups) {
          var r = registry();
          if (!r) return null;
          for (var id in r.m) {
            var source = String(r.m[id]);
            for (var g = 0; g < groups.length; g++) {
              var name = groups[g], map = MAPS[name];
              if (maps[name] || source.length > map.limit) continue;
              if (!map.has.every(function (key) { return source.indexOf(key + ':"') !== -1; })) continue;
              try {
                var exports = r(id);
                if (exports && map.needs.every(function (key) { return exports[key]; })) maps[name] = exports;
              } catch (e) {}
            }
          }
          return maps;
        }
    
        // MARK: ES modules, read as text
    
        function isName(ch) { return ch !== "" && /[\w$]/.test(ch); }
    
        /* Where each top-level argument begins and ends, in the call whose
           ( is just before `start`. */
        function callArguments(text, start) {
          var depth = 0, quote = "", pieces = [], piece = start;
          var limit = Math.min(text.length, start + 6000);
          for (var i = start; i < limit; i++) {
            var ch = text.charAt(i);
            if (quote) {
              if (ch === "\\") i++;
              else if (ch === quote) quote = "";
            } else if (ch === '"' || ch === "'" || ch === "`") {
              quote = ch;
            } else if (ch === "(" || ch === "[" || ch === "{") {
              depth++;
            } else if (ch === ")" || ch === "]" || ch === "}") {
              if (depth === 0) { pieces.push([piece, i]); return pieces; }
              depth--;
            } else if (ch === "," && depth === 0) {
              pieces.push([piece, i]);
              piece = i + 1;
            }
          }
          return null;
        }
    
        /* Just past `name=` at the nearest assignment before `before`. */
        function definitionOf(text, name, before) {
          var needle = name + "=";
          var at = before >= needle.length ? text.lastIndexOf(needle, before - needle.length) : -1;
          while (at !== -1) {
            var previous = at > 0 ? text.charAt(at - 1) : " ";
            var next = text.charAt(at + needle.length);
            if (next !== "" && next !== "=" && !isName(previous) && previous !== ".") return at + needle.length;
            at = at >= needle.length ? text.lastIndexOf(needle, at - needle.length) : -1;
          }
          return -1;
        }
    
        /* The class the expression at `at` names: a literal, a constant read
           at its nearest definition before it, or one argument of a call
           that joins several (`shown&&X` names X). */
        function classAt(text, at, argument, depth) {
          if (depth >= 5 || at < 0 || at >= text.length) return null;
          var ch = text.charAt(at);
          if (ch === '"' || ch === "'" || ch === "`") {
            var close = text.indexOf(ch, at + 1);
            var literal = text.slice(at + 1, close === -1 ? text.length : close);
            return /^[\w$-]+$/.test(literal) ? literal : null;
          }
          var end = at;
          while (end < text.length && isName(text.charAt(end))) end++;
          if (end === at || end >= text.length) return null;
          if (text.charAt(end) === "(") {
            var pieces = callArguments(text, end + 1);
            if (!pieces || !pieces.length) return null;
            var index = argument >= 0 ? argument : pieces.length + argument;
            if (index < 0 || index >= pieces.length) return null;
            var from = pieces[index][0], to = pieces[index][1];
            while (from < to && text.charAt(from) === " ") from++;
            var shown = to - from >= 2 ? text.lastIndexOf("&&", to - 2) : -1;
            return classAt(text, shown >= from ? shown + 2 : from, 0, depth + 1);
          }
          var defined = definitionOf(text, text.slice(at, end), at);
          return defined === -1 ? null : classAt(text, defined, argument, depth + 1);
        }
    
        /* The class a recipe names in a chunk's text: the value of the
           `className:` so many places before or after the recipe's token. */
        function readClass(text, recipe) {
          var marker = "className:";
          for (var anchor = text.indexOf(recipe.anchor); anchor !== -1; anchor = text.indexOf(recipe.anchor, anchor + 1)) {
            if (recipe.beside) {
              var near = text.indexOf(recipe.beside, Math.max(0, anchor - recipe.reach));
              if (near === -1 || near + recipe.beside.length > anchor + recipe.anchor.length + recipe.reach) continue;
            }
            var cursor = anchor;
            for (var n = 0; n <= recipe.skip && cursor !== -1; n++) {
              if (recipe.after) cursor = text.indexOf(marker, cursor + 1);
              else cursor = cursor >= marker.length ? text.lastIndexOf(marker, cursor - marker.length) : -1;
            }
            return cursor === -1 ? null : classAt(text, cursor + marker.length, recipe.argument, 0);
          }
          return null;
        }
    
        /* The function that owns the code at `at`: the walk out to the block
           around it, then that block's head. */
        function enclosingName(source, at, floor) {
          for (var i = at, depth = 0; i >= (floor || 0); i--) {
            var ch = source.charAt(i);
            if (ch === "}") depth++;
            else if (ch === "{" && depth > 0) depth--;
            else if (ch === "{") {
              var head = source.slice(Math.max(0, i - 160), i);
              var hit = head.match(/function\s*([\w$]+)\s*\([^()]*\)\s*$/)
                || head.match(/([\w$]+)\s*=\s*(?:async\s*)?(?:function\s*[\w$]*\s*)?\([^()]*\)\s*(?:=>\s*)?$/)
                || head.match(/([\w$]+)\s*=\s*(?:async\s*)?[\w$]+\s*=>\s*$/);
              if (hit) return hit[1];
            }
          }
          return null;
        }
    
        function nearestFunction(source, at) {
          var start = source.lastIndexOf("function ", at);
          var hit = start === -1 ? null : source.slice(start, start + 64).match(/^function\s*([\w$]+)\s*\(/);
          return hit ? hit[1] : null;
        }
    
        /* Every function that may list Properties › Compatibility, by the
           page's label. Two readings of each owner, so a brace inside a
           string that misleads the walk still leaves the other; a name only
           counts when the stack shows it calling the Linux test. */
        function listersIn(source) {
          var names = [], label = "#AppProperties_CompatibilityPage";
          for (var at = source.indexOf(label); at !== -1; at = source.indexOf(label, at + 1)) {
            var open = source.charAt(at - 1);
            if (open !== source.charAt(at + label.length) || (open !== '"' && open !== "'" && open !== "`")) continue;
            [enclosingName(source, at - 1, Math.max(0, at - 400000)), nearestFunction(source, at - 1)].forEach(function (name) {
              if (name && names.indexOf(name) === -1) names.push(name);
            });
          }
          return names;
        }
    
        /* The chunks a module's text names, as addresses beside its own:
           those its import statements load before it runs, and those it
           loads on demand. */
        function chunkLinks(text, base) {
          var folder = base.split("?")[0];
          folder = folder.slice(0, folder.lastIndexOf("/") + 1);
          var imported = [], named = [];
          var pattern = /(["'`])\.\/([^"'`\s]+?\.js(?:\?[^"'`\s]*)?)\1/g, match;
          while ((match = pattern.exec(text))) {
            var url = folder + match[2];
            var before = text.slice(Math.max(0, match.index - 8), match.index).replace(/\s+$/, "");
            var list = /(?:from|import)$/.test(before) ? imported : named;
            if (list.indexOf(url) === -1) list.push(url);
          }
          var onDemand = named.filter(function (url) { return imported.indexOf(url) === -1; });
          return { imported: imported, onDemand: onDemand };
        }
    
        function fetchText(url) {
          return fetch(url, { cache: "force-cache" }).then(function (response) { return response.ok ? response.text() : null; });
        }
    
        function readInto(found, text) {
          found.size += text.length;
          RECIPES.forEach(function (recipe) {
            var id = recipe.group + "." + recipe.key;
            if (!found.classes[id]) found.classes[id] = readClass(text, recipe);
          });
          if (!found.listers.length) found.listers = listersIn(text);
        }
    
        function complete(found) {
          return found.listers.length > 0
            && RECIPES.every(function (recipe) { return found.classes[recipe.group + "." + recipe.key]; });
        }
    
        /* One chunk after another, until everything is read or the limits
           are reached: the library's code is in the first the entry names. */
        function readChunks(urls, index, found) {
          if (index >= urls.length || index >= CHUNK_LIMIT || found.size > SIZE_LIMIT || complete(found)) return found;
          return fetchText(urls[index]).then(function (text) {
            if (text !== null) readInto(found, text);
            return readChunks(urls, index + 1, found);
          });
        }
    
        /* The classes as maps like webpack's. A map that lacks a class the
           scripts draw with is left out whole. */
        function grouped(classes) {
          var groups = {};
          RECIPES.forEach(function (recipe) {
            if (groups[recipe.group] === undefined) groups[recipe.group] = {};
            var name = classes[recipe.group + "." + recipe.key];
            if (name && groups[recipe.group]) groups[recipe.group][recipe.key] = name;
            else if (!name && !recipe.optional) groups[recipe.group] = null;
          });
          return groups;
        }
    
        /* Reads the entry script and the chunks it loads on demand, once a
           page; a failure is tried again after a while. */
        function readText() {
          if (state.read || Date.now() - (state.readAt || 0) < RETRY_AFTER) return;
          var entry = entryURL();
          if (!entry) return;
          state.readAt = Date.now();
          var found = { classes: {}, listers: [], size: 0 };
          fetchText(entry).then(function (text) {
            if (text === null) throw new Error("the entry script did not load");
            var links = chunkLinks(text, entry);
            state.imports = links.imported;
            readInto(found, text);
            return readChunks(links.onDemand, 0, found);
          }).then(function () {
            state.classes = grouped(found.classes);
            state.listers = found.listers;
            state.read = true;
            loadModules();
          }).catch(function (error) {
            state.failure = String((error && error.message) || error);
          });
        }
    
        /* The modules the entry script imports, which ran before it did:
           importing one again by the same address answers with the module
           the page already has. Asked only in Steam's own page, whose
           module map holds them. */
        function loadModules() {
          if (state.modules || state.importing || !state.imports || ctx !== window) return;
          state.importing = true;
          var load = state.importModule || function (url) { return import(url); };
          Promise.all(state.imports.map(function (url) {
            return load(url).then(function (module) { return module; }, function () { return null; });
          })).then(function (modules) {
            state.modules = modules.filter(function (module) { return !!module; });
            state.importing = false;
          });
        }
    
        function firstIn(modules, pick) {
          for (var i = 0; modules && i < modules.length; i++) {
            try {
              var found = pick(modules[i]);
              if (found) return found;
            } catch (e) {}
          }
          return null;
        }
    
        // MARK: Elements, through React
    
        function fiberOf(element) {
          var keys = Object.keys(element);
          for (var i = 0; i < keys.length; i++) {
            if (keys[i].indexOf("__reactFiber$") === 0) return element[keys[i]];
          }
          return null;
        }
    
        /* The first element a component draws. */
        function firstElement(fiber) {
          for (var depth = 0; fiber && depth < 30; depth++, fiber = fiber.child) {
            if (fiber.stateNode && fiber.stateNode.nodeType === 1) return fiber.stateNode;
          }
          return null;
        }
    
        /* The game page's row of links (Store Page, Community Hub…): the
           element drawn by the component that takes the row's props, reached
           from any link in it. The strip goes after it. */
        function linksBarSlot(doc) {
          var links = doc.querySelectorAll('[role="link"]');
          for (var i = 0; i < links.length && i < 200; i++) {
            var fiber = fiberOf(links[i]);
            for (var depth = 0; fiber && depth < 40; depth++, fiber = fiber.return) {
              var props = fiber.memoizedProps;
              if (!props || typeof props !== "object" || !("workshopVisible" in props) || !("marketPresence" in props)) continue;
              var bar = firstElement(fiber);
              if (bar && bar.contains(links[i]) && bar.parentElement) return { after: bar };
              break;
            }
          }
          return null;
        }
    
        // MARK: The answers
    
        /* Whether Steam's modules can be asked: webpack's registry is up, or
           a build of ES modules has been read and its modules are in hand. */
        function ready() {
          var kind = build();
          if (kind === "webpack") return !!registry();
          if (kind !== "modules") return false;
          readText();
          if (state.read) loadModules();
          return !!(state.read && state.modules);
        }
    
        var settled = {};
    
        /* Steam's class names by their names in its source, one map for
           each group: `{ play: { PlayButton: "…" }, … }`. Null until every
           `required` group is found; an `optional` one found by then comes
           along. */
        function classes(required, optional) {
          var all = required.concat(optional || []);
          var id = all.join(" ");
          if (settled[id]) return settled[id];
          var kind = build(), found = null;
          if (kind === "webpack") {
            found = webpackMaps(all);
          } else if (kind === "modules") {
            readText();
            found = state.read ? state.classes : null;
          }
          if (!found) return null;
          var answer = {};
          for (var i = 0; i < all.length; i++) {
            if (found[all[i]]) answer[all[i]] = found[all[i]];
            else if (i < required.length) return null;
          }
          settled[id] = answer;
          return answer;
        }
    
        /* Where the compatibility strip goes in a game's page. Steam's own
           slot is inside the game-info block, which the desktop page keeps
           collapsed behind its (i) button, so the strip goes right under
           the page's row of links instead, the next sibling of that
           collapsed block; the block itself is the fallback. */
        function stripSlot(doc) {
          if (build() === "modules") return linksBarSlot(doc);
          var names = classes(["strip"]);
          var container = names && doc.querySelector("." + names.strip.Container);
          if (!container) return null;
          var block = container.parentElement;
          var tabBar = block && block.nextElementSibling;
          return tabBar ? { after: tabBar } : { inside: container };
        }
    
        function matcher(prototype) {
          return prototype && typeof prototype.MatchesImpl === "function" && typeof prototype.MatchesScoredImpl === "function"
            && Object.getOwnPropertyDescriptor(prototype, "bIsEmpty");
        }
    
        /* Steam's library filter class. On a build of ES modules it is the
           link of the library's own filter's prototype chain that defines
           the matchers. */
        function libraryFilter() {
          if (build() === "webpack") {
            return find("Found SteamDeckUnsupported set in AppFilter", function (exports) {
              for (var key in exports) {
                if (matcher(exports[key] && exports[key].prototype)) return exports[key];
              }
              return null;
            });
          }
          try {
            var prototype = Object.getPrototypeOf(ctx.uiStore.collectionsAppFilter);
            for (var depth = 0; prototype && depth < 8; depth++, prototype = Object.getPrototypeOf(prototype)) {
              if (matcher(prototype) && typeof prototype.constructor === "function") return prototype.constructor;
            }
          } catch (e) {}
          return null;
        }
    
        /* MobX's `observable`. */
        function observable() {
          function pick(exports) {
            for (var key in exports) {
              if (typeof exports[key] === "function" && typeof exports[key].box === "function") return exports[key];
            }
            return null;
          }
          return build() === "webpack" ? find("[MobX]", pick) : firstIn(state.modules, pick);
        }
    
        function eachExport(exports, visit) {
          if (!exports || typeof exports !== "object") return;
          Object.keys(exports).forEach(function (key) {
            var value;
            try { value = exports[key]; } catch (e) { return; }
            visit(value);
          });
        }
    
        /* Steam's Linux test and the config object it reads: the exported
           function true for `linux` and false for `windows` and `macos`,
           from the small modules that read the platform. */
        function platformTest() {
          var modules = [];
          if (build() === "webpack") {
            var r = registry();
            if (!r) return null;
            for (var id in r.m) {
              var source = String(r.m[id]);
              if (source.length < 20000 && source.indexOf("PLATFORM") !== -1) {
                try { modules.push(r(id)); } catch (e) {}
              }
            }
          } else {
            modules = state.modules || [];
          }
          var configs = [];
          modules.forEach(function (exports) {
            eachExport(exports, function (value) {
              if (value && typeof value === "object" && PLATFORMS.indexOf(value.PLATFORM) !== -1 && configs.indexOf(value) === -1) configs.push(value);
            });
          });
          for (var c = 0; c < configs.length; c++) {
            var config = configs[c], real = config.PLATFORM, found = null;
            var answers = function (test, platform) {
              config.PLATFORM = platform;
              try { return test() === true; } catch (e) { return null; } finally { config.PLATFORM = real; }
            };
            modules.forEach(function (exports) {
              eachExport(exports, function (value) {
                if (found || typeof value !== "function" || value.length !== 0 || !value.name) return;
                var source = String(value);
                if (source.length > 200 || source.indexOf("PLATFORM") === -1) return;
                if (answers(value, "linux") === true && answers(value, "windows") === false && answers(value, "macos") === false) found = value.name;
              });
            });
            if (found) return { config: config, name: found };
          }
          return null;
        }
    
        /* The names of the functions that may list Properties › Compatibility. */
        function pageListers() {
          if (build() !== "webpack") return state.listers || [];
          var r = registry(), names = [];
          if (!r) return names;
          for (var id in r.m) {
            listersIn(String(r.m[id])).forEach(function (name) {
              if (names.indexOf(name) === -1) names.push(name);
            });
          }
          return names;
        }
    
        return {
          build: build, ready: ready, classes: classes, stripSlot: stripSlot, libraryFilter: libraryFilter,
          observable: observable, platformTest: platformTest, pageListers: pageListers,
          read: { className: readClass, links: chunkLinks, listers: listersIn }
        };
      }
    
    """#
}
