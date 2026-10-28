import { default as makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, Browsers } from '@whiskeysockets/baileys';
import qrcodeTerminal from 'qrcode-terminal';
import QRCode from 'qrcode';
import pino from 'pino';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { spawn, spawnSync } from 'child_process';
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import { sameUrl, trycloudflareUrls } from './tunnel-links.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const toolRoot = path.resolve(__dirname, '..');
const require = createRequire(import.meta.url);

function fail(msg, code = 1) {
  console.error(msg);
  process.exit(code);
}

function assertDeps() {
  try {
    require.resolve('@whiskeysockets/baileys');
  } catch {
    fail(
      'WhatsApp bağımlılıkları eksik / WhatsApp dependencies missing.\n' +
        `  cd "${toolRoot}"\n` +
        '  npm install\n' +
        'Sonra tüneli yeniden başlatın / Then restart the tunnel:\n' +
        '  node scripts/send-whatsapp.js <url>'
    );
  }
}

assertDeps();

const configPath = path.join(__dirname, 'whatsapp-config.json');
if (!fs.existsSync(configPath)) {
  fail('whatsapp-config.json bulunamadı: ' + configPath);
}

const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const waProduct =
  String(process.env.DT_WA_PRODUCT || '').trim().toLowerCase() === 'duendee' ? 'duendee' : 'fm';
const productLabel = waProduct === 'duendee' ? 'Duendee' : 'DuendeeFM';
const urlFile =
  String(process.env.DT_WA_URL_FILE || '').trim() ||
  path.join(
    toolRoot,
    waProduct === 'duendee' ? '.tunnelstate-duendee' : '.tunnelstate',
    'tunnel.url'
  );
const action =
  String(process.env.DT_WA_ACTION || '').trim().toLowerCase() === 'retract' || process.argv.includes('--retract')
    ? 'retract'
    : 'send';

function resolveUrl(raw) {
  let fromFile = '';
  const arg = String(raw || '').trim();
  if (arg && /^https?:\/\//i.test(arg)) {
    return arg.replace(/[\r\n\s]+/g, '').replace(/\/+$/, '');
  }
  const filePath = arg && fs.existsSync(arg) ? arg : urlFile;
  if (fs.existsSync(filePath)) {
    fromFile = fs.readFileSync(filePath, 'utf8').trim();
  }
  const value = fromFile || arg;
  return String(value || '').replace(/[\r\n\s]+/g, '').replace(/\/+$/, '');
}

function defaultMessageTemplate() {
  if (waProduct === 'duendee') {
    return config.messageTemplateDuendee || 'Duendee tüneli (main)\n{url}';
  }
  return config.messageTemplate || config.messageTemplateFm || 'DuendeeFM tüneli\n{url}';
}

function rowMatchesProduct(row) {
  const p = String(row?.product || '').trim().toLowerCase();
  if (!p) {
    // Legacy untagged rows belong to DuendeeFM only.
    return waProduct === 'fm';
  }
  return p === waProduct;
}

const url = action === 'retract' ? '' : resolveUrl(process.argv[2] || process.env.DT_WA_URL || '');
const apkPath = String(process.env.DT_WA_APK || '').trim();
const apkOnly = Boolean(apkPath) && process.env.DT_WA_APK_ONLY === '1';

// Everyone the tunnel link was shared with can be listed, so a rebuilt tunnel
// reaches all of them instead of only one number.
// Accepts a single number, a comma/semicolon separated list, or an array.
function normalizeRecipients(value) {
  const raw = Array.isArray(value) ? value.join(',') : String(value || '');
  const seen = new Set();
  const out = [];
  for (const item of raw.split(/[,;]+/)) {
    const entry = item.trim();
    const digits = toDigits(entry);
    if (!entry || !digits) continue;
    if (seen.has(digits)) continue;
    seen.add(digits);
    out.push(entry);
  }
  return out;
}

const phoneArg = String(process.argv[3] || process.env.DT_WA_PHONE || '').trim();
const configRecipients = normalizeRecipients([
  ...(Array.isArray(config.targetPhones) ? config.targetPhones : []),
  config.targetPhone
]);
const recipients = normalizeRecipients(phoneArg).length
  ? normalizeRecipients(phoneArg)
  : configRecipients;
const phone = recipients[0] || '';

