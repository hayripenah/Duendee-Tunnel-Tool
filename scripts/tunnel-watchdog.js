#!/usr/bin/env node
/**
 * Duendee Tunnel Tool - tunnel watchdog.
 *
 * Cloudflare quick tunnels (*.trycloudflare.com) are ephemeral. When the
 * connector loses its edge connection the quick tunnel is dropped on
 * Cloudflare's side ("Unauthorized: Tunnel not found") and the hostname is
 * removed from DNS. Every other device then fails with
 * DNS_PROBE_FINISHED_NXDOMAIN.
 *
 * This watchdog owns the lifecycle of the local quick tunnel:
 *   - it watches the published URL the way an outside device does
 *     (public DNS lookup + real HTTPS request),
 *   - it restarts cloudflared with a fresh hostname when the tunnel dies,
 *   - it republishes the new URL to the fleet and sends it over WhatsApp.
 *
 * Usage:
 *   node scripts/tunnel-watchdog.js --root <toolRoot> [--port 8080]
 *        [--state <stateDir>] [--cloudflared <path>] [--project <path>]
 *        [--product fm|duendee]
 *   node scripts/tunnel-watchdog.js --root <toolRoot> --check
 */

import { spawn, spawnSync } from 'child_process'
import dns from 'dns'
import fs from 'fs'
import https from 'https'
import net from 'net'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

function arg(name, fallback = '') {
  const i = process.argv.indexOf(name)
  if (i < 0 || i + 1 >= process.argv.length) return fallback
  return process.argv[i + 1]
}

function flag(name) {
  return process.argv.includes(name)
}

const toolRoot = path.resolve(arg('--root') || path.join(__dirname, '..'))
const product = String(arg('--product') || process.env.DT_PRODUCT || 'fm').toLowerCase()
const defaultState =
  product === 'duendee'
    ? path.join(toolRoot, '.tunnelstate-duendee')
    : path.join(toolRoot, '.tunnelstate')
const STATE = path.resolve(arg('--state') || defaultState)
const URL_FILE = path.join(STATE, 'tunnel.url')
const PID_FILE = path.join(STATE, 'tunnel.pid')
const SERVER_PID_FILE = path.join(STATE, 'server.pid')
const MANUAL_FILE = path.join(STATE, 'manual-stop')
const WATCHDOG_PID_FILE = path.join(STATE, 'watchdog.pid')
const WATCHDOG_LOG = path.join(STATE, 'watchdog.log')
const RECOVER_LOCK = path.join(STATE, 'recover.lock')
const TUNNEL_LOG = path.join(STATE, 'tunnel.log')
const TUNNEL_OUT_LOG = path.join(STATE, 'tunnel.out.log')
const WA_LOG = path.join(STATE, 'wa-watchdog.log')
const FLEET_ENABLED = product !== 'duendee'

// Last address written to the fleet record. Kept at module level so the
// recovery path and the main loop share the same state.
let publishedUrl = ''
let publishRetryAt = 0

const CHECK_MS = Number(process.env.DT_WATCHDOG_INTERVAL_MS || 15000)
const MAX_FAILS = Number(process.env.DT_WATCHDOG_MAX_FAILS || 3)
const GRACE_MS = Number(process.env.DT_WATCHDOG_GRACE_MS || 20000)
const RECOVER_LOCK_MS = Number(process.env.DT_WATCHDOG_LOCK_MS || 90000)
const PROTOCOL = process.env.DT_CF_PROTOCOL || 'http2'
const URL_RE = /https:\/\/[a-zA-Z0-9-]+\.(?:trycloudflare\.com|cfargotunnel\.com)/g

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function log(message) {
  const line = `${new Date().toISOString()} ${message}`
  try {
    fs.mkdirSync(STATE, { recursive: true })
    fs.appendFileSync(WATCHDOG_LOG, line + '\n')
  } catch {
    /* ignore */
  }
  console.log(line)
}

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8').trim()
  } catch {
    return ''
  }
}

function writeText(file, text) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, text)
  } catch {
    /* ignore */
  }
}

function readPid(file = PID_FILE) {
  const raw = readText(file)
  const id = Number(raw)
  return Number.isInteger(id) && id > 0 ? id : 0
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (err) {
    return err.code === 'EPERM'
  }
}

