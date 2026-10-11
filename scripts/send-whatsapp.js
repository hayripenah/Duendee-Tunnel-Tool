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
const urlFile = path.join(toolRoot, '.tunnelstate', 'tunnel.url');
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

function sameUrl(a, b) {
  const norm = (value) => String(value || '').trim().replace(/\/+$/, '').toLowerCase();
  return norm(a) !== '' && norm(a) === norm(b);
}

const url = action === 'retract' ? '' : resolveUrl(process.argv[2] || process.env.DT_WA_URL || '');
const phone = String(process.argv[3] || process.env.DT_WA_PHONE || config.targetPhone || '').trim();

if (action === 'send' && (!url || !/^https:\/\//i.test(url))) {
  fail(
    'Kullanim / Usage: node send-whatsapp.js <tunnel-url|tunnel.url-file> [phone]\n' +
      'URL yok veya gecersiz / missing or invalid URL.'
  );
}

if (action === 'send' && !phone) {
  fail(
    'Hedef telefon yok / No target phone.\n' +
      'scripts/whatsapp-config.json icinde targetPhone ayarlayin veya arguman verin.\n' +
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

const CONNECT_TIMEOUT_MS = Number(process.env.DT_WA_TIMEOUT_MS) || (action === 'retract' ? 45000 : 180000);
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

async function deleteStored(sock, keepUrl) {
  const rows = loadSent();
  const keep = [];
  for (const row of rows) {
    if (keepUrl && sameUrl(row.url, keepUrl)) {
      keep.push(row);
      continue;
    }
    const pn = toDigits(phone) + '@s.whatsapp.net';
    const jids = [...new Set([row.jid, pn].filter(Boolean))];
    let removed = false;
    for (const jid of jids) {
      try {
        await sock.sendMessage(jid, {
          delete: { remoteJid: jid, fromMe: true, id: row.id }
        });
        removed = true;
      } catch (err) {
        console.error('  Mesaj kaldirilamadi (' + jid + '): ' + (err?.message || err));
      }
    }
    if (removed) console.log('  Eski link mesaji kaldirildi: ' + (row.url || row.id));
    else keep.push(row);
  }
  saveSent(keep);
  return keep;
}

function trycloudflareUrls(text) {
  const found = String(text || '').match(/https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com\/?(?!\S)/gi) || [];
  return [...new Set(found.map((item) => item.replace(/\/+$/, '')))];
}

function messageText(msg) {
  const content = msg?.message || {};
  return (
    content.conversation ||
    content.extendedTextMessage?.text ||
    content.ephemeralMessage?.message?.conversation ||
    content.ephemeralMessage?.message?.extendedTextMessage?.text ||
    ''
  );
}

function activeTunnelUrl() {
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
    for (const url of trycloudflareUrls(messageText(msg))) {
      found.set(id + '\n' + jid, { id, jid, url });
    }
  };
  const onHistory = (payload) => {
    for (const msg of payload?.messages || []) absorb(msg);
  };
  const onUpsert = (payload) => {
    for (const msg of payload?.messages || []) absorb(msg);
  };
  sock.ev.on('messaging-history.set', onHistory);
  sock.ev.on('messages.upsert', onUpsert);
  for (const row of loadSent()) {
    for (const url of trycloudflareUrls(row.url)) {
      if (row.id && row.jid) found.set(row.id + '\n' + row.jid, { id: row.id, jid: row.jid, url });
    }
  }
  const anchor = loadSent().find((row) => row.id && row.jid);
  if (anchor && typeof sock.fetchMessageHistory === 'function') {
    const stamp = Date.parse(anchor.at || '') || 0;
    try {
      await sock.fetchMessageHistory(50, { remoteJid: anchor.jid, fromMe: true, id: anchor.id }, stamp);
    } catch (err) {
      console.log('  Sohbet gecmisi alinamadi: ' + (err?.message || err));
    }
  }
  await new Promise((resolve) => setTimeout(resolve, 2500));
  sock.ev.off('messaging-history.set', onHistory);
  sock.ev.off('messages.upsert', onUpsert);
  return [...found.values()];
}

async function purgeInactiveTunnelLinks(sock) {
  const keepUrl = activeTunnelUrl();
  const rows = await scanTunnelMessages(sock);
  const drop = rows.filter((row) => !sameUrl(row.url, keepUrl));
  await Promise.all(
    drop.map(async (row) => {
      try {
        await sock.sendMessage(row.jid, {
          delete: { remoteJid: row.jid, fromMe: true, id: row.id },
        });
        row.removed = true;
      } catch (err) {
        console.error('  Mesaj kaldirilamadi (' + row.jid + '): ' + (err?.message || err));
      }
    })
  );
  const removedIds = new Set(drop.filter((row) => row.removed).map((row) => row.id));
  saveSent(loadSent().filter((row) => !removedIds.has(row.id)));
  const removed = removedIds.size;
  if (keepUrl) console.log('  Aktif tunel linki birakildi.');
  console.log('  Pasif tunel linkleri kaldirildi: ' + removed);
  return { removed, failed: drop.length - removed };
}

function rememberSent(id, jid, messageUrl) {
  const rows = loadSent().filter((row) => row.id !== id);
  rows.push({ id, jid, url: messageUrl, at: new Date().toISOString() });
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
  const acked = await waitForServerAck(sock, id, 12000);
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
  if (process.env.DT_WA_KEEP_EXISTING === '1' && loadSent().some((row) => sameUrl(row.url, url))) {
    console.log('  Bu link zaten WhatsApp mesajinda.');
    delivered = true;
    finish(0, 'Mevcut link mesaji duruyor.');
    return;
  }
  await deleteStored(sock, url);
  const lid = await resolveSendJid(sock, phone);
  const pn = toDigits(phone) + '@s.whatsapp.net';
  const targets = [...new Set([lid, pn].filter(Boolean))];
  const message = String(config.messageTemplate || 'Duendee tunnel linki: {url}').replace('{url}', url);
  let last = null;
  for (const target of targets) {
    console.log('  Link gonderiliyor -> ' + phone + ' (' + target + ')');
    last = await sendText(sock, target, message);
    if (last.acked) break;
    console.log('  Sunucu onayi gelmedi, diger adres deneniyor...');
  }
  if (!last?.acked) {
    throw new Error('WhatsApp sunucusu mesaji onaylamadi');
  }
  console.log('WhatsApp mesaji gonderildi -> ' + phone + ' | ' + url);
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

const retractLock = path.join(toolRoot, '.tunnelstate', 'wa-retract.lock');

function claimRetractLock() {
  fs.mkdirSync(path.dirname(retractLock), { recursive: true });
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
        return claimRetractLock();
      }
    } catch {
      /* another retract owns the lock */
    }
    return false;
  }
}