if (action === 'send' && apkPath) {
  if (!fs.existsSync(apkPath) || !/\.apk$/i.test(apkPath)) {
    fail('DT_WA_APK gecersiz veya .apk degil: ' + apkPath);
  }
}
if (action === 'send' && !apkOnly && (!url || !/^https:\/\//i.test(url))) {
  fail(
    'Kullanim / Usage: node send-whatsapp.js <tunnel-url|tunnel.url-file> [phone[,phone...]]\n' +
      'URL yok veya gecersiz / missing or invalid URL.\n' +
      'APK icin: DT_WA_APK=/path/app.apk (opsiyonel DT_WA_APK_ONLY=1)'
  );
}
if (action === 'send' && apkOnly && !apkPath) {
  fail('DT_WA_APK_ONLY=1 icin DT_WA_APK gerekli.');
}

if (action === 'send' && !recipients.length) {
  fail(
    'Hedef telefon yok / No target phone.\n' +
      'scripts/whatsapp-config.json icinde targetPhone (veya targetPhones) ayarlayin ya da arguman verin.\n' +
      'Ornek: node send-whatsapp.js "' + url + '" "+905xxxxxxxxx"'
  );
}

function stableSessionDir() {
  if (process.env.DT_WA_SESSION) return process.env.DT_WA_SESSION;
  if (process.platform === 'win32') {
    const base = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    return path.join(base, 'DuendeeWhatsApp');
  }
  const base = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
  return path.join(base, 'duendee-whatsapp');
}

function migrateLegacySession(target) {
  const legacy = path.join(toolRoot, '.whatsapp-session');
  if (fs.existsSync(path.join(target, 'creds.json'))) return;
  if (!fs.existsSync(path.join(legacy, 'creds.json'))) return;
  fs.mkdirSync(target, { recursive: true });
  for (const name of fs.readdirSync(legacy)) {
    const from = path.join(legacy, name);
    const to = path.join(target, name);
    if (!fs.existsSync(to)) fs.cpSync(from, to, { recursive: true });
  }
}

const sessionDir = stableSessionDir();
migrateLegacySession(sessionDir);
const sentPath = path.join(sessionDir, 'sent-links.json');
const keepExisting = process.env.DT_WA_KEEP_EXISTING === '1';
const qrImage = path.join(os.tmpdir(), 'duendee-whatsapp-qr.png');
const credsPath = path.join(sessionDir, 'creds.json');
const hasSession = fs.existsSync(credsPath);

const CONNECT_TIMEOUT_MS = Number(process.env.DT_WA_TIMEOUT_MS) || (action === 'retract' ? 90000 : 180000);
const MAX_RECONNECT = 4;
const READY_FALLBACK_MS = 5000;
const SEND_DELAY_MS = 800;

function loadSent() {
  try {
    const rows = JSON.parse(fs.readFileSync(sentPath, 'utf8'));
    return Array.isArray(rows) ? rows.filter((row) => row && row.id && row.jid) : [];
  } catch {
    return [];
  }
}

function saveSent(rows) {
  fs.mkdirSync(sessionDir, { recursive: true });
  fs.writeFileSync(sentPath, JSON.stringify(rows, null, 2));
}

function showQr(qr) {
  qrSeen = true;
  console.log('');
  console.log('  ============================================================');
  console.log('  ' + phone + ' hattina bagli degil — yeni QR');
  console.log('  Bagli cihazlarda Duendee Tunnel Tool olarak gorunur.');
  console.log('  WhatsApp > Bagli Cihazlar > Cihaz Bagla');
  console.log('  ============================================================');
  console.log('');
  try {
    qrcodeTerminal.generate(qr, { small: true });
  } catch (err) {
    console.log('  Terminal QR yazilamadi: ' + (err?.message || err));
  }
  QRCode.toFile(qrImage, qr, { width: 400, margin: 2 })
    .then(() => {
      console.log('');
      console.log('  QR resmi acildi / QR image opened: ' + qrImage);
      console.log('  Tarama sonrasi mesaj otomatik gidecek / Message sends after scan.');
      try {
        if (process.platform === 'win32') {
          spawn('explorer.exe', [qrImage], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
        } else if (process.platform === 'darwin') {
          spawn('open', [qrImage], { detached: true, stdio: 'ignore' }).unref();
        } else {
          spawn('xdg-open', [qrImage], { detached: true, stdio: 'ignore' }).unref();
        }
      } catch {
        /* ignore open failures */
      }
    })
    .catch(() => {});
}

function toDigits(raw) {
  return String(raw || '').replace(/[^0-9]/g, '');
}

function userDigits(raw) {
  const user = String(raw || '').trim().split('@')[0].split(':')[0];
  return user.replace(/[^0-9]/g, '');
}

function phonesMatch(accountId, target) {
  const account = userDigits(accountId);
  const expected = userDigits(target);
  if (!account || !expected) return false;
  return account === expected || account.endsWith(expected) || expected.endsWith(account);
}

function isPhoneAccount(accountId) {
  return String(accountId || '').includes('@s.whatsapp.net');
}

function readLinkedId() {
  try {
    const creds = JSON.parse(fs.readFileSync(credsPath, 'utf8'));
    return String(creds?.me?.id || '');
  } catch {
    return '';
  }
}

function lidFromCache(rawPhone) {
  const digits = toDigits(rawPhone);
  if (!digits) return '';
  const mapFile = path.join(sessionDir, 'lid-mapping-' + digits + '.json');
  if (!fs.existsSync(mapFile)) return '';
  try {
    const raw = JSON.parse(fs.readFileSync(mapFile, 'utf8'));
    const lid = String(raw || '').replace(/[^0-9]/g, '');
    return lid ? lid + '@lid' : '';
  } catch {
    return '';
  }
}

async function resolveSendJid(sock, rawPhone) {
  const digits = toDigits(rawPhone);
  if (!digits) {
    throw new Error('Telefon numarasi gecersiz: ' + rawPhone);
  }
  const pn = digits + '@s.whatsapp.net';
  for (let attempt = 0; attempt < 6; attempt++) {
    try {
      const lid = await sock.signalRepository.lidMapping.getLIDForPN(pn);
      if (lid) return lid;
    } catch {
      /* mapping lookup is optional */
    }
    const cached = lidFromCache(rawPhone);
    if (cached) return cached;
    if (attempt < 5) await new Promise((resolve) => setTimeout(resolve, 1500));
  }
  try {
    const results = await sock.onWhatsApp(pn);
    const hit = Array.isArray(results) ? results.find((row) => row && (row.exists || row.jid)) : null;
    if (hit?.lid) return hit.lid;
    if (hit?.jid) return hit.jid;
  } catch {
    /* fall through */
  }
  return pn;
}

function waitForServerAck(sock, id, ms) {
  return new Promise((resolve) => {
    let settled = false;
    const finishAck = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      sock.ev.off('messages.update', onUpdate);
      resolve(ok);
    };
    const onUpdate = (updates) => {
      for (const update of updates || []) {
        const status = update?.update?.status;
        const statusNo = Number(status);
        const acked = statusNo >= 2 || status === 'SERVER_ACK' || status === 'DELIVERY_ACK' || status === 'READ' || status === 'PLAYED';
        if (update?.key?.id === id && acked) finishAck(true);
      }
    };
    sock.ev.on('messages.update', onUpdate);
    const timer = setTimeout(() => finishAck(false), ms);
  });
}

async function waitUntilUsable(sock) {
  const start = Date.now();
  while (Date.now() - start < 8000) {
    if (sock?.user?.id) return;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
}

async function revokeTargets(sock) {
  const pn = toDigits(phone) ? toDigits(phone) + '@s.whatsapp.net' : '';
  let lid = '';
  if (pn) {
    try {
      lid = await sock.signalRepository.lidMapping.getLIDForPN(pn);
    } catch {
      lid = '';
    }
    if (!lid) lid = lidFromCache(phone);
    if (!lid) {
      try {
        const results = await sock.onWhatsApp(pn);
        const hit = Array.isArray(results) ? results.find((row) => row && (row.lid || row.jid)) : null;
        if (hit?.lid) lid = hit.lid;
      } catch {
        /* optional */
      }
    }
  }
  return { pn, lid };
}

function revokeConfirmed(sock, messageId, waitMs) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      sock.ev.off('messages.update', onUpdate);
      sock.ev.off('messages.delete', onDelete);
      resolve(ok);
    };
    const matches = (key) => key?.id === messageId;
    const onUpdate = (updates) => {
      for (const update of updates || []) {
        const stub = Number(update?.update?.messageStubType);
        if (matches(update?.key) && stub === 1) finish(true);
      }
    };
    const onDelete = (item) => {
      const keys = item?.keys || item || [];
      if ([].concat(keys).some(matches)) finish(true);
    };
    sock.ev.on('messages.update', onUpdate);
    sock.ev.on('messages.delete', onDelete);
    const timer = setTimeout(() => finish(false), waitMs);
  });
}