function processName(pid) {
  try {
    if (process.platform === 'linux') {
      return fs.readFileSync(`/proc/${pid}/comm`, 'utf8').replace(/\0/g, '').trim()
    }
    if (process.platform === 'win32') {
      const out = spawnSync('tasklist', ['/FI', `PID eq ${pid}`, '/NH', '/FO', 'CSV'], { encoding: 'utf8' })
      const match = /"([^"]+)"/.exec(String(out.stdout || ''))
      return match ? match[1] : ''
    }
  } catch {
    /* ignore */
  }
  return ''
}

function portListening(port) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port: Number(port) || 0, timeout: 1500 })
    let settled = false
    const done = (ok) => {
      if (settled) return
      settled = true
      try {
        sock.destroy()
      } catch {
        /* ignore */
      }
      resolve(ok)
    }
    sock.once('connect', () => done(true))
    sock.once('timeout', () => done(false))
    sock.once('error', () => done(false))
  })
}

function hostOf(url) {
  return String(url || '')
    .replace(/^https?:\/\//i, '')
    .split('/')[0]
    .split('?')[0]
    .split(':')[0]
}

function isNxError(err) {
  const code = String(err && err.code ? err.code : '')
  return code === 'ENOTFOUND' || code === 'ENODATA' || code === 'NXDOMAIN'
}

async function resolveSystem(host) {
  if (!host) return { ok: false, nx: false, error: 'host yok' }
  try {
    const addrs = await dns.promises.resolve4(host)
    return { ok: addrs.length > 0, nx: false, addrs }
  } catch (err) {
    return { ok: false, nx: isNxError(err), error: String((err && err.code) || err) }
  }
}

async function resolveVia(server, host) {
  return new Promise((resolve) => {
    let done = false
    const finish = (value) => {
      if (done) return
      done = true
      resolve(value)
    }
    try {
      const resolver = new dns.Resolver()
      resolver.setServers([server])
      resolver.resolve4(host, (err, addrs) => {
        if (err) {
          finish({ ok: false, nx: isNxError(err), error: String(err.code || err) })
          return
        }
        finish({ ok: Array.isArray(addrs) && addrs.length > 0, nx: false, addrs })
      })
    } catch (err) {
      finish({ ok: false, nx: false, error: String((err && err.code) || err) })
    }
  })
}

async function resolvePublic(host) {
  if (!host) return { state: 'unknown' }
  const servers = ['1.1.1.1', '8.8.8.8']
  const results = await Promise.all(servers.map((server) => resolveVia(server, host)))
  const nx = results.some((row) => row.nx)
  const ok = results.some((row) => row.ok)
  // Both public resolvers answered but neither has the name: the quick tunnel
  // hostname was removed from DNS (the NXDOMAIN other devices see).
  const answered = results.filter((row) => !row.nx).length
  if (ok) return { state: 'ok' }
  if (nx && answered < servers.length) return { state: 'nx' }
  if (nx) return { state: 'nx' }
  return { state: 'unknown' }
}

async function httpProbe(url) {
  // node:https instead of fetch: a forced process.exit() while an undici
  // socket is still closing aborts the process with a libuv assertion.
  return new Promise((resolve) => {
    let settled = false
    const finish = (value) => {
      if (settled) return
      settled = true
      resolve(value)
    }
    let req = null
    try {
      req = https.get(url, { timeout: 12000, agent: false }, (res) => {
        const status = res.statusCode || 0
        res.resume()
        res.once('end', () => finish({ ok: status >= 200 && status < 400, status }))
        res.once('error', () => finish({ ok: false, status, error: 'body' }))
      })
      req.on('timeout', () => {
        try {
          req.destroy()
        } catch {
          /* ignore */
        }
        finish({ ok: false, status: 0, error: 'timeout' })
      })
      req.on('error', (err) => {
        finish({ ok: false, status: 0, error: String((err && err.code) || err) })
      })
    } catch (err) {
      finish({ ok: false, status: 0, error: String((err && err.code) || err) })
    }
  })
}

/**
 * Health of the published link, measured the way an outside device sees it.
 */
async function checkHealth(url) {
  const host = hostOf(url)
  const pid = readPid()
  const procAlive = pidAlive(pid)
  const procName = procAlive ? processName(pid) : ''
  const dnsSystem = await resolveSystem(host)
  const dnsPublic = await resolvePublic(host)
  const http = await httpProbe(url)
  const originUp = await portListening(readPort())
  return {
    url,
    host,
    procAlive,
    procName,
    dnsSystem,
    dnsPublic,
    http,
    originUp,
    dns: dnsPublic.state
  }
}

function readPort() {
  const fromArg = Number(arg('--port'))
  if (Number.isInteger(fromArg) && fromArg > 0) return fromArg
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(toolRoot, 'config.json'), 'utf8'))
    const port = Number(cfg.port)
    if (Number.isInteger(port) && port > 0) return port
  } catch {
    /* ignore */
  }
  return 8080
}

