import { execFileSync, spawn, spawnSync } from 'child_process'
import crypto from 'crypto'
import fs from 'fs'
import os from 'os'
import path from 'path'

const REPO = process.env.DT_TOOL_REPO || 'hayripenah/Duendee-Tunnel-Tool'
const BRANCH = 'fleet'
const FILE = 'active.json'
const STARTING_MS = 180000
const FRESH_MS = 720000
const POLL_MS = 10000
const KEEPALIVE_MS = 240000
const URL_CHECK_MS = 60000
const URL_MISS_LIMIT = 2
const FOREIGN_WAIT_MS = 90000

function arg(name) {
  const i = process.argv.indexOf(name)
  if (i < 0 || i + 1 >= process.argv.length) return ''
  return process.argv[i + 1]
}

function stateDir(root) {
  const dir = path.join(root, '.tunnelstate')
  fs.mkdirSync(dir, { recursive: true })
  return dir
}

function ownerId(root) {
  const file = path.join(stateDir(root), 'fleet-owner')
  if (fs.existsSync(file)) {
    const id = fs.readFileSync(file, 'utf8').trim()
    if (id) return id
  }
  const id = `${os.hostname()}-${crypto.randomBytes(4).toString('hex')}`
  fs.writeFileSync(file, id)
  return id
}

function findExe(name) {
  const exts = process.platform === 'win32' ? ['.cmd', '.exe', ''] : ['']
  const dirs = (process.env.PATH || '').split(path.delimiter)
  if (process.platform !== 'win32') dirs.unshift(path.join(os.homedir(), '.local', 'bin'))
  const localGh = process.env.LOCALAPPDATA && path.join(process.env.LOCALAPPDATA, 'DuendeeTunnel', 'gh')
  if (localGh && fs.existsSync(localGh)) {
    const stack = [localGh]
    while (stack.length) {
      const dir = stack.pop()
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, ent.name)
        if (ent.isDirectory()) stack.push(full)
        else if (exts.some((ext) => ent.name.toLowerCase() === `${name}${ext}`.toLowerCase())) return full
      }
    }
  }
  for (const dir of dirs) {
    if (!dir) continue
    for (const ext of exts) {
      const full = path.join(dir, name + ext)
      if (fs.existsSync(full)) return full
    }
  }
  return ''
}

function ghToken(interactive) {
  const envTok = (process.env.GH_TOKEN || process.env.GITHUB_TOKEN || '').trim()
  if (envTok) return envTok
  const gh = findExe('gh')
  if (!gh) {
    if (interactive) {
      throw new Error(
        'Filo için GitHub CLI yok. Yerel tünel yine de açılabilir. Kurulum: duendee-tunnel doctor — sonra gh auth login'
      )
    }
    return ''
  }
  const read = () => {
    const out = spawnSync(gh, ['auth', 'token'], { encoding: 'utf8' })
    return out.status === 0 ? String(out.stdout || '').trim() : ''
  }
  let token = read()
  if (!token && interactive) {
    const login = spawnSync(gh, ['auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web'], {
      stdio: 'inherit',
    })
    if (login.status !== 0) {
      throw new Error(
        'Filo için GitHub girişi tamamlanmadı. Yerel tünel çalışır; filo/private: gh auth login veya GH_TOKEN'
      )
    }
    token = read()
  }
  if (!token && interactive) {
    throw new Error(
      'Filo için GitHub girişi yok. Yerel tünel çalışır; filo/private clone: gh auth login veya GH_TOKEN'
    )
  }
  return token
}

