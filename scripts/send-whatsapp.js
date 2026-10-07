import { default as makeWASocket, useMultiFileAuthState, DisconnectReason } from '@whiskeysockets/baileys';
import qrcodeTerminal from 'qrcode-terminal';
import QRCode from 'qrcode';
import pino from 'pino';
import path from 'path';
import fs from 'fs';
import os from 'os';
import { spawn } from 'child_process';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const config = JSON.parse(fs.readFileSync(path.join(__dirname, 'whatsapp-config.json'), 'utf8'));
const urlFile = path.join(__dirname, '..', '.tunnelstate', 'tunnel.url');

function resolveUrl(raw) {
  let fromFile = '';
  const arg = String(raw || '').trim();
  const filePath = arg && !/^https?:\/\//i.test(arg) && fs.existsSync(arg) ? arg : urlFile;
  if (fs.existsSync(filePath)) {
    fromFile = fs.readFileSync(filePath, 'utf8').trim();
  }
  const value = fromFile || arg;
  return value.replace(/[\r\n\s]+/g, '').replace(/\/+$/, '');
}

const url = resolveUrl(process.argv[2]);
const phone = process.argv[3] || config.targetPhone;

if (!url || !/^https:\/\//i.test(url)) {
  console.error('Kullanim: node send-whatsapp.js <tunnel-url> [phone]');
  process.exit(1);
}

const sessionDir = path.join(__dirname, '..', config.sessionDir);
const qrImage = path.join(os.tmpdir(), 'duendee-whatsapp-qr.png');
let attempts = 0;
const MAX_ATTEMPTS = 3;

function showQr(qr) {
  console.log('\n  WhatsApp QR kodu, terminalde de gorunuyor.');
  console.log('  WhatsApp > Bagli Cihazlar > Cihaz Bagla [Link a Device]\n');
  qrcodeTerminal.generate(qr, { small: true });
  QRCode.toFile(qrImage, qr, { width: 400, margin: 2 })
    .then(() => {
      console.log('\n  QR pencerede acildi. Acilmadiysa: start ' + qrImage);
      try {
        spawn('cmd', ['/c', 'start', '', qrImage], { detached: true, stdio: 'ignore' }).unref();
      } catch {}
    })
    .catch(() => {});
}

async function send() {
  const { state, saveCreds } = await useMultiFileAuthState(sessionDir);

  const sock = makeWASocket({
    auth: state,
    logger: pino({ level: 'silent' }),
    browser: ['Duendee Tunnel Tool', 'Chrome', '1.0.0'],
    syncFullHistory: false
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
      setTimeout(send, 3000);
    }

    if (connection === 'open' && !sent) {
      sent = true;
      const jid = phone.replace(/[^0-9]/g, '') + '@s.whatsapp.net';
      const message = config.messageTemplate.replace('{url}', url);

      sock.sendMessage(jid, { text: message })
        .then(() => {
          console.log('WhatsApp mesaji gonderildi -> ' + phone + ' | ' + url);
          sock.end();
          setTimeout(() => process.exit(0), 500);
        })
        .catch((err) => {
          console.error('Mesaj gonderilemedi:', err.message);
          process.exit(1);
        });
    }
  });
}

send();