function findCloudflared() {
  const explicit = arg('--cloudflared')
  if (explicit && fs.existsSync(explicit)) return explicit
  if (process.env.DT_CF && fs.existsSync(process.env.DT_CF)) return process.env.DT_CF
  const names = process.platform === 'win32' ? ['cloudflared.exe'] : ['cloudflared']
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean)
  if (process.platform === 'win32') {
    dirs.push(path.join(process.env.LOCALAPPDATA || '', 'DuendeeTunnel'))
    dirs.push(path.join(process.env.USERPROFILE || '', '.cloudflared'))
  } else {
    dirs.push(path.join(process.env.HOME || '', '.local', 'bin'))
    dirs.push('/usr/local/bin')
  }
  for (const dir of dirs) {
    for (const name of names) {
      const full = path.join(dir, name)
      try {
        if (fs.existsSync(full)) return full
      } catch {
        /* ignore */
      }
    }
  }
  return ''
}

function urlFromLogs() {
  const parts = []
  for (const file of [TUNNEL_OUT_LOG, TUNNEL_LOG]) {
    try {
      const stat = fs.statSync(file)
      parts.push({ time: stat.mtimeMs, text: fs.readFileSync(file, 'utf8') })
    } catch {
      /* ignore */
    }
  }
  if (!parts.length) return ''
  parts.sort((a, b) => a.time - b.time)
  const found = (parts.map((part) => part.text).join('\n')).match(URL_RE)
  if (!found || !found.length) return ''
  return found[found.length - 1].replace(/\/+$/, '')
}

function killTunnel() {
  const pid = readPid()
  if (pid && pidAlive(pid)) {
    if (process.platform === 'win32') {
      spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' })
    } else {
      try {
        process.kill(-pid, 'SIGTERM')
      } catch {
        /* not a group leader */
      }
      try {
        process.kill(pid, 'SIGTERM')
      } catch {
        /* gone */
      }
    }
  }
  try {
    fs.rmSync(PID_FILE, { force: true })
  } catch {
    /* ignore */
  }
}

function startCloudflared(bin, port) {
  if (!bin) return 0
  const target = `http://127.0.0.1:${port}`
  const args = [
    'tunnel',
    '--url',
    target,
    '--http-host-header',
    `127.0.0.1:${port}`,
    '--no-autoupdate',
    '--no-prechecks',
    '--protocol',
    PROTOCOL,
    '--edge-ip-version',
    '4',
    '--retries',
    '8'
  ]
  let outFd = null
  let errFd = null
  try {
    outFd = fs.openSync(TUNNEL_OUT_LOG, 'a')
    errFd = fs.openSync(TUNNEL_LOG, 'a')
  } catch {
    /* ignore */
  }
  const child = spawn(bin, args, {
    detached: true,
    windowsHide: true,
    stdio: ['ignore', outFd === null ? 'ignore' : outFd, errFd === null ? 'ignore' : errFd]
  })
  child.on('error', (err) => log(`cloudflared başlatılamadı: ${err.message}`))
  child.unref()
  return child.pid || 0
}

async function waitForUrl(timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const url = urlFromLogs()
    if (url) return url
    await sleep(500)
  }
  return ''
}

async function waitForPublic(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  let last = ''
  while (Date.now() < deadline) {
    const host = hostOf(url)
    const dnsPublic = await resolvePublic(host)
    const http = await httpProbe(url)
    if (dnsPublic.state === 'ok' && http.ok) return true
    last = `dns=${dnsPublic.state} http=${http.status || http.error || '000'}`
    await sleep(3000)
  }
  log(`yayın adresi hazır değil (${last})`)
  return false
}