async function revokeMessage(sock, row, targets) {
  const jids = [...new Set([targets.lid, row.key?.remoteJid, row.jid, targets.pn].filter(Boolean))];
  let lastError = '';
  for (const jid of jids) {
    const pending = revokeConfirmed(sock, row.id, 5000);
    try {
      await sock.sendMessage(jid, {
        delete: { remoteJid: jid, fromMe: true, id: row.id }
      });
    } catch (err) {
      lastError = err?.message || String(err);
      await pending;
      continue;
    }
    if (await pending) return true;
  }
  if (typeof sock.chatModify === 'function') {
    for (const jid of jids) {
      try {
        await sock.chatModify({
          deleteForMe: {
            deleteMedia: false,
            key: { remoteJid: jid, fromMe: true, id: row.id },
            timestamp: Math.floor((row.stamp || Date.now()) / 1000)
          }
        }, jid);
        return true;
      } catch (err) {
        lastError = err?.message || String(err);
      }
    }
  }
  if (lastError) console.error('  Mesaj kaldirilamadi (' + (row.jid || '') + '): ' + lastError);
  return false;
}

async function deleteStored(sock, keepUrl) {
  const rows = loadSent();
  const keep = [];
  const targets = await revokeTargets(sock);
  for (const row of rows) {
    // Never delete the other product's tunnel/APK messages.
    if (!rowMatchesProduct(row)) {
      keep.push(row);
      continue;
    }
    if (keepUrl && sameUrl(row.url, keepUrl)) {
      keep.push(row);
      continue;
    }
    if (await revokeMessage(sock, row, targets)) {
      console.log('  Eski ' + productLabel + ' link mesaji kaldirildi: ' + (row.url || row.id));
    } else {
      keep.push(row);
    }
  }
  saveSent(keep);
  return keep;
}