async function api(token, method, apiPath, body) {
  const res = await fetch(`https://api.github.com${apiPath}`, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${token}`,
      'User-Agent': 'DuendeeTunnelTool',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  })
  if (res.status === 404) return null
  const text = await res.text()
  let data = null
  if (text) {
    try { data = JSON.parse(text) } catch { data = { message: text } }
  }
  if (!res.ok) {
    const err = new Error((data && data.message) || `GitHub ${res.status}`)
    err.status = res.status
    throw err
  }
  return data
}

async function ensureBranch(token) {
  const existing = await api(token, 'GET', `/repos/${REPO}/git/ref/heads/${BRANCH}`)
  if (existing) return
  const main = await api(token, 'GET', `/repos/${REPO}/git/ref/heads/main`)
  if (!main || !main.object) throw new Error('main dalı okunamadı')
  try {
    await api(token, 'POST', `/repos/${REPO}/git/refs`, {
      ref: `refs/heads/${BRANCH}`,
      sha: main.object.sha,
    })
  } catch (err) {
    if (err.status !== 422) throw err
  }
}

async function readRec(token) {
  const data = await api(token, 'GET', `/repos/${REPO}/contents/${FILE}?ref=${BRANCH}&t=${Date.now()}`)
  if (!data || !data.content) return null
  const rec = JSON.parse(Buffer.from(data.content, 'base64').toString('utf8'))
  rec.sha = data.sha
  return rec
}

async function writeRec(token, rec, sha) {
  const payload = {
    url: rec.url || '',
    owner: rec.owner || '',
    host: rec.host || '',
    state: rec.state || 'idle',
    updatedAt: rec.updatedAt || Date.now(),
  }
  const body = {
    message: 'tunnel',
    content: Buffer.from(JSON.stringify(payload)).toString('base64'),
    branch: BRANCH,
  }
  if (sha) body.sha = sha
  await api(token, 'PUT', `/repos/${REPO}/contents/${FILE}`, body)
}

async function httpOk(url) {
  const probe = await probeUrl(url)
  return probe.ok
}

/**
 * Probes a published tunnel link.
 *
 * kind:
 *   'ok'       - the link answers with a 2xx/3xx status
 *   'dns'      - the hostname does not exist any more (NXDOMAIN). This is what
 *                other devices see after Cloudflare drops a quick tunnel.
 *   'server'   - Cloudflare answered, but the tunnel itself is gone (530/1033)
 *   'network'  - temporary network problem, the link may still be fine
 */
async function probeUrl(url) {
  if (!url || !/^https:\/\//i.test(url)) return { ok: false, kind: 'invalid', status: 0 }
  try {
    const res = await fetch(url, { redirect: 'follow', signal: AbortSignal.timeout(8000) })
    const status = res.status
    if (status >= 200 && status < 400) return { ok: true, kind: 'ok', status }
    if (status === 530 || status === 1033) return { ok: false, kind: 'server', status }
    return { ok: false, kind: 'network', status }
  } catch (err) {
    const cause = String((err && err.cause && err.cause.code) || '')
    const message = String(((err && err.cause && err.cause.message) || (err && err.message) || err))
    if (cause === 'ENOTFOUND' || cause === 'ENODATA' || /ENOTFOUND|ENODATA/i.test(message)) {
      return { ok: false, kind: 'dns', status: 0 }
    }
    return { ok: false, kind: 'network', status: 0 }
  }
}

/** A link whose hostname vanished from DNS must never be handed to another device. */
function isDeadLink(probe) {
  return probe.kind === 'dns' || probe.kind === 'server'
}

function watchdogAlive(root) {
  const file = path.join(stateDir(root), 'watchdog.pid')
  if (!fs.existsSync(file)) return false
  const pid = Number(fs.readFileSync(file, 'utf8').trim())
  if (!Number.isInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (err) {
    return err.code === 'EPERM'
  }
}

function age(rec) {
  return Date.now() - Number(rec && rec.updatedAt || 0)
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function tasklistText(args) {
  const out = spawnSync('tasklist', args, { encoding: 'buffer' })
  const buf = Buffer.isBuffer(out.stdout) ? out.stdout : Buffer.alloc(0)
  if (buf.length >= 2 && buf[1] === 0) return buf.toString('utf16le')
  return buf.toString('utf8')
}

function pidIsCloudflared(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false
  if (process.platform === 'win32') {
    const text = tasklistText(['/FI', `PID eq ${pid}`, '/NH'])
    return /cloudflared\.exe/i.test(text)
  }
  try {
    const comm = fs.readFileSync(`/proc/${pid}/comm`, 'utf8').replace(/\0/g, '').trim()
    return comm === 'cloudflared'
  } catch {
    return false
  }
}

function fmPort(root) {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(root, 'config.json'), 'utf8'))
    const port = Number(cfg.port)
    if (Number.isInteger(port) && port > 0) return port
  } catch {
    /* ignore */
  }
  return 8080
}

function pathBoundaryMatch(blob, needle) {
  if (!blob || !needle) return false
  const n = String(needle).replace(/[\\/]+$/, '')
  if (!n) return false
  const lower = String(blob)
  let start = 0
  const hay = lower
  const want = n
  while (start < hay.length) {
    const idx = hay.toLowerCase().indexOf(want.toLowerCase(), start)
    if (idx < 0) return false
    const after = idx + want.length
    if (after >= hay.length) return true
    const ch = hay[after]
    if (ch === '\\' || ch === '/' || ch === '"' || ch === "'" || /\s/.test(ch)) return true
    // Reject ".tunnelstate" matching inside ".tunnelstate-duendee"
    start = idx + 1
  }
  return false
}

function cmdlineForPid(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return ''
  if (process.platform === 'win32') {
    try {
      const out = spawnSync(
        'powershell.exe',
        ['-NoProfile', '-Command', `(Get-CimInstance Win32_Process -Filter "ProcessId=${pid}").CommandLine`],
        { encoding: 'utf8', windowsHide: true }
      )
      return String(out.stdout || '').trim()
    } catch {
      return ''
    }
  }
  try {
    return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').replace(/\0/g, ' ')
  } catch {
    return ''
  }
}

function listCloudflaredPids() {
  const pids = []
  if (process.platform === 'win32') {
    const text = tasklistText(['/FI', 'IMAGENAME eq cloudflared.exe', '/NH'])
    for (const line of String(text || '').split(/\r?\n/)) {
      const m = line.match(/cloudflared\.exe\s+(\d+)/i)
      if (m) pids.push(Number(m[1]))
    }
    return pids
  }
  try {
    for (const ent of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(ent)) continue
      try {
        const comm = fs.readFileSync(`/proc/${ent}/comm`, 'utf8').replace(/\0/g, '').trim()
        if (comm === 'cloudflared') pids.push(Number(ent))
      } catch {
        /* ignore */
      }
    }
  } catch {
    /* ignore */
  }
  return pids
}

function cloudflaredBelongsToFm(root, pid) {
  const cmd = cmdlineForPid(pid)
  if (!cmd) return false
  const port = fmPort(root)
  if (cmd.includes(`127.0.0.1:${port}`)) return true
  const dir = stateDir(root)
  if (pathBoundaryMatch(cmd, dir)) return true
  if (pathBoundaryMatch(cmd, path.join(dir, 'tunnel.log'))) return true
  if (pathBoundaryMatch(cmd, path.join(dir, 'tunnel.out.log'))) return true
  return false
}

function tunnelProcAlive(dir) {
  const pidFile = path.join(dir, 'tunnel.pid')
  if (fs.existsSync(pidFile)) {
    const pid = Number(fs.readFileSync(pidFile, 'utf8').trim())
    if (Number.isInteger(pid) && pid > 0) {
      try {
        process.kill(pid, 0)
        return true
      } catch (err) {
        if (err && err.code === 'EPERM') return true
      }
      if (pidIsCloudflared(pid)) return true
    }
  }
  // Never treat Duendee (main) cloudflared as the FM fleet tunnel.
  return false
}

function killPid(pid) {
  if (!pid || pid <= 0) return
  if (process.platform === 'win32') {
    spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' })
    return
  }
  try { process.kill(-pid, 'SIGTERM') } catch { try { process.kill(pid, 'SIGTERM') } catch { /* gone */ } }
  try { process.kill(-pid, 'SIGKILL') } catch { try { process.kill(pid, 'SIGKILL') } catch { /* gone */ } }
}

function stopLocalTunnel(root) {
  // Fleet is DuendeeFM-only. Never taskkill/pkill every cloudflared — that
  // used to tear down a concurrent Duendee (main) tunnel on the same machine.
  const dir = stateDir(root)
  for (const name of ['tunnel.pid', 'server.pid', 'watchdog.pid']) {
    const file = path.join(dir, name)
    if (!fs.existsSync(file)) continue
    const pid = Number(fs.readFileSync(file, 'utf8').trim())
    killPid(pid)
    fs.rmSync(file, { force: true })
  }
  fs.rmSync(path.join(dir, 'tunnel.url'), { force: true })
  for (const pid of listCloudflaredPids()) {
    if (cloudflaredBelongsToFm(root, pid)) killPid(pid)
  }
}

async function classify(rec, me) {
  if (!rec || !rec.owner || rec.state === 'idle') return 'free'
  if (rec.state === 'stop' && age(rec) < 90000) return rec.owner === me ? 'self' : 'wait'
  const probe = rec.url ? await probeUrl(rec.url) : { ok: false, kind: 'invalid', status: 0 }
  const dead = isDeadLink(probe)
  const fresh = age(rec) < FRESH_MS
  if (rec.owner === me) {
    if (rec.url && (probe.ok || (fresh && !dead))) return 'self'
    return 'free'
  }
  if (rec.state === 'starting' && !rec.url && age(rec) < STARTING_MS) return 'wait'
  if (rec.url && (probe.ok || (fresh && !dead))) return 'foreign'
  return 'free'
}

function stopWatchdog(root) {
  const file = path.join(stateDir(root), 'watchdog.pid')
  if (!fs.existsSync(file)) return
  const pid = Number(fs.readFileSync(file, 'utf8').trim())
  fs.rmSync(file, { force: true })
  if (pid > 0) {
    try { process.kill(pid, 'SIGTERM') } catch { /* already gone */ }
  }
}

function stopHeartbeat(root) {
  const dir = stateDir(root)
  const flag = path.join(dir, 'fleet-heartbeat.on')
  const pidFile = path.join(dir, 'fleet-heartbeat.pid')
  fs.rmSync(flag, { force: true })
  if (!fs.existsSync(pidFile)) return
  const pid = Number(fs.readFileSync(pidFile, 'utf8').trim())
  fs.rmSync(pidFile, { force: true })
  if (pid > 0) {
    try { process.kill(pid) } catch { /* already gone */ }
  }
}

async function withRecord(token, mutate) {
  await ensureBranch(token)
  let last = null
  for (let i = 0; i < 6; i++) {
    const cur = await readRec(token)
    const next = await mutate(cur)
    if (!next) return cur
    try {
      await writeRec(token, next, cur && cur.sha)
      return next
    } catch (err) {
      last = err
      if (err.status !== 409 && err.status !== 422) throw err
    }
  }
  throw last || new Error('kayıt yazılamadı')
}

async function begin(root) {
  const token = ghToken(true)
  const me = ownerId(root)
  const localAlive = arg('--local-alive') === '1'
  let localUrl = arg('--local-url').trim()
  if (localUrl === '-') localUrl = ''
  await ensureBranch(token)
  let rec = await readRec(token)
  let kind = await classify(rec, me)
  let waited = false
  const waitUntil = Date.now() + STARTING_MS
  while (kind === 'wait' && Date.now() < waitUntil) {
    waited = true
    await new Promise((r) => setTimeout(r, 2000))
    rec = await readRec(token)
    kind = await classify(rec, me)
  }
  if (kind === 'wait') {
    waited = true
    kind = 'free'
  }
  if (kind === 'foreign') {
    if (rec && rec.url && await httpOk(rec.url)) {
      process.stdout.write(`adopt\t${rec.url}`)
      return
    }
    const foreignUntil = Date.now() + FOREIGN_WAIT_MS
    while (Date.now() < foreignUntil) {
      await sleep(POLL_MS)
      rec = await readRec(token)
      kind = await classify(rec, me)
      if (kind !== 'foreign') break
      if (rec && rec.url && await httpOk(rec.url)) {
        process.stdout.write(`adopt\t${rec.url}`)
        return
      }
    }
    if (kind === 'wait') {
      const againUntil = Date.now() + STARTING_MS
      while (kind === 'wait' && Date.now() < againUntil) {
        waited = true
        await sleep(2000)
        rec = await readRec(token)
        kind = await classify(rec, me)
      }
      if (kind === 'wait') {
        waited = true
        kind = 'free'
      }
    }
    if (kind === 'foreign') {
      throw new Error('Aktif tünel toparlanıyor, kısa süre sonra yeniden deneyin')
    }
  }
  if (kind === 'self' && !localAlive) {
    if (rec && rec.url && await httpOk(rec.url)) {
      process.stdout.write(`adopt\t${rec.url}`)
      return
    }
    kind = 'free'
  }
  if (localAlive || kind === 'self') {
    const url = localUrl || (rec && rec.url) || ''
    if (url) {
      const saved = await withRecord(token, async (cur) => {
        const curKind = await classify(cur, me)
        if (curKind === 'foreign') return null
        return { url, owner: me, host: os.hostname(), state: 'live', updatedAt: Date.now() }
      })
      if (saved && saved.owner && saved.owner !== me && saved.url) {
        process.stdout.write(`adopt\t${saved.url}`)
        return
      }
    }
    process.stdout.write(url ? `keep\t${url}` : 'keep')
    return
  }
  const claimed = await withRecord(token, async (cur) => {
    const curKind = await classify(cur, me)
    const abandoned = waited && cur && cur.state === 'starting' && !cur.url
    const deadSelf = curKind === 'self' && !localAlive && !(cur && cur.url && await httpOk(cur.url))
    if (!abandoned && !deadSelf && (curKind === 'foreign' || curKind === 'wait' || curKind === 'self')) return null
    return { url: '', owner: me, host: os.hostname(), state: 'starting', updatedAt: Date.now() }
  })
  if (!claimed || claimed.owner !== me || claimed.state !== 'starting') {
    const again = await readRec(token)
    const againKind = await classify(again, me)
    const againUrl = again && again.url
    if (againKind === 'self' && !localAlive && againUrl && !(await httpOk(againUrl))) {
      throw new Error('Aktif tünel kaydı alınamadı')
    }
    if (againKind === 'foreign' && againUrl && !(await httpOk(againUrl))) {
      throw new Error('Aktif tünel toparlanıyor, kısa süre sonra yeniden deneyin')
    }
    if ((againKind === 'foreign' || againKind === 'self') && againUrl) {
      process.stdout.write(`adopt\t${again.url}`)
      return
    }
    throw new Error('Aktif tünel kaydı alınamadı')
  }
  process.stdout.write('own')
}

async function publish(root) {
  const token = ghToken(process.env.DT_FLEET_QUIET !== '1')
  if (!token) return
  const me = ownerId(root)
  const url = arg('--url').trim()
  if (!/^https:\/\//i.test(url)) throw new Error('yayın adresi yok')
  const saved = await withRecord(token, async (cur) => {
    if (cur && cur.owner && cur.owner !== me) {
      const kind = await classify(cur, me)
      if (kind === 'foreign') return null
    }
    return { url, owner: me, host: os.hostname(), state: 'live', updatedAt: Date.now() }
  })
  if (!saved || saved.owner !== me || saved.url !== url) {
    if (process.env.DT_FLEET_QUIET === '1') return
    process.exitCode = 4
    throw new Error('Aktif tünel başka kopyada')
  }
}

async function release(root) {
  const token = ghToken(false)
  if (!token) return
  const me = ownerId(root)
  stopHeartbeat(root)
  await ensureBranch(token).catch(() => {})
  await withRecord(token, async (cur) => {
    if (!cur || cur.owner !== me) return null
    return { url: '', owner: '', host: '', state: 'idle', updatedAt: Date.now() }
  }).catch(() => {})
}

async function requestStop(root) {
  const token = ghToken(true)
  const me = ownerId(root)
  await ensureBranch(token)
  const cur = await readRec(token)
  if (!cur || !cur.owner || cur.state === 'idle') {
    process.stdout.write('idle')
    return
  }
  if (cur.owner === me) {
    process.stdout.write('self')
    return
  }
  await withRecord(token, async (rec) => {
    if (!rec || !rec.owner || rec.owner === me || rec.state === 'idle') return null
    return {
      url: rec.url || '',
      owner: rec.owner,
      host: rec.host || '',
      state: 'stop',
      updatedAt: Date.now(),
    }
  })
  const deadline = Date.now() + 45000
  while (Date.now() < deadline) {
    const rec = await readRec(token)
    if (!rec || !rec.owner || rec.state === 'idle') {
      process.stdout.write('stopped')
      return
    }
    await new Promise((r) => setTimeout(r, 2000))
  }
  const rec = await readRec(token)
  if (!rec || !rec.url || !(await httpOk(rec.url))) {
    process.stdout.write('stopped')
    return
  }
  throw new Error('Tünel servisi kapatılamadı')
}

async function lookup(root) {
  const token = ghToken(false)
  if (!token) process.exit(2)
  await ensureBranch(token).catch(() => {})
  const rec = await readRec(token)
  if (rec && rec.state === 'live' && rec.url && await httpOk(rec.url)) {
    process.stdout.write(rec.url)
    return
  }
  process.exit(2)
}

async function show(root) {
  const token = ghToken(false)
  if (!token) process.exit(2)
  const me = ownerId(root)
  await ensureBranch(token).catch(() => {})
  const rec = await readRec(token)
  const kind = await classify(rec, me)
  if ((kind === 'foreign' || kind === 'self') && rec && rec.url) {
    process.stdout.write(rec.url)
    return
  }
  process.exit(2)
}

async function clearRecord(root) {
  const token = ghToken(true)
  if (!token) return
  stopHeartbeat(root)
  await ensureBranch(token).catch(() => {})
  await withRecord(token, async () => (
    { url: '', owner: '', host: '', state: 'idle', updatedAt: Date.now() }
  )).catch(() => {})
}

async function role(root) {
  const token = ghToken(false)
  if (!token) {
    process.stdout.write('none')
    return
  }
  const me = ownerId(root)
  const rec = await readRec(token).catch(() => null)
  const kind = rec ? await classify(rec, me) : 'free'
  if (kind === 'self') process.stdout.write('self')
  else if (kind === 'foreign' || kind === 'wait') process.stdout.write('other')
  else process.stdout.write('none')
}

function spawnRecover(root) {
  const dir = stateDir(root)
  const manual = path.join(dir, 'manual-stop')
  if (fs.existsSync(manual)) return
  const lock = path.join(dir, 'recover.lock')
  if (fs.existsSync(lock)) {
    const ageMs = Date.now() - fs.statSync(lock).mtimeMs
    if (ageMs < 60000) return
  }
  fs.writeFileSync(lock, String(Date.now()))
  if (process.platform === 'win32') {
    const ps1 = path.join(root, 'windows', 'duendee-tunnel-tool.ps1')
    const child = spawn('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', ps1, 'recover-tunnel',
    ], { detached: true, stdio: 'ignore', windowsHide: true })
    child.unref()
    return
  }
  const sh = path.join(root, 'linux', 'duendee-tunnel-tool.sh')
  const child = spawn('bash', [sh, 'recover-tunnel'], { detached: true, stdio: 'ignore' })
  child.unref()
}

async function writeStarting(token, me) {
  for (let i = 0; i < 4; i++) {
    const cur = await readRec(token).catch(() => null)
    if (cur && cur.owner && cur.owner !== me) {
      await sleep(1000 * (i + 1))
      continue
    }
    try {
      await writeRec(token, {
        url: '',
        owner: me,
        host: os.hostname(),
        state: 'starting',
        updatedAt: Date.now(),
      }, cur && cur.sha)
      return true
    } catch {
      await sleep(1000 * (i + 1))
    }
  }
  return false
}

async function recoverFromCrash(token, me, root, dir) {
  const manual = path.join(dir, 'manual-stop')
  if (fs.existsSync(manual)) {
    stopWatchdog(root)
    stopLocalTunnel(root)
    const cur = await readRec(token).catch(() => null)
    if (cur && cur.owner === me && cur.sha) {
      await writeRec(token, { url: '', owner: '', host: '', state: 'idle', updatedAt: Date.now() }, cur.sha).catch(() => {})
    }
    return false
  }
  if (watchdogAlive(root)) {
    // The local watchdog owns the tunnel lifecycle: it restarts cloudflared,
    // publishes the new link and notifies the users on its own.
    return true
  }
  await writeStarting(token, me)
  stopLocalTunnel(root)
  fs.rmSync(path.join(dir, 'fleet-heartbeat.pid'), { force: true })
  spawnRecover(root)
  return false
}

async function heartbeat(root) {
  const token = ghToken(false)
  if (!token) return
  const me = ownerId(root)
  const dir = stateDir(root)
  const flag = path.join(dir, 'fleet-heartbeat.on')
  const manual = path.join(dir, 'manual-stop')
  fs.writeFileSync(path.join(dir, 'fleet-heartbeat.pid'), String(process.pid))
  if (!fs.existsSync(flag)) fs.writeFileSync(flag, '1')
  let lastKeep = 0
  let primed = false
  let urlMisses = 0
  let lastUrlCheck = 0
  let seenUrl = null
  let otherOwnerStreak = 0
  while (fs.existsSync(flag)) {
    try {
      if (fs.existsSync(manual)) {
        stopWatchdog(root)
        stopLocalTunnel(root)
        const cur = await readRec(token).catch(() => null)
        if (cur && cur.owner === me && cur.sha) {
          await writeRec(token, { url: '', owner: '', host: '', state: 'idle', updatedAt: Date.now() }, cur.sha).catch(() => {})
        }
        break
      }
      const cur = await readRec(token)
      if (!cur || !cur.owner) {
        otherOwnerStreak = 0
      } else if (cur.owner !== me) {
        otherOwnerStreak++
        if (otherOwnerStreak >= 2) break
      } else {
        otherOwnerStreak = 0
        if (cur.state === 'stop') {
          stopLocalTunnel(root)
          await writeRec(token, { url: '', owner: '', host: '', state: 'idle', updatedAt: Date.now() }, cur.sha).catch(() => {})
          break
        }
        if (cur.state === 'starting') {
          if (!cur.url && age(cur) > STARTING_MS) {
            await writeRec(token, { url: '', owner: '', host: '', state: 'idle', updatedAt: Date.now() }, cur.sha).catch(() => {})
            break
          }
        } else if (cur.state === 'live') {
          if (!primed) {
            lastKeep = Number(cur.updatedAt) || 0
            primed = true
          }
          if (cur.url !== seenUrl) {
            seenUrl = cur.url || ''
            urlMisses = 0
            lastUrlCheck = 0
          }
          const procUp = tunnelProcAlive(dir)
          if (cur.url && Date.now() - lastUrlCheck >= URL_CHECK_MS) {
            lastUrlCheck = Date.now()
            if (await httpOk(cur.url)) urlMisses = 0
            else urlMisses++
          }
          if (!procUp || urlMisses >= URL_MISS_LIMIT) {
            const handled = await recoverFromCrash(token, me, root, dir)
            if (!handled) break
            // The watchdog is recovering on its own. Keep polling so the
            // keepalive continues once the new link is published.
            urlMisses = 0
            lastUrlCheck = 0
          }
          if (Date.now() - lastKeep >= KEEPALIVE_MS) {
            await writeRec(token, {
              url: cur.url || '',
              owner: me,
              host: cur.host || os.hostname(),
              state: 'live',
              updatedAt: Date.now(),
            }, cur.sha)
            lastKeep = Date.now()
          }
        }
      }
    } catch {
      /* next tick */
    }
    await sleep(POLL_MS)
  }
}

function git(root, args) {
  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0' }
  const gh = findExe('gh')
  const prefix = []
  if (gh) {
    const auth = spawnSync(gh, ['auth', 'status'], { encoding: 'utf8' })
    if (auth.status === 0) prefix.push('-c', 'credential.helper=!gh auth git-credential')
  }
  return execFileSync('git', [...prefix, '-C', root, ...args], { encoding: 'utf8', env })
}

async function update(root) {
  if (process.env.DT_SKIP_UPDATE === '1') return
  if (fs.existsSync(path.join(root, '.git'))) {
    try {
      const before = git(root, ['rev-parse', 'HEAD']).trim()
      try {
        git(root, ['fetch', '--depth', '1', '--quiet', 'origin', 'main'])
      } catch {
        git(root, ['fetch', '--quiet', 'origin', 'main'])
      }
      const remote = git(root, ['rev-parse', 'origin/main']).trim()
      if (!remote || remote === before) return
      git(root, ['reset', '--hard', 'origin/main'])
      process.stderr.write('Tool güncellendi, yeniden açılıyor.\n')
      process.exit(20)
    } catch {
      process.stderr.write('Tool güncellenemedi.\n')
      return
    }
  }
  try {
    await updateFromArchive(root)
  } catch {
    process.stderr.write('Tool güncellenemedi.\n')
  }
}

async function updateFromArchive(root) {
  const res = await fetch(`https://api.github.com/repos/${REPO}/commits/main`, {
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'DuendeeTunnelTool' },
    signal: AbortSignal.timeout(20000),
  })
  if (!res.ok) return
  const meta = await res.json()
  const sha = meta && meta.sha
  if (!sha) return
  const marker = path.join(stateDir(root), 'tool.sha')
  const local = fs.existsSync(marker) ? fs.readFileSync(marker, 'utf8').trim() : ''
  if (local === sha) return
  const pack = await fetch(`https://codeload.github.com/${REPO}/tar.gz/refs/heads/main`, {
    headers: { 'User-Agent': 'DuendeeTunnelTool' },
    signal: AbortSignal.timeout(60000),
  })
  if (!pack.ok) return
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'duendee-tool-'))
  const tgz = path.join(tmp, 'src.tgz')
  fs.writeFileSync(tgz, Buffer.from(await pack.arrayBuffer()))
  execFileSync('tar', ['-xzf', tgz, '-C', tmp], { stdio: 'ignore' })
  const extracted = fs.readdirSync(tmp, { withFileTypes: true })
    .filter((ent) => ent.isDirectory())
    .map((ent) => path.join(tmp, ent.name))[0]
  if (!extracted) return
  const keep = new Set([
    'config.json',
    '.whatsapp-session',
    '.tunnelstate',
    '.tunnelstate-duendee',
    'node_modules',
    '.git',
  ])
  const oldLock = path.join(root, 'package-lock.json')
  const newLock = path.join(extracted, 'package-lock.json')
  const oldHash = fs.existsSync(oldLock) ? fs.readFileSync(oldLock) : Buffer.alloc(0)
  const newHash = fs.existsSync(newLock) ? fs.readFileSync(newLock) : Buffer.alloc(0)
  for (const name of fs.readdirSync(root)) {
    if (keep.has(name)) continue
    fs.rmSync(path.join(root, name), { recursive: true, force: true })
  }
  for (const name of fs.readdirSync(extracted)) {
    if (keep.has(name)) continue
    fs.cpSync(path.join(extracted, name), path.join(root, name), { recursive: true })
  }
  fs.writeFileSync(marker, sha)
  if (!oldHash.equals(newHash)) {
    const npm = findExe('npm')
    if (npm) spawnSync(npm, ['install', '--omit=dev'], { cwd: root, stdio: 'inherit' })
  }
  fs.rmSync(tmp, { recursive: true, force: true })
  process.stderr.write('Tool güncellendi, yeniden açılıyor.\n')
  process.exit(20)
}

const root = path.resolve(arg('--root') || path.join(path.dirname(new URL(import.meta.url).pathname), '..'))
const cmd = process.argv[2] || ''

const run = {
  update,
  begin,
  publish,
  release,
  lookup,
  show,
  clear: clearRecord,
  role,
  heartbeat,
  stop: requestStop,
}[cmd]

if (!run) {
  process.stderr.write('fleet komutu yok\n')
  process.exit(1)
}

run(root).catch((err) => {
  process.stderr.write(`${err.message || err}\n`)
  if (!process.exitCode) process.exitCode = 1
  process.exit(process.exitCode)
})