function acquireRecoverLock() {
  try {
    fs.mkdirSync(STATE, { recursive: true })
    const stat = fs.statSync(RECOVER_LOCK)
    if (Date.now() - stat.mtimeMs < RECOVER_LOCK_MS) return false
  } catch {
    /* no lock or unreadable */
  }
  try {
    fs.writeFileSync(RECOVER_LOCK, String(Date.now()))
  } catch {
    return false
  }
  return true
}

function releaseRecoverLock() {
  try {
    fs.rmSync(RECOVER_LOCK, { force: true })
  } catch {
    /* ignore */
  }
}

function fleetRun(args, env = {}) {
  const script = path.join(toolRoot, 'scripts', 'fleet.js')
  if (!fs.existsSync(script)) return { code: -1, out: '', err: 'fleet.js yok' }
  const res = spawnSync(process.execPath, [script, ...args, '--root', toolRoot], {
    encoding: 'utf8',
    env: { ...process.env, ...env }
  })
  return { code: res.status, out: String(res.stdout || ''), err: String(res.stderr || '') }
}

function publishToFleet(url) {
  if (!FLEET_ENABLED) return true
  const res = fleetRun(['publish', '--url', url], { DT_FLEET_QUIET: '1' })
  if (res.code === 0) {
    log('filo kaydı güncellendi');
    return true
  }
  log(`filo kaydı güncellenemedi: ${(res.err || '').trim() || `çıkış ${res.code}`}`)
  return false
}

function notifyNewLink(url) {
  const script = path.join(toolRoot, 'scripts', 'send-whatsapp.js')
  if (!fs.existsSync(script)) return
  let fd = null
  try {
    fd = fs.openSync(WA_LOG, 'a')
  } catch {
    /* ignore */
  }
  const waProduct = product === 'duendee' ? 'duendee' : 'fm'
  const defaultTpl =
    waProduct === 'duendee'
      ? 'Duendee tüneli yenilendi (main)\n{url}'
      : 'DuendeeFM tüneli yenilendi\n{url}'
  const child = spawn(process.execPath, [script, url, '--product', waProduct], {
    detached: true,
    windowsHide: true,
    stdio: ['ignore', fd === null ? 'ignore' : fd, fd === null ? 'ignore' : fd],
    env: {
      ...process.env,
      DT_WA_PRODUCT: waProduct,
      DT_WA_URL_FILE: URL_FILE,
      DT_WA_TEMPLATE: process.env.DT_WA_RECOVER_TEMPLATE || defaultTpl,
      DT_WA_TIMEOUT_MS: process.env.DT_WA_TIMEOUT_MS || '120000'
    }
  })
  child.on('error', (err) => log(`WhatsApp bildirimi başlatılamadı: ${err.message}`))
  child.unref()
  log(`WhatsApp için yeni ${waProduct} linki gönderiliyor`)
}

function findNpm() {
  const names = process.platform === 'win32' ? ['npm.cmd', 'npm'] : ['npm']
  const dirs = (process.env.PATH || '').split(path.delimiter).filter(Boolean)
  for (const dir of dirs) {
    for (const name of names) {
      const full = path.join(dir, name)
      try {
        if (fs.existsSync(full)) return full
      } catch {
        /* ignore */
      }
    }
  }
  return ''
}

/**
 * Brings the local app back up. The tool scripts know how to build the
 * bundle and to write the Supabase settings, so they are preferred; the
 * direct vite start is the fallback.
 */
async function ensureOrigin() {
  const port = readPort()
  if (await portListening(port)) return true
  const project = arg('--project') || readProjectFromConfig()
  if (!project || !fs.existsSync(project)) {
    log('uygulama klasörü yok, origin yeniden başlatılamıyor')
    return false
  }
  const started = await startOriginWithTool()
  if (started) {
    for (let i = 0; i < 60; i++) {
      if (await portListening(port)) {
        log(`uygulama ${port} portunda yeniden açıldı`)
        return true
      }
      await sleep(1000)
    }
  }
  return startOriginDirect(project, port)
}