function messageText(msg) {
  const chunks = [];
  const seen = new WeakSet();
  const walk = (node, depth) => {
    if (!node || depth > 8) return;
    if (typeof node === 'string') {
      if (node.includes('trycloudflare.com')) chunks.push(node);
      return;
    }
    if (typeof node !== 'object' || Buffer.isBuffer(node) || seen.has(node)) return;
    seen.add(node);
    if (Array.isArray(node)) {
      for (const item of node) walk(item, depth + 1);
      return;
    }
    for (const value of Object.values(node)) walk(value, depth + 1);
  };
  walk(msg?.message || {}, 0);
  return chunks.join('\n');
}

function messageStampMs(msg) {
  const raw = msg?.messageTimestamp;
  const n = typeof raw === 'object' && raw && typeof raw.toNumber === 'function' ? raw.toNumber() : Number(raw || 0);
  if (!Number.isFinite(n) || n <= 0) return 0;
  return n > 1e12 ? n : n * 1000;
}

function activeTunnelUrl() {
  if (fs.existsSync(urlFile)) {
    const fromProductFile = String(fs.readFileSync(urlFile, 'utf8') || '')
      .trim()
      .replace(/\/+$/, '');
    if (/^https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com$/i.test(fromProductFile)) {
      return fromProductFile;
    }
  }
  if (waProduct === 'duendee') return '';
  const script = path.join(toolRoot, 'scripts', 'fleet.js');
  if (!fs.existsSync(script)) return '';
  const out = spawnSync(process.execPath, [script, 'lookup', '--root', toolRoot], { encoding: 'utf8' });
  if (out.status !== 0) return '';
  const url = String(out.stdout || '').trim().replace(/\/+$/, '');
  return /^https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com$/i.test(url) ? url : '';
}

