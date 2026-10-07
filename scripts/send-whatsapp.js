import { default as makeWASocket, useMultiFileAuthState, DisconnectReason } from '@whiskeysockets/baileys';
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
      'WhatsApp bağımlılıkları eksik. Kurulum:\n' +
        `  cd "${toolRoot}"\n` +
        '  npm install\n' +
        'Sonra tüneli yeniden başlatın veya: node scripts/send-whatsapp.js <url>'
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

const url = resolveUrl(process.argv[2]);
const phone = String(process.argv[3] || config.targetPhone || '').trim();

if (!url || !/^https:\/\//i.test(url)) {
  fail('Kullanim: node send-whatsapp.js <tunnel-url|tunnel.url-dosyasi> [phone]\nURL yok veya gecersiz.');
}

if (!phone) {
  fail(
    'Hedef telefon yok. scripts/whatsapp-config.json icinde targetPhone ayarlayin veya arguman verin.\n' +
      'Ornek: node send-whatsapp.js "' + url + '" "+905xxxxxxxxx"'
  );
}

const sessionDir = path.isAbsolute(config.sessionDir)
  ? config.sessionDir
  : path.join(toolRoot, config.sessionDir || '.whatsapp-session');
const qrImage = path.join(os.tmpdir(), 'duendee-whatsapp-qr.png');
let attempts = 0;
const MAX_ATTEMPTS = 3;

function showQr(qr) {
  console.log('\n  WhatsApp QR kodu, terminalde de gorunuyor.');
  console.log('  WhatsApp > Bagli Cihazlar > Cihaz Bagla [Link a Device]\n');
  qrcodeTerminal.generate(qr, { small: true });
  QRCode.toFile(qrImage, qr, { width: 400, margin: 2 })
    .then(() => {
      console.log('\n  QR pencerede acildi. Acilmadiysa: ' + qrImage);
      try {
        if (process.platform === 'win32') {
          spawn('cmd', ['/c', 'start', '', qrImage], { detached: true, stdio: 'ignore' }).unref();
        } else if (process.platform === 'darwin') {
          spawn('open', [qrImage], { detached: true, stdio: 'ignore' }).unref();
        } else {
          spawn('xdg-open', [qrImage], { detached: true, stdio: 'ignore' }).unref();
        }
      } catch {}
    })
    .catch(() => {});
}

async function send() {
  fs.mkdirSync(sessionDir, { recursive: true });
  const { state, saveCreds } = await useMultiFileAuthState(sessionDir);

  const sock = makeWASocket({
    auth: state,
    logger: pino({ level: 'silent' }),
    browser: ['Duendee Tunnel Tool', 'Chrome', '1.0.0'],
    syncFullHistory: false,
    markOnlineOnConnect: false
  });

  sock.ev.on('creds.update', saveCreds);

  let sent = false;

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) showQr(qr);

    if (connection === 'close') {
      const code = lastDisconnect?.error?.output?.statusCode;
      if (code === DisconnectReason.loggedOut) {
        console.log('  Oturum silindi, yeniden taramaniz gerekiyor.');
        fs.rmSync(sessionDir, { recursive: true, force: true });
        process.exit(1);
      }
      if (code === DisconnectReason.badSession) {
        console.log('  Bozuk oturum, temizleniyor...');
        fs.rmSync(sessionDir, { recursive: true, force: true });
        process.exit(1);
      }
      if (attempts >= MAX_ATTEMPTS) {
        console.log('  Baglanti 3 kez kesildi, cikiliyor.');
        process.exit(1);
      }
      attempts += 1;
      setTimeout(send, 2000);
    }

    if (connection === 'open' && !sent) {
      sent = true;
      const digits = phone.replace(/[^0-9]/g, '');
      if (!digits) {
        console.error('Telefon numarasi gecersiz:', phone);
        process.exit(1);
      }
      const jid = digits + '@s.whatsapp.net';
      const message = String(config.messageTemplate || 'Duendee tunnel linki: {url}').replace('{url}', url);

      sock.sendMessage(jid, { text: message })
        .then(() => {
          console.log('WhatsApp mesaji gonderildi -> ' + phone + ' | ' + url);
          try { sock.end(undefined); } catch {}
          setTimeout(() => process.exit(0), 400);
        })
        .catch((err) => {
          console.error('Mesaj gonderilemedi:', err?.message || err);
          console.error('Kontrol: targetPhone dogru mu, WhatsApp oturumu bagli mi?');
          process.exit(1);
        });
    }
  });
}

send().catch((err) => {
  console.error('WhatsApp baslatilamadi:', err?.message || err);
  process.exit(1);
});