function startOriginWithTool() {
  const ps1 = path.join(toolRoot, 'windows', 'duendee-tunnel-tool.ps1')
  const sh = path.join(toolRoot, 'linux', 'duendee-tunnel-tool.sh')
  let res = null
  if (process.platform === 'win32' && fs.existsSync(ps1)) {
    res = spawnSync('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', ps1, 'start-origin'
    ], {
      encoding: 'utf8',
      timeout: 300000,
      env: { ...process.env, DT_SKIP_UPDATE: '1' }
    })
  } else if (process.platform !== 'win32' && fs.existsSync(sh)) {
    res = spawnSync('bash', [sh, 'start-origin'], {
      encoding: 'utf8',
      timeout: 300000,
      env: { ...process.env, DT_SKIP_UPDATE: '1' }
    })
  }
  if (!res) return false
  if (res.status === 0) return true
  log(`uygulama başlatma komutu başarısız (çıkış ${res.status})`)
  return false
}

async function startOriginDirect(project, port) {
  const vite = path.join(project, 'node_modules', 'vite', 'bin', 'vite.js')
  const dist = path.join(project, 'dist', 'index.html')
  let outFd = null
  let errFd = null
  try {
    outFd = fs.openSync(path.join(STATE, 'server.out.log'), 'a')
    errFd = fs.openSync(path.join(STATE, 'server.err.log'), 'a')
  } catch {
    /* ignore */
  }
  const stdio = ['ignore', outFd === null ? 'ignore' : outFd, errFd === null ? 'ignore' : errFd]
  let child = null
  if (fs.existsSync(vite)) {
    const mode = fs.existsSync(dist) ? ['preview', '--host', '127.0.0.1'] : ['--host', '127.0.0.1']
    child = spawn(process.execPath, [vite, ...mode, '--port', String(port), '--strictPort'], {
      cwd: project,
      detached: true,
      windowsHide: true,
      stdio
    })
  } else {
    const npm = findNpm()
    if (!npm) {
      log('npm yok, origin yeniden başlatılamıyor')
      return false
    }
    child = spawn(npm, ['run', 'dev'], {
      cwd: project,
      detached: true,
      windowsHide: true,
      stdio,
      shell: process.platform === 'win32'
    })
  }
  child.on('error', (err) => log(`uygulama başlatılamadı: ${err.message}`))
  child.unref()
  writeText(SERVER_PID_FILE, String(child.pid || ''))
  for (let i = 0; i < 45; i++) {
    if (await portListening(port)) {
      log(`uygulama ${port} portunda yeniden açıldı`)
      return true
    }
    await sleep(1000)
  }
  log(`uygulama ${port} portunda açılamadı`)
  return false
}

function readProjectFromConfig() {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(toolRoot, 'config.json'), 'utf8'))
    return String(cfg.projectPath || '')
  } catch {
    return ''
  }
}

async function recoverTunnel(reason) {
  if (!acquireRecoverLock()) {
    log('başka bir kurtarma sürüyor, atlanıyor')
    return false
  }
  try {
    log(`tünel yeniden açılıyor: ${reason}`)
    killTunnel()
    try {
      fs.rmSync(TUNNEL_LOG, { force: true })
      fs.rmSync(TUNNEL_OUT_LOG, { force: true })
      fs.rmSync(URL_FILE, { force: true })
    } catch {
      /* ignore */
    }
    const bin = findCloudflared()
    if (!bin) {
      log('cloudflared bulunamadı')
      return false
    }
    const pid = startCloudflared(bin, readPort())
    if (!pid) {
      log('cloudflared süreci başlatılamadı')
      return false
    }
    writeText(PID_FILE, String(pid))
    const url = await waitForUrl(60000)
    if (!url) {
      log('yeni tünel adresi oluşmadı')
      return false
    }
    writeText(URL_FILE, url)
    await waitForPublic(url, 120000)
    if (publishToFleet(url)) publishedUrl = url
    notifyNewLink(url)
    log(`yeni yayın adresi: ${url}`)
    return true
  } finally {
    releaseRecoverLock()
  }
}

