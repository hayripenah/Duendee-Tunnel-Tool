import { default as makeWASocket, useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } from '@whiskeysockets/baileys';
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

const url = resolveUrl(process.argv[2] || process.env.DT_WA_URL || '');
const phone = String(process.argv[3] || process.env.DT_WA_PHONE || config.targetPhone || '').trim();

if (!url || !/^https:\/\//i.test(url)) {
  fail(
    'Kullanim / Usage: node send-whatsapp.js <tunnel-url|tunnel.url-file> [phone]\n' +
      'URL yok veya gecersiz / missing or invalid URL.'
  );
}

if (!phone) {
  fail(
    'Hedef telefon yok / No target phone.\n' +
      'scripts/whatsapp-config.json icinde targetPhone ayarlayin veya arguman verin.\n' +
      'Ornek: node send-whatsapp.js "' + url + '" "+905xxxxxxxxx"'
  );
}

const sessionDir = path.isAbsolute(config.sessionDir)
  ? config.sessionDir
  : path.join(toolRoot, config.sessionDir || '.whatsapp-session');
const qrImage = path.join(os.tmpdir(), 'duendee-whatsapp-qr.png');
const credsPath = path.join(sessionDir, 'creds.json');
const hasSession = fs.existsSync(credsPath);

const CONNECT_TIMEOUT_MS = 120000;
const MAX_RECONNECT = 4;

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
    const results = await sock.onWhatsApp(digits);
    const hit = Array.isArray(results) ? results.find((r) => r && (r.exists || r.jid)) : null;
    if (hit?.jid) return hit.jid;
  } catch {
    /* fall through */
  }
  return bare;
}

async function deliver(sock) {
  const jid = await resolveJid(sock, phone);
  const message = String(config.messageTemplate || 'Duendee tunnel linki: {url}').replace('{url}', url);
  await sock.sendMessage(jid, { text: message });
  console.log('WhatsApp mesaji gonderildi / Message sent -> ' + phone + ' | ' + url);
}

async function main() {
  fs.mkdirSync(sessionDir, { recursive: true });

  if (hasSession) {
    console.log('  WhatsApp oturumu bulundu, baglaniliyor...');
    console.log('  Existing WhatsApp session found, connecting...');
  } else {
    console.log('  Ilk kurulum: QR taramaniz istenecek (oturum sonra saklanir).');
    console.log('  First run: scan QR once; session is saved for later sends.');
  }

  let finished = false;
  let sent = false;
  let attempts = 0;
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
        url +
        '"'
    );
  }, CONNECT_TIMEOUT_MS);

  const connect = async () => {
    if (finished || sent) return;

    const { state, saveCreds } = await useMultiFileAuthState(sessionDir);
    let version;
    try {
      ({ version } = await fetchLatestBaileysVersion());
    } catch {
      version = undefined;
    }

    sock = makeWASocket({
      auth: state,
      version,
      logger: pino({ level: 'silent' }),
      browser: ['Duendee Tunnel Tool', 'Chrome', '120.0.0'],
      syncFullHistory: false,
      markOnlineOnConnect: false,
      printQRInTerminal: false
    });

    sock.ev.on('creds.update', saveCreds);

    sock.ev.on('connection.update', async (update) => {
      if (finished) return;
      const { connection, lastDisconnect, qr } = update;

      if (qr && !sent) showQr(qr);

      if (connection === 'open' && !sent) {
        sent = true;
        try {
          await deliver(sock);
          finish(0);
        } catch (err) {
          finish(
            1,
            'Mesaj gonderilemedi / send failed: ' +
              (err?.message || err) +
              '\nKontrol: targetPhone dogru mu? WhatsApp oturumu bagli mi?\n' +
              'Check targetPhone in scripts/whatsapp-config.json and re-scan QR if needed.'
          );
        }
        return;
      }

      if (connection === 'close') {
        // Successful send already called finish(); ignore teardown close.
        if (sent || finished) return;

        const code = lastDisconnect?.error?.output?.statusCode;
        const loggedOut = code === DisconnectReason.loggedOut;
        const badSession = code === DisconnectReason.badSession;

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

        attempts += 1;
        if (attempts > MAX_RECONNECT) {
          finish(1, 'Baglanti ' + MAX_RECONNECT + ' kez kesildi / connection dropped repeatedly.');
          return;
        }
        console.log('  Yeniden baglaniliyor (' + attempts + '/' + MAX_RECONNECT + ')...');
        setTimeout(() => {
          connect().catch((err) => finish(1, 'WhatsApp baslatilamadi: ' + (err?.message || err)));
        }, 2000);
      }
    });
  };

  await connect();
}

main().catch((err) => {
  console.error('WhatsApp baslatilamadi / failed to start:', err?.message || err);
  process.exit(1);
});
