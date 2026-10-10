'use strict';
// net-guard.cjs — boundary TEST INSTRUMENTATION (not a product shim).
// Fail-closed: any outbound network attempt throws a distinctive
// NETWORK_FORBIDDEN error instead of touching the network.
// Loaded via NODE_OPTIONS=--require <this file> so it applies to the
// real application code without patching any application function.
// Vendored from the completed dsh-codex-oracle packet's proven guard
// (scratch/dsh-codex-oracle/guard/net-guard.cjs), with ONE documented
// deviation below: loopback resolution passthrough. Everything else is
// verbatim: fail-closed NETWORK_FORBIDDEN on any outbound attempt.
function forbidden(where) {
  const err = new Error(`NETWORK_FORBIDDEN:${where}`);
  err.code = 'NETWORK_FORBIDDEN';
  return err;
}

// --- DNS ---
try {
  const dns = require('node:dns');
  const names = ['lookup', 'resolve', 'resolve4', 'resolve6', 'resolveAny',
    'resolveCname', 'resolveMx', 'resolveNaptr', 'resolveNs', 'resolvePtr',
    'resolveSoa', 'resolveSrv', 'resolveTxt', 'reverse', 'lookupService'];
  for (const k of names) {
    if (typeof dns[k] === 'function') {
      const name = k;
      dns[k] = (...args) => {
        // Deviation from the oracle guard: loopback resolution is NOT
        // egress. dsh's own webserver boot path resolves 'localhost' via
        // lookupAndListen before bind; blocking it breaks even --port 0
        // localhost boots that never leave the machine. Only the literal
        // loopback names/IPs pass through; every other name stays
        // fail-closed, and Socket.connect/TLS/fetch stay blocked, so no
        // outbound connection is possible either way.
        if (name === 'lookup') {
          const host = args[0];
          const isLoopback = host === 'localhost' || host === '::1' || host === '::ffff:127.0.0.1'
            || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host || '');
          if (isLoopback) {
            // Synthesise hosts-file loopback answers (no recursion into
            // this same wrapper, no network).
            const last = args[args.length - 1];
            const family = typeof args[1] === 'number' ? args[1] : (args[1] && args[1].family) || 0;
            const addr = host === '::1' ? '::1' : '127.0.0.1';
            const fam = family === 6 ? 6 : 4;
            if (typeof last === 'function') {
              queueMicrotask(() => last(null, addr, fam));
              return {};
            }
            return { address: addr, family: fam };
          }
        }
        const last = args[args.length - 1];
        const err = forbidden(`dns.${name}`);
        if (typeof last === 'function') {
          queueMicrotask(() => last(err));
          return {};
        }
        throw err;
      };
    }
  }
} catch { /* ignore */ }
try {
  const dp = require('node:dns/promises');
  for (const k of Object.keys(dp)) {
    if (typeof dp[k] === 'function') {
      const name = k;
      dp[k] = async () => { throw forbidden(`dns/promises.${name}`); };
    }
  }
} catch { /* ignore */ }

// --- TCP sockets (catches undici and all raw socket users) ---
try {
  const net = require('node:net');
  const OrigSocket = net.Socket;
  if (OrigSocket && OrigSocket.prototype && typeof OrigSocket.prototype.connect === 'function') {
    OrigSocket.prototype.connect = function () { throw forbidden('net.Socket.connect'); };
  }
  net.connect = (...args) => { throw forbidden('net.connect'); };
  net.createConnection = (...args) => { throw forbidden('net.createConnection'); };
} catch { /* ignore */ }

// --- TLS ---
try {
  const tls = require('node:tls');
  tls.connect = (...args) => { throw forbidden('tls.connect'); };
  if (typeof tls.createSecureContext === 'function') {
    // createSecureContext is local crypto, allowed; leave intact.
  }
} catch { /* ignore */ }

// --- HTTP/HTTPS ---
try {
  const http = require('node:http');
  http.request = (...args) => { throw forbidden('http.request'); };
  http.get = (...args) => { throw forbidden('http.get'); };
} catch { /* ignore */ }
try {
  const https = require('node:https');
  https.request = (...args) => { throw forbidden('https.request'); };
  https.get = (...args) => { throw forbidden('https.get'); };
} catch { /* ignore */ }

// --- fetch / WebSocket / navigator-adjacent globals ---
globalThis.fetch = (...args) => { throw forbidden('global.fetch'); };
if (typeof globalThis.WebSocket !== 'undefined') {
  globalThis.WebSocket = class extends (globalThis.WebSocket || Object) {
    constructor() { throw forbidden('WebSocket'); }
  };
}
