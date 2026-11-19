/// The page loaded into the hidden WebView — a JavaScript runtime that
/// believes it is `https://www.youtube.com`.
///
/// Two jobs live in here, and both need a real browser engine rather than a
/// Dart interpreter:
///
///   1. **BotGuard attestation.** YouTube's proof-of-origin token comes from
///      running Google's BotGuard virtual machine, which inspects the
///      environment it runs in (DOM, timing, the lot) and signs a verdict.
///      The flow is the one `bgutils-js` and NewPipe use: fetch a challenge
///      from the `Waa/Create` endpoint, load the interpreter it names, run
///      the program, hand its answer to `Waa/GenerateIT` for an *integrity
///      token*, and use the minter the VM exposed to bind that token to a
///      session identifier. The result is the `pot` every stream URL needs.
///
///   2. **The player's own challenges.** The web client's stream URLs carry a
///      scrambled signature and an `n` parameter that the player JavaScript
///      transforms. yt-dlp's `ejs` solver does that given the player script;
///      it is a JavaScript library, so it runs here too.
///
/// The page is loaded with youtube.com as its base URL, which is what makes
/// the BotGuard endpoints answer (they check the origin) and makes fetching
/// the player script a same-origin request.
///
/// Dart talks to it through one dispatcher: `__aibitCall(id, name, args)`
/// runs `aibit[name](...args)` and posts `{id, ok, value | error}` back on
/// the `AiBit` channel. Every function is async; nothing returns through
/// `runJavaScriptReturningResult`, whose result encoding differs between the
/// two platforms.
library;