function releaseRetractLock() {
  try {
    fs.rmSync(retractLock, { force: true });
  } catch {
    /* ignore */
  }
}

async function main() {
  if (action === 'retract' && !claimRetractLock()) {
    console.log('  Link mesaji kaldirma zaten calisiyor.');
    return;
  }

  const linkedNow = readLinkedId();
  const keepLinked = action === 'send' && keepExisting && hasSession && Boolean(linkedNow);
  if (keepLinked && loadSent().some((row) => sameUrl(row.url, url))) {
    console.log('  Bu link zaten WhatsApp mesajinda.');
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
        const purged = await purgeInactiveTunnelLinks(currentSock);
        delivered = true;
        finish(purged.failed ? 1 : 0, purged.failed ? 'Bazi pasif tunel linkleri kaldirilamadi.' : 'Pasif tunel link mesajlari tarandi.');
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
      ({ version } = await fetchLatestBaileysVersion());
    } catch {
      version = undefined;
    }

    const current = makeWASocket({
      auth: state,
      version,
      logger: pino({ level: 'silent' }),
      browser: process.platform === 'win32' ? Browsers.windows('Duendee Tunnel Tool') : Browsers.ubuntu('Duendee Tunnel Tool'),
      syncFullHistory: false,
      markOnlineOnConnect: false
    });
    sock = current;

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

main().catch((err) => {
  if (action === 'retract') releaseRetractLock();
  console.error('WhatsApp baslatilamadi / failed to start:', err?.message || err);
  process.exit(1);
});