async function main() {
  fs.mkdirSync(STATE, { recursive: true })

  if (flag('--check')) {
    const url = readText(URL_FILE)
    const health = await checkHealth(url)
    console.log(JSON.stringify(health, null, 2))
    return 0
  }

  const running = readPid(WATCHDOG_PID_FILE)
  if (running && running !== process.pid && pidAlive(running)) {
    console.log(`başka bir gözcü çalışıyor (pid ${running})`)
    return 0
  }
  writeText(WATCHDOG_PID_FILE, String(process.pid))

  log(`izleme başladı (pid ${process.pid}, aralık ${CHECK_MS}ms)`)
  let fails = 0
  let graceUntil = Date.now() + GRACE_MS
  let sawDnsOk = false
  let nxStreak = 0
  let knownUrl = ''
  while (true) {
    await sleep(CHECK_MS)
    if (fs.existsSync(MANUAL_FILE)) {
      log('tünel elle durduruldu, izleme bitti')
      break
    }
    const url = readText(URL_FILE)
    const pid = readPid()
    const procAlive = pidAlive(pid)
    if (!url && !procAlive) {
      log('aktif tünel yok, izleme bitti')
      break
    }
    if (url !== knownUrl) {
      knownUrl = url
      sawDnsOk = false
      nxStreak = 0
    }
    const logUrl = urlFromLogs()
    if (logUrl && logUrl !== url) {
      // Only adopt a log entry that already resolves publicly, otherwise an
      // old address from the log file could be published again.
      const probe = await resolvePublic(hostOf(logUrl))
      if (probe.state === 'ok') {
        log(`yeni adres bulundu: ${logUrl}`)
        writeText(URL_FILE, logUrl)
        if (publishToFleet(logUrl)) publishedUrl = logUrl
        notifyNewLink(logUrl)
        knownUrl = logUrl
        sawDnsOk = false
        nxStreak = 0
      }
    }
    if (Date.now() < graceUntil) {
      fails = 0
      continue
    }
    const health = await checkHealth(knownUrl || url)
    if (health.dns === 'ok') sawDnsOk = true
    const liveUrl = knownUrl || url
    if (
      liveUrl &&
      liveUrl !== publishedUrl &&
      health.procAlive &&
      health.dns === 'ok' &&
      Date.now() >= publishRetryAt
    ) {
      // Only an address that already resolves publicly goes into the fleet
      // record, so other devices never adopt a link that fails with NXDOMAIN.
      if (publishToFleet(liveUrl)) {
        publishedUrl = liveUrl
      } else {
        publishRetryAt = Date.now() + 60000
      }
    }
    if (health.dns === 'nx') nxStreak += 1
    else nxStreak = 0
    let action = ''
    if (!health.procAlive) {
      action = 'tünel süreci çalışmıyor'
    } else if (health.dns === 'nx') {
      action = 'adres DNS kaydı silinmiş (NXDOMAIN)'
    } else if (!health.http.ok && health.dns === 'ok' && !health.originUp) {
      action = 'yerel uygulama yanıt vermiyor'
    } else if (!health.http.ok) {
      action = `yayın adresi yanıt vermiyor (${health.http.status || health.http.error || '000'})`
    }
    if (!action) {
      if (fails > 0) log('yayın adresi yeniden sağlıklı')
      fails = 0
      continue
    }
    fails += 1
    log(`sorun: ${action} (${fails}/${MAX_FAILS})`)
    const fatal = !health.procAlive || (nxStreak >= 2 && sawDnsOk)
    if (!fatal && fails < MAX_FAILS) continue
    if (action.includes('yerel uygulama')) {
      const ok = await ensureOrigin()
      if (ok) {
        fails = 0
        continue
      }
    }
    const recovered = await recoverTunnel(action)
    fails = 0
    nxStreak = 0
    graceUntil = Date.now() + GRACE_MS
    if (recovered) continue
  }
  return 0
}

function cleanup() {
  const current = readText(WATCHDOG_PID_FILE)
  if (!current || Number(current) === process.pid) {
    try {
      fs.rmSync(WATCHDOG_PID_FILE, { force: true })
    } catch {
      /* ignore */
    }
  }
}

process.on('SIGTERM', () => {
  cleanup()
  process.exit(0)
})
process.on('SIGINT', () => {
  cleanup()
  process.exit(0)
})
process.on('unhandledRejection', (err) => {
  log(`beklenmeyen hata: ${(err && err.message) || err}`)
})

main()
  .then((code) => {
    cleanup()
    process.exitCode = code || 0
  })
  .catch((err) => {
    log(`izleme durdu: ${(err && err.message) || err}`)
    cleanup()
    process.exitCode = 1
  })
