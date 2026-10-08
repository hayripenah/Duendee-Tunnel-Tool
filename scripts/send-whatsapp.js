import { default as makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion, Browsers } from '@whiskeysockets/baileys';
import qrcodeTerminal from 'qrcode-terminal';
import QRCode from 'qrcode';
import pino from 'pino';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { spawn } from 'child_process';
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
const action = String(process.env.DT_WA_ACTION || 'send').trim().toLowerCase() === 'retract' ? 'retract' : 'send';

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

const sessionDir = path.isAbsolute(config.sessionDir)
  ? config.sessionDir
  : path.join(toolRoot, config.sessionDir || '.whatsapp-session');
const sentPath = path.join(sessionDir, 'sent-links.json');
const qrImage = path.join(os.tmpdir(), 'duendee-whatsapp-qr.png');
const credsPath = path.join(sessionDir, 'creds.json');
const hasSession = fs.existsSync(credsPath);

const CONNECT_TIMEOUT_MS = Number(process.env.DT_WA_TIMEOUT_MS) || (action === 'retract' ? 45000 : 90000);
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
  console.log('');
  console.log('  ============================================================');
  console.log('  WhatsApp oturumu yok — QR ile baglayin / Scan QR to link');
  console.log('  WhatsApp > Bagli Cihazlar > Cihaz Bagla');
  console.log('  WhatsApp > Linked Devices > Link a Device');
  console.log('  ============================================================');
  console.log('');
  qrcodeTerminal.generate(qr, { small: true });
  QRCode.toFile(qrImage, qr, { width: 400, margin: 2 })
    .then(() => {
      console.log('');
      console.log('  QR resmi acildi / QR image opened: ' + qrImage);
      console.log('  Tarama sonrasi mesaj otomatik gidecek / Message sends after scan.');
      try {
        if (process.platform === 'win32') {
          spawn('cmd', ['/c', 'start', '', qrImage], { detached: true, stdio: 'ignore' }).unref();
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

async function resolveJid(sock, rawPhone) {
  const digits = toDigits(rawPhone);
  if (!digits) {
    throw new Error('Telefon numarasi gecersiz / Invalid phone: ' + rawPhone);
  }
  const bare = digits + '@s.whatsapp.net';
  try {
    const results = await sock.onWhatsApp(bare);
    const hit = Array.isArray(results) ? results.find((r) => r && (r.exists || r.jid)) : null;
    if (hit?.jid) return hit.jid;
  } catch {
    /* fall through */
  }
  return bare;
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
    try {
      await sock.sendMessage(row.jid, {
        delete: { remoteJid: row.jid, fromMe: true, id: row.id }
      });
      console.log('  Eski link mesaji kaldirildi: ' + (row.url || row.id));
    } catch (err) {
      console.error('  Mesaj kaldirilamadi, sonra tekrar denenecek: ' + (err?.message || err));
      keep.push(row);
    }
  }
  saveSent(keep);
  return keep;
}

async function deliver(sock) {
  await waitUntilUsable(sock);
  try {
    await sock.sendPresenceUpdate('available');
  } catch {
    /* presence is optional */
  }
  await deleteStored(sock, url);
  const already = loadSent().some((row) => sameUrl(row.url, url));
  if (already) {
    console.log('WhatsApp mesaji zaten aktif linki tasiyor / already current: ' + url);
    return;
  }
  const jid = await resolveJid(sock, phone);
  const message = String(config.messageTemplate || 'Duendee tunnel linki: {url}').replace('{url}', url);
  const sentMsg = await sock.sendMessage(jid, { text: message });
  const id = sentMsg?.key?.id;
  if (!id) {
    throw new Error('Mesaj anahtari donmedi / WhatsApp did not return a message id');
  }
  const rows = loadSent().filter((row) => !sameUrl(row.url, url));
  rows.push({
    id,
    jid: sentMsg.key.remoteJid || jid,
    url,
    at: new Date().toISOString()
  });
  saveSent(rows);
  console.log('WhatsApp mesaji gonderildi / Message sent -> ' + phone + ' | ' + url);
}

async function main() {
  const stored = loadSent();
  if (action === 'retract' && stored.length === 0) {
    console.log('  Kaldirilacak eski link mesaji yok.');
    return;
  }
  if (action === 'retract' && !hasSession) {
    fail('WhatsApp oturumu yok; eski link mesaji kaldirilamadi.');
  }

  fs.mkdirSync(sessionDir, { recursive: true });

  if (hasSession) {
    console.log('  WhatsApp oturumu bulundu, baglaniliyor...');
  } else {
    console.log('  Ilk kurulum: QR taramaniz istenecek (oturum sonra saklanir).');
  }

  let finished = false;
  let delivered = false;
  let delivering = false;
  let attempts = 0;
  let generation = 0;
  let sock = null;
  let timer = null;

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
    setTimeout(() => process.exit(code), 350);
  };

  timer = setTimeout(() => {
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
        await deleteStored(currentSock, '');
        delivered = true;
        const left = loadSent().length;
        finish(left === 0 ? 0 : 1, left === 0 ? 'Eski tunnel linki mesajlari kaldirildi.' : 'Bazi mesajlar kaldirilamadi.');
        return;
      }
      await deliver(currentSock);
      delivered = true;
      finish(0);
    } catch (err) {
      delivering = false;
      if (finished || gen !== generation) return;
      const text = err?.message || String(err);
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
      browser: Browsers.ubuntu('Chrome'),
      syncFullHistory: false,
      markOnlineOnConnect: true
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
      const { connection, lastDisconnect, qr } = update;

      if (qr && action === 'send' && !delivered) showQr(qr);

      if (update.receivedPendingNotifications) {
        notificationsReady = true;
        armDelivery();
      }

      if (connection === 'open') {
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

        if (loggedOut || badSession) {
          console.error(
            loggedOut
              ? '  Oturum dusuruldu — QR yeniden taranmali / Logged out — re-scan QR.'
              : '  Bozuk oturum temizleniyor / Bad session, clearing...'
          );
          try {
            fs.rmSync(sessionDir, { recursive: true, force: true });
          } catch {
            /* ignore */
          }
          finish(1, 'WhatsApp oturumu sifirlandi. Tüneli yeniden baslatin / Session cleared; restart tunnel.');
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
    });
  };

  await connect();
}

main().catch((err) => {
  console.error('WhatsApp baslatilamadi / failed to start:', err?.message || err);
  process.exit(1);
});