const runtimePageHtml = r'''<!doctype html>
<html><head><meta charset="utf-8"><title>AI BIT</title></head>
<body>
<script>
(function () {
  'use strict';

  function post(payload) {
    try { AiBit.postMessage(JSON.stringify(payload)); }
    catch (e) { /* channel not yet bound; nothing to do */ }
  }

  function describe(e) {
    if (!e) return 'unknown error';
    if (typeof e === 'string') return e;
    var text = e.message || String(e);
    if (e.stack && e.stack.indexOf(text) < 0) text += '\n' + e.stack;
    return text;
  }

  window.__aibitCall = function (id, name, args) {
    Promise.resolve()
      .then(function () {
        var fn = window.aibit[name];
        if (typeof fn !== 'function') throw new Error('no such function: ' + name);
        return fn.apply(null, args || []);
      })
      .then(function (value) { post({ id: id, ok: true, value: value === undefined ? null : value }); })
      .catch(function (e) { post({ id: id, ok: false, error: describe(e) }); });
  };

  // ------------------------------------------------------------ helpers

  function b64ToU8(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    var bin = atob(s);
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function u8ToB64Url(u8) {
    var bin = '';
    for (var i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_');
  }

  function loadScript(url) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = url;
      s.onload = function () { resolve(); };
      s.onerror = function () { reject(new Error('could not load ' + url)); };
      document.head.appendChild(s);
    });
  }

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  // ------------------------------------------------------------ BotGuard

  var WAA = 'https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/';
  var WAA_HEADERS = {
    'content-type': 'application/json+protobuf',
    'x-goog-api-key': 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw',
    'x-user-agent': 'grpc-web-javascript/0.1'
  };

  // The challenge arrives scrambled: base64 of bytes each 97 below the real
  // character. Decoding it is the whole of the "scrambling".
  function descramble(s) {
    var u8 = b64ToU8(s);
    return new TextDecoder().decode(u8.map(function (b) { return b + 97; }));
  }

  async function createChallenge(requestKey) {
    var res = await fetch(WAA + 'Create', {
      method: 'POST', headers: WAA_HEADERS, body: JSON.stringify([requestKey])
    });
    if (!res.ok) throw new Error('Waa/Create answered HTTP ' + res.status);
    var raw = await res.json();
    var data = [];
    if (raw.length > 1 && typeof raw[1] === 'string') {
      data = JSON.parse(descramble(raw[1]) || '[]');
    } else if (raw.length && typeof raw[0] === 'object') {
      data = raw[0];
    }
    var wrappedScript = data[1], wrappedUrl = data[2];
    var pick = function (v) {
      return Array.isArray(v) ? v.filter(function (x) { return x && typeof x === 'string'; })[0] : null;
    };
    return {
      messageId: data[0],
      script: pick(wrappedScript),
      scriptUrl: pick(wrappedUrl),
      interpreterHash: data[3],
      program: data[4],
      globalName: data[5]
    };
  }

  async function loadBotGuard(program, globalName) {
    var vm = window[globalName];
    if (!vm || typeof vm.a !== 'function') {
      throw new Error('BotGuard VM "' + globalName + '" is not present after loading the interpreter');
    }
    var fns = null;
    var onFunctions = function (asyncSnapshot, shutdown, passEvent, checkCamera) {
      fns = { asyncSnapshot: asyncSnapshot, shutdown: shutdown, passEvent: passEvent, checkCamera: checkCamera };
    };
    var started = vm.a(program, onFunctions, true, undefined, function () {}, [[], []]);
    if (Array.isArray(started)) await started[0]; else await started;
    for (var i = 0; i < 200 && !(fns && fns.asyncSnapshot); i++) await sleep(25);
    if (!(fns && fns.asyncSnapshot)) throw new Error('BotGuard VM never exposed its snapshot function');
    return {
      snapshot: function (args) {
        return new Promise(function (resolve, reject) {
          var timer = setTimeout(function () { reject(new Error('BotGuard snapshot timed out')); }, 15000);
          try {
            fns.asyncSnapshot(function (response) { clearTimeout(timer); resolve(response); },
              [args.contentBinding, args.signedTimestamp, args.webPoSignalOutput, args.skipPrivacyBuffer]);
          } catch (e) { clearTimeout(timer); reject(e); }
        });
      },
      shutdown: function () { try { if (fns.shutdown) fns.shutdown(); } catch (e) {} }
    };
  }

  // Mints a proof-of-origin token bound to `identifier` (the visitorData the
  // player request will carry). Returns the websafe-base64 token plus the
  // integrity token's lifetime, which is the longest the result is worth
  // caching.
  async function mintPoToken(requestKey, identifier) {
    var steps = [];
    var challenge = await createChallenge(requestKey);
    steps.push('challenge');
    if (challenge.script) {
      new Function(challenge.script)();
    } else if (challenge.scriptUrl) {
      var url = challenge.scriptUrl;
      if (url.indexOf('//') === 0) url = 'https:' + url;
      await loadScript(url);
    } else {
      throw new Error('challenge named no interpreter');
    }
    steps.push('interpreter');
    var bg = await loadBotGuard(challenge.program, challenge.globalName);
    steps.push('vm');
    var webPoSignalOutput = [];
    var botguardResponse = await bg.snapshot({ webPoSignalOutput: webPoSignalOutput });
    if (typeof botguardResponse !== 'string' || !botguardResponse) {
      throw new Error('BotGuard produced no response');
    }
    steps.push('snapshot');
    var res = await fetch(WAA + 'GenerateIT', {
      method: 'POST', headers: WAA_HEADERS, body: JSON.stringify([requestKey, botguardResponse])
    });
    if (!res.ok) throw new Error('Waa/GenerateIT answered HTTP ' + res.status);
    var generated = await res.json();
    var integrityToken = generated[0], ttl = generated[1], refresh = generated[2];
    if (typeof integrityToken !== 'string') {
      throw new Error('GenerateIT returned no integrity token: ' + JSON.stringify(generated).slice(0, 200));
    }
    steps.push('integrity');
    var getMinter = webPoSignalOutput[0];
    if (typeof getMinter !== 'function') throw new Error('PMD:Undefined — the VM exposed no minter');
    var mint = await getMinter(b64ToU8(integrityToken));
    if (typeof mint !== 'function') throw new Error('APF:Failed — the minter is not a function');
    var out = await mint(new TextEncoder().encode(identifier));
    if (!(out instanceof Uint8Array)) throw new Error('ODM:Invalid — minted value is not bytes');
    steps.push('mint');
    bg.shutdown();
    return { token: u8ToB64Url(out), ttlSeconds: typeof ttl === 'number' ? ttl : null,
             refreshSeconds: typeof refresh === 'number' ? refresh : null, steps: steps };
  }

  // ------------------------------------------------------------ player JS

  var playerScripts = {};      // url -> source text
  var preprocessed = {};       // url -> the solver's preprocessed player

  async function playerScript(url) {
    if (playerScripts[url]) return playerScripts[url];
    var res = await fetch(url);
    if (!res.ok) throw new Error('player script answered HTTP ' + res.status);
    var text = await res.text();
    playerScripts = {}; preprocessed = {};   // one build at a time
    playerScripts[url] = text;
    return text;
  }

  async function playerInfo(url) {
    var text = await playerScript(url);
    var m = /(?:signatureTimestamp|sts):(\d{5})/.exec(text);
    return { signatureTimestamp: m ? parseInt(m[1], 10) : null, bytes: text.length };
  }

  // requests: [{type: 'n' | 'sig', challenges: [...]}]
  async function solveChallenges(url, requests) {
    if (typeof window.jsc !== 'function') throw new Error('solver not loaded');
    var input;
    if (preprocessed[url]) {
      input = { type: 'preprocessed', preprocessed_player: preprocessed[url], requests: requests };
    } else {
      input = { type: 'player', player: await playerScript(url), requests: requests, output_preprocessed: true };
    }
    var result = await window.jsc(input);
    if (!result || result.type !== 'result') {
      throw new Error('solver answered ' + JSON.stringify(result).slice(0, 300));
    }
    if (result.preprocessed_player) preprocessed[url] = result.preprocessed_player;
    var solved = {};
    (result.responses || []).forEach(function (r) {
      if (r && r.type === 'result' && r.data) {
        Object.keys(r.data).forEach(function (k) { solved[k] = r.data[k]; });
      }
    });
    return solved;
  }

  window.aibit = {
    ping: async function () { return 'ok'; },
    mintPoToken: mintPoToken,
    playerInfo: playerInfo,
    solveChallenges: solveChallenges,
    hasSolver: async function () { return typeof window.jsc === 'function'; }
  };
})();
</script>
</body></html>
''';