async function scanTunnelMessages(sock) {
  const found = new Map();
  const absorb = (msg) => {
    const id = msg?.key?.id;
    const jid = msg?.key?.remoteJid;
    if (!id || !jid || msg.key.fromMe === false) return;
    const text = messageText(msg);
    let urls = trycloudflareUrls(text);
    if (text.includes('Tünel zaman aşımına uğradı') && urls.length === 0) urls = ['notice'];
    const stamp = messageStampMs(msg);
    for (const url of urls) {
      const key = id + '\n' + jid;
      const prev = found.get(key);
      found.set(key, {
        id,
        jid,
        url,
        stamp: stamp || prev?.stamp || 0,
        key: msg.key || prev?.key
      });
    }
  };
  const drain = () => {
    while (historyMessages.length) absorb(historyMessages.shift());
  };
  for (const row of loadSent()) {
    for (const url of trycloudflareUrls(row.url)) {
      if (row.id && row.jid) {
        found.set(row.id + '\n' + row.jid, {
          id: row.id,
          jid: row.jid,
          url,
          stamp: Date.parse(row.at || '') || 0
        });
      }
    }
  }
  drain();
  await new Promise((resolve) => setTimeout(resolve, 6000));
  drain();
  const used = new Set();
  for (let page = 0; page < 20 && typeof sock.fetchMessageHistory === 'function'; page += 1) {
    const dated = [...found.values()].filter((row) => row.stamp > 0).sort((a, b) => a.stamp - b.stamp);
    const anchor = dated[0] || [...found.values()][0];
    if (!anchor) break;
    const mark = anchor.id + '\n' + anchor.jid + '\n' + anchor.stamp;
    if (used.has(mark)) break;
    used.add(mark);
    const before = found.size;
    const stampSec = anchor.stamp > 1e12 ? Math.floor(anchor.stamp / 1000) : Math.floor((anchor.stamp || Date.now()) / 1000);
    try {
      await sock.fetchMessageHistory(50, { remoteJid: anchor.jid, fromMe: true, id: anchor.id }, stampSec);
    } catch (err) {
      console.log('  Sohbet gecmisi alinamadi: ' + (err?.message || err));
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
    drain();
    if (found.size === before) break;
  }
  return [...found.values()];
}

async function purgeInactiveTunnelLinks(sock) {
  const keepUrl = activeTunnelUrl();
  const fromChat = await scanTunnelMessages(sock);
  const byId = new Map();
  for (const row of fromChat) {
    if (row?.id) byId.set(row.id + '\n' + (row.jid || ''), row);
  }
  // Include locally tracked APK / link sends for this product only.
  for (const row of loadSent()) {
    if (!rowMatchesProduct(row)) continue;
    const key = (row.id || '') + '\n' + (row.jid || '');
    if (!row.id) continue;
    if (!byId.has(key)) byId.set(key, row);
  }
  const drop = [...byId.values()].filter((row) => {
    if (!rowMatchesProduct(row)) return false;
    const u = String(row.url || '');
    if (!u) return !keepUrl;
    if (u.startsWith('apk:')) return !keepUrl;
    return !sameUrl(u, keepUrl);
  });
  const targets = await revokeTargets(sock);
  const removedIds = new Set();
  for (const row of drop) {
    if (await revokeMessage(sock, row, targets)) removedIds.add(row.id);
  }
  saveSent(loadSent().filter((row) => !removedIds.has(row.id)));
  const removed = removedIds.size;
  if (keepUrl) console.log('  Aktif tunel linki birakildi.');
  console.log('  Pasif tunel / APK mesajlari kaldirildi: ' + removed);
  return { removed, failed: drop.length - removed, kept: keepUrl ? 1 : 0 };
}

function rememberSent(id, jid, messageUrl, kind = 'link') {
  const rows = loadSent().filter((row) => row.id !== id);
  rows.push({
    id,
    jid,
    url: messageUrl,
    kind,
    product: waProduct,
    at: new Date().toISOString()
  });
  saveSent(rows);
}

async function sendText(sock, jid, message) {
  const sentMsg = await sock.sendMessage(jid, { text: message });
  const id = sentMsg?.key?.id;
  if (!id) {
    throw new Error('Mesaj anahtari donmedi');
  }
  const remoteJid = sentMsg.key?.remoteJid || jid;
  rememberSent(id, remoteJid, url);
  const rows = loadSent();
  const saved = rows.find((row) => row.id === id);
  if (saved && sentMsg.key) {
    saved.key = {
      remoteJid: sentMsg.key.remoteJid,
      fromMe: true,
      id: sentMsg.key.id
    };
    saveSent(rows);
  }
  const acked = await waitForServerAck(sock, id, 12000);
  return { sentMsg, id, jid: remoteJid, acked };
}

async function sendApkDocument(sock, jid, filePath, caption) {
  const buf = fs.readFileSync(filePath);
  const sentMsg = await sock.sendMessage(jid, {
    document: buf,
    mimetype: 'application/vnd.android.package-archive',
    fileName: /duendeefm\.apk$/i.test(path.basename(filePath))
      ? path.basename(filePath)
      : 'DuendeeFM.apk',
    caption: caption || undefined
  });
  const id = sentMsg?.key?.id;
  if (!id) {
    throw new Error('APK mesaj anahtari donmedi');
  }
  const remoteJid = sentMsg.key?.remoteJid || jid;
  // Store the live tunnel URL so cancel/retract can delete the APK message too.
  rememberSent(id, remoteJid, url || 'apk:' + path.basename(filePath), 'apk');
  const acked = await waitForServerAck(sock, id, 60000);
  return { sentMsg, id, jid: remoteJid, acked };
}

async function deliver(sock) {
  await waitUntilUsable(sock);
  const linked = sock.user?.id || readLinkedId();
  if (!keepExisting && !phonesMatch(linked, phone)) {
    const error = new Error('WRONG_LINE');
    error.linked = linked;
    throw error;
  }
  try {
    await sock.sendPresenceUpdate('available');
  } catch {
    /* presence is optional */
  }
  if (
    !apkOnly &&
    process.env.DT_WA_KEEP_EXISTING === '1' &&
    loadSent().some((row) => rowMatchesProduct(row) && sameUrl(row.url, url))
  ) {
    console.log('  Bu ' + productLabel + ' linki zaten WhatsApp mesajinda.');
    delivered = true;
    finish(0, 'Mevcut link mesaji duruyor.');
    return;
  }
  if (!apkOnly && url) {
    await deleteStored(sock, url);
  }
  const message = String(process.env.DT_WA_TEMPLATE || defaultMessageTemplate()).replace(
    '{url}',
    url || ''
  );
  const apkCaption =
    process.env.DT_WA_APK_CAPTION ||
    (url
      ? productLabel + ' Android APK\nTünel: ' + url
      : productLabel + ' Android APK');
  const deliveredRows = [];
  console.log('  Ürün: ' + productLabel);
  for (const target of recipients) {
    let acked = false;
    try {
      const lid = await resolveSendJid(sock, target);
      const pn = toDigits(target) + '@s.whatsapp.net';
      const targets = [...new Set([lid, pn].filter(Boolean))];
      let last = null;
      for (const jid of targets) {
        if (!apkOnly && url) {
          console.log('  ' + productLabel + ' linki gonderiliyor -> ' + target + ' (' + jid + ')');
          last = await sendText(sock, jid, message);
          if (!last.acked) {
            console.log('  Sunucu onayi gelmedi, diger adres deneniyor...');
            continue;
          }
        }
        if (apkPath) {
          console.log('  APK gonderiliyor -> ' + target + ' (' + path.basename(apkPath) + ')');
          last = await sendApkDocument(sock, jid, apkPath, apkCaption);
          if (!last.acked) {
            console.log('  APK sunucu onayi gelmedi, diger adres deneniyor...');
            continue;
          }
        }
        if (last?.acked) break;
      }
      acked = !!last?.acked;
    } catch (err) {
      console.error('  Gonderilemedi (' + target + '): ' + (err?.message || err));
    }
    deliveredRows.push({ phone: target, acked });
  }
  const okPhones = deliveredRows.filter((row) => row.acked).map((row) => row.phone);
  const failedPhones = deliveredRows.filter((row) => !row.acked).map((row) => row.phone);
  if (!okPhones.length) {
    throw new Error('WhatsApp sunucusu mesaji onaylamadi');
  }
  const what = apkPath ? (apkOnly ? path.basename(apkPath) : url + ' + ' + path.basename(apkPath)) : url;
  console.log('WhatsApp mesaji gonderildi -> ' + okPhones.join(', ') + ' | ' + what);
  if (failedPhones.length) {
    console.error('  Gonderilemeyen alici(lar): ' + failedPhones.join(', '));
  }
}

let qrSeen = false;
process.on('uncaughtException', (err) => {
  console.error('WhatsApp hatasi: ' + (err?.message || err));
  if (!qrSeen) process.exit(1);
});
process.on('unhandledRejection', (err) => {
  console.error('WhatsApp hatasi: ' + (err?.message || err));
  if (!qrSeen) process.exit(1);
});

const historyMessages = [];

function rememberHistory(msg) {
  if (msg) historyMessages.push(msg);
}

const retractLock = path.join(toolRoot, '.tunnelstate', 'wa-retract.lock');

async function claimRetractLock() {
  fs.mkdirSync(path.dirname(retractLock), { recursive: true });
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    try {
      const fd = fs.openSync(retractLock, 'wx');
      fs.writeFileSync(fd, String(process.pid));
      fs.closeSync(fd);
      return true;
    } catch (err) {
      if (err.code !== 'EEXIST') throw err;
      try {
        const age = Date.now() - fs.statSync(retractLock).mtimeMs;
        if (age > 90000) {
          fs.rmSync(retractLock, { force: true });
          continue;
        }
      } catch {
        /* lock disappeared; try again */
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  return false;
}

function releaseRetractLock() {
  try {
    fs.rmSync(retractLock, { force: true });
  } catch {
    /* ignore */
  }
}

async function main() {
  if (action === 'retract' && !(await claimRetractLock())) {
    fail('Link mesaji kaldirma zaman asimi.');
  }

  const linkedNow = readLinkedId();
  const keepLinked = action === 'send' && keepExisting && hasSession && Boolean(linkedNow);
  if (keepLinked && loadSent().some((row) => rowMatchesProduct(row) && sameUrl(row.url, url))) {
    console.log('  Bu ' + productLabel + ' linki zaten WhatsApp mesajinda.');
    return;
  }
  if (!keepLinked && action === 'send' && linkedNow && isPhoneAccount(linkedNow) && !phonesMatch(linkedNow, phone)) {
    console.log('  Kayitli WhatsApp hatti ' + phone + ' degil. Yeni QR olusturuluyor...');
    try {
      fs.rmSync(sessionDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }

  if (action === 'retract' && !hasSession) {
    releaseRetractLock();
    fail('WhatsApp oturumu yok; eski link mesaji kaldirilamadi.');
  }

  fs.mkdirSync(sessionDir, { recursive: true });

  if (fs.existsSync(credsPath)) {
    console.log('  WhatsApp hatti kontrol ediliyor: ' + phone);
  } else {
    console.log('  Kayitli WhatsApp oturumu yok. Baglanti deneniyor...');
  }

  let finished = false;
  let delivered = false;
  let delivering = false;
  let attempts = 0;
  let qrCycles = 0;
  let generation = 0;
  let allowQr = !keepLinked && !fs.existsSync(credsPath);
  let sock = null;
  let timer = null;

  const replaceWithQr = (reason) => {
    if (finished) return;
    if (keepLinked) {
      finish(0, 'Kayitli WhatsApp baglantisi duruyor. Yeni QR istenmedi.');
      return;
    }
    if (qrCycles >= 2) {
      finish(1, reason);
      return;
    }
    qrCycles += 1;
    allowQr = true;
    delivered = false;
    delivering = false;
    attempts = 0;
    generation += 1;
    console.log('  ' + reason);
    console.log('  WhatsApp hatti ' + phone + ' bagli degil. Yeni QR olusturuluyor...');
    try {
      if (sock) sock.end(undefined);
    } catch {
      /* ignore */
    }
    try {
      fs.rmSync(sessionDir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
    fs.mkdirSync(sessionDir, { recursive: true });
    setTimeout(() => {
      connect().catch((err) => finish(1, 'WhatsApp baslatilamadi: ' + (err?.message || err)));
    }, 400);
  };

  const finish = (code, msg) => {
    if (finished) return;
    finished = true;
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    if (msg) {
      if (code === 0) console.log(msg);
      else console.error(msg);
    }
    try {
      if (sock) sock.end(undefined);
    } catch {
      /* ignore */
    }
    if (action === 'retract') releaseRetractLock();
    setTimeout(() => process.exit(code), 1500);
  };

  timer = setTimeout(() => {
    if (keepLinked) {
      finish(0, 'Kayitli WhatsApp baglantisi duruyor. Yeni QR istenmedi.');
      return;
    }
    finish(
      1,
      'WhatsApp zaman asimi / timed out (' +
        Math.round(CONNECT_TIMEOUT_MS / 1000) +
        's).\n' +
        'QR tarandi mi? Oturumu sifirlamak icin:\n' +
        '  rmdir /s /q "' +
        sessionDir +
        '"   (Windows)\n' +
        '  rm -rf "' +
        sessionDir +
        '"   (Linux)\n' +
        'Sonra tekrar: node scripts/send-whatsapp.js "' +
        (url || '') +
        '"'
    );
  }, CONNECT_TIMEOUT_MS);

  const runDelivery = async (currentSock, gen) => {
    if (finished || delivered || delivering || gen !== generation) return;
    delivering = true;
    try {
      await waitUntilUsable(currentSock);
      if (action === 'retract') {
        // Drop every tracked send (link + APK) when the tunnel is cancelled.
        await deleteStored(currentSock, activeTunnelUrl());
        const purged = await purgeInactiveTunnelLinks(currentSock);
        delivered = true;
        finish(
          purged.failed ? 1 : 0,
          purged.failed
            ? 'Bazi pasif tunel / APK mesajlari kaldirilamadi.'
            : 'Pasif tunel ve APK mesajlari tarandi.'
        );
        return;
      }
      await deliver(currentSock);
      delivered = true;
      finish(0);
    } catch (err) {
      delivering = false;
      if (finished || gen !== generation) return;
      const text = err?.message || String(err);
      if (text === 'WRONG_LINE' || /WRONG_LINE/.test(text)) {
        replaceWithQr('Kayitli hat bu numara degil: ' + (err.linked || readLinkedId() || 'yok'));
        return;
      }
      if (/connection closed|timed out|not-authorized|stream errored/i.test(text) && attempts < MAX_RECONNECT) {
        console.log('  Gonderim hazir degil, yeniden denenecek: ' + text);
        return;
      }
      finish(
        1,
        'Mesaj gonderilemedi / send failed: ' +
          text +
          '\nKontrol: targetPhone dogru mu? WhatsApp oturumu bagli mi?\n' +
          'Check targetPhone in scripts/whatsapp-config.json and re-scan QR if needed.'
      );
    }
  };

  const connect = async () => {
    if (finished || delivered) return;
    const gen = ++generation;
    delivering = false;

    const { state, saveCreds } = await useMultiFileAuthState(sessionDir);
    let version;
    try {
      version = await Promise.race([
        fetchLatestBaileysVersion().then((out) => out.version),
        new Promise((resolve) => setTimeout(() => resolve(undefined), 8000))
      ]);
    } catch {
      version = undefined;
    }

    const current = makeWASocket({
      auth: state,
      version,
      logger: pino({ level: 'silent' }),
      browser: process.platform === 'win32' ? Browsers.windows('Duendee Tunnel Tool') : Browsers.ubuntu('Duendee Tunnel Tool'),
      syncFullHistory: action === 'retract',
      markOnlineOnConnect: false
    });
    sock = current;
    current.ev.on('messaging-history.set', (payload) => {
      for (const msg of payload?.messages || []) rememberHistory(msg);
    });
    current.ev.on('messages.upsert', (payload) => {
      for (const msg of payload?.messages || []) rememberHistory(msg);
    });

    let socketOpen = false;
    let notificationsReady = false;
    let readyTimer = null;

    const armDelivery = () => {
      if (finished || delivered || delivering || gen !== generation) return;
      if (!socketOpen || !notificationsReady) return;
      if (readyTimer) {
        clearTimeout(readyTimer);
        readyTimer = null;
      }
      readyTimer = setTimeout(() => {
        readyTimer = null;
        void runDelivery(current, gen);
      }, SEND_DELAY_MS);
    };

    const sessionProbe = setTimeout(() => {
      if (finished || delivered || socketOpen || qrSeen || gen !== generation) return;
      if (allowQr) return;
      replaceWithQr('Kayitli oturum yanit vermiyor.');
    }, 20000);

    current.ev.on('creds.update', saveCreds);

    current.ev.on('connection.update', (update) => {
      if (finished || gen !== generation) return;
      try {
      const { connection, lastDisconnect, qr } = update;

      if (qr && action === 'send' && !delivered && allowQr) showQr(qr);

      if (update.receivedPendingNotifications) {
        notificationsReady = true;
        armDelivery();
      }

      if (connection === 'open') {
        const linked = current.user?.id || '';
        clearTimeout(sessionProbe);
        if (!keepLinked && action === 'send' && linked && isPhoneAccount(linked) && !phonesMatch(linked, phone)) {
          replaceWithQr('Acilan oturum ' + linked + ' hattina ait.');
          return;
        }
        console.log('  WhatsApp hatti bagli: ' + (linked || phone));
        socketOpen = true;
        if (readyTimer) clearTimeout(readyTimer);
        readyTimer = setTimeout(() => {
          readyTimer = null;
          if (gen !== generation || finished || delivered) return;
          notificationsReady = true;
          armDelivery();
        }, READY_FALLBACK_MS);
        armDelivery();
      }

      if (connection === 'close') {
        socketOpen = false;
        notificationsReady = false;
        if (readyTimer) {
          clearTimeout(readyTimer);
          readyTimer = null;
        }
        if (delivered || finished) return;
        delivering = false;

        const code = lastDisconnect?.error?.output?.statusCode;
        const loggedOut = code === DisconnectReason.loggedOut;
        const badSession = code === DisconnectReason.badSession;
        const restarting = code === DisconnectReason.restartRequired;

        if ((loggedOut || badSession) && action === 'send') {
          replaceWithQr(loggedOut ? 'Oturum dusmus.' : 'Oturum bozuk.');
          return;
        }
        if (loggedOut || badSession) {
          finish(1, 'WhatsApp oturumu yok; eski link mesaji kaldirilamadi.');
          return;
        }

        if (!restarting) attempts += 1;
        if (attempts > MAX_RECONNECT) {
          finish(1, 'Baglanti ' + MAX_RECONNECT + ' kez kesildi / connection dropped repeatedly.');
          return;
        }
        console.log('  Yeniden baglaniliyor (' + attempts + '/' + MAX_RECONNECT + ')...');
        setTimeout(() => {
          connect().catch((err) => finish(1, 'WhatsApp baslatilamadi: ' + (err?.message || err)));
        }, restarting ? 500 : 2000);
      }
      } catch (err) {
        console.error('  WhatsApp baglanti hatasi: ' + (err?.message || err));
      }
    });
  };

  await connect();
}

const runningDirectly = process.argv[1]
  && path.resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase();

if (runningDirectly) {
  main().catch((err) => {
    if (action === 'retract') releaseRetractLock();
    console.error('WhatsApp baslatilamadi / failed to start:', err?.message || err);
    process.exit(1);
  });
}
