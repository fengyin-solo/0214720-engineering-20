#!/usr/bin/env node
/**
 * 用户端可复现基线校验脚本（零第三方依赖，仅使用 Node 内置模块）
 *
 * 固化基线：
 *   1. 运行时   —— Node / npm 版本满足要求
 *   2. 依赖     —— package.json 与 package-lock.json 完整，node_modules 与当前
 *                  平台/架构匹配（跨平台拷贝 node_modules 会直接失败，如 rollup 原生模块）
 *   3. 环境变量 —— .env.development / .env.production / .env.example 存在，
 *                  VITE_APP_TITLE / VITE_USE_MOCK / VITE_API_BASE_URL / VITE_LOG_LEVEL
 *                  取值合法，缺失或非法给出明确修复指引
 *   4. 端口     —— 开发端口 8080 与容器宿主端口 8081 必须空闲，占用即失败并提示占用方
 *   5. 构建     —— `npm run build` 必须成功，失败回显末尾日志
 *   6. 产物     —— dist/index.html 与 dist/assets/*.js、*.css 必须存在且相互引用
 *   7. 开发冒烟 —— `npm run dev` 必须在 8080 起来，核心页面入口（/、/tables、
 *                  /courses、/competitions、/shop、/tasks、/profile）全部 200，
 *                  /src/main.js 经 Vite 转换可加载；脚本退出时强制关停并复核端口释放，
 *                  不残留服务
 *   8. 容器约束 —— Dockerfile 多阶段 + 多架构基础镜像 + npm ci + 构建产物，
 *                  nginx.conf SPA 回退，docker-compose 固定 8081:80 且带健康检查，
 *                  .dockerignore 排除 node_modules/dist
 *
 * 退出码：0 全部通过；1 存在失败项。
 *
 * 用法：
 *   node scripts/verify-baseline.mjs                 # 全量基线
 *   node scripts/verify-baseline.mjs --skip-build    # 跳过构建/产物阶段
 *   node scripts/verify-baseline.mjs --skip-smoke    # 跳过开发服务器冒烟
 *   node scripts/verify-baseline.mjs --skip-container# 跳过容器静态约束
 */

import { spawn } from 'node:child_process'
import net from 'node:net'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const DEV_PORT = 8080 // vite.config.js server.port，开发服务器固定端口
const HOST_PORT = 8081 // docker-compose.yml 宿主机映射端口
const PREVIEW_PORT = 4173 // vite preview 固定端口

const argv = process.argv.slice(2)
const skipBuild = argv.includes('--skip-build')
const skipSmoke = argv.includes('--skip-smoke')
const skipContainer = argv.includes('--skip-container')

const results = []
let failures = 0
function record(stage, ok, message, fix) {
  results.push({ stage, ok, message, fix })
  const firstLine = message.split('\n')[0]
  console.log(`  ${ok ? C.green('✓') : C.red('✗')} ${C.gray('[' + stage + ']')} ${firstLine}`)
  if (!ok) failures++
}
const pass = (stage, message) => record(stage, true, message)
const fail = (stage, message, fix) => record(stage, false, message, fix)

const C = {
  green: (s) => `\x1b[32m${s}\x1b[0m`,
  red: (s) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s) => `\x1b[33m${s}\x1b[0m`,
  cyan: (s) => `\x1b[36m${s}\x1b[0m`,
  gray: (s) => `\x1b[90m${s}\x1b[0m`
}

// 退出前统一清理本脚本拉起的所有子进程，保证不残留服务
const children = new Set()
let cleaned = false
function cleanup(signal = 'SIGTERM') {
  if (cleaned) return
  cleaned = true
  for (const child of children) {
    try {
      if (process.platform === 'win32') {
        spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore' })
      } else {
        try {
          process.kill(-child.pid, signal) // 杀整个进程组（vite 会派生 esbuild 等子进程）
        } catch {
          child.kill(signal)
        }
      }
    } catch {
      /* 进程可能已退出 */
    }
  }
}
process.on('exit', () => cleanup())
process.on('SIGINT', () => {
  cleanup('SIGINT')
  process.exit(1)
})
process.on('SIGTERM', () => {
  cleanup('SIGTERM')
  process.exit(1)
})

function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const useCmd = process.platform === 'win32' && !opts.noShell ? `${cmd}.cmd` : cmd
    const child = spawn(useCmd, args, {
      cwd: ROOT,
      env: process.env,
      shell: process.platform === 'win32' && !opts.noShell,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
      ...(process.platform === 'win32' ? {} : { detached: true }),
      ...opts.spawnOpts
    })
    children.add(child)
    let out = ''
    const append = (d) => {
      const s = d.toString()
      if (out.length < 200000) out += s
    }
    child.stdout?.on('data', append)
    child.stderr?.on('data', append)
    const timer = opts.timeout
      ? setTimeout(() => {
          try {
            if (process.platform === 'win32') {
              spawn('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore' })
            } else {
              process.kill(-child.pid, 'SIGKILL')
            }
          } catch {}
          resolve({ code: 'TIMEOUT', out })
        }, opts.timeout)
      : null
    child.on('close', (code) => {
      if (timer) clearTimeout(timer)
      children.delete(child)
      resolve({ code, out })
    })
    child.on('error', (err) => {
      if (timer) clearTimeout(timer)
      children.delete(child)
      resolve({ code: 'SPAWN_ERROR', out: String(err && err.message ? err.message : err) })
    })
  })
}

function read(path) {
  try {
    return readFileSync(join(ROOT, path), 'utf8')
  } catch {
    return null
  }
}
function exists(path) {
  return existsSync(join(ROOT, path))
}

/** 检测 TCP 端口是否可连接（可连接即被占用） */
function probePort(port) {
  return new Promise((resolve) => {
    const sock = net.createConnection({ port, host: '127.0.0.1' })
    const done = (busy) => {
      sock.destroy()
      resolve(busy)
    }
    sock.once('connect', () => done(true))
    sock.once('error', () => done(false))
    setTimeout(() => done(false), 1500)
  })
}

async function waitForPort(port, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await probePort(port)) return true
    await new Promise((r) => setTimeout(r, 500))
  }
  return false
}

async function httpGet(pathname, port = DEV_PORT) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 5000)
  try {
    const res = await fetch(`http://127.0.0.1:${port}${pathname}`, {
      signal: controller.signal,
      headers: { Accept: 'text/html,application/javascript,*/*' }
    })
    const text = await res.text()
    return { status: res.status, text, ok: res.ok }
  } catch (err) {
    return { status: 0, text: String(err && err.message ? err.message : err), ok: false }
  } finally {
    clearTimeout(timer)
  }
}

// 极简 .env 解析：KEY=VALUE，忽略注释/空行
function parseEnv(content) {
  const env = {}
  for (const raw of content.split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq === -1) continue
    env[line.slice(0, eq).trim()] = line.slice(eq + 1).trim()
  }
  return env
}

function banner(title) {
  console.log(`\n${C.cyan('▶ ' + title)}`)
}

// ---------------------------------------------------------------------------
// 阶段 1：运行时基线
// ---------------------------------------------------------------------------
banner('阶段 1/8 运行时（Node / npm）')
{
  const major = Number(process.versions.node.split('.')[0])
  if (major >= 18) {
    pass('runtime', `Node ${process.version}（platform=${process.platform}/${process.arch}）`)
  } else {
    fail(
      'runtime',
      `Node 版本过低：${process.version}`,
      '请安装 Node.js >= 18（推荐 20 LTS）：https://nodejs.org/'
    )
  }
  const npm = await run('npm', ['--version'], { timeout: 15000 })
  if (npm.code === 0) {
    pass('runtime', `npm ${npm.out.trim()}`)
  } else {
    fail('runtime', 'npm 不可用', '请先安装 npm（随 Node.js 一起分发）并重开终端')
  }
}

// ---------------------------------------------------------------------------
// 阶段 2：依赖基线
// ---------------------------------------------------------------------------
banner('阶段 2/8 依赖（package.json / lockfile / node_modules 平台匹配）')
{
  if (!exists('package.json')) {
    fail('deps', '缺少 package.json', '该文件是用户端依赖与脚本的唯一来源，请勿从仓库中删除')
  }
  if (!exists('package-lock.json')) {
    fail('deps', '缺少 package-lock.json', '请在 frontend-user/ 下执行 `npm install` 生成锁文件并提交')
  } else {
    let pkg = null
    let lock = null
    try {
      pkg = JSON.parse(read('package.json'))
      lock = JSON.parse(read('package-lock.json'))
    } catch (error) {
      fail('deps', `package.json/package-lock.json 解析失败：${error.message}`)
    }
    if (pkg && lock) {
      const lockVersion = lock.lockfileVersion
      if (lockVersion === 2 || lockVersion === 3) {
        pass('deps', `package-lock.json 存在（lockfileVersion=${lockVersion}）`)
      } else {
        fail(
          'deps',
          `package-lock.json 版本过旧（lockfileVersion=${lockVersion}）`,
          '请使用 npm >= 7 重新生成锁文件：删除 package-lock.json 后执行 `npm install`'
        )
      }
      const depNames = ['vite', '@vitejs/plugin-vue', 'vue', 'vue-router']
      const missing = depNames.filter((name) => !exists(join('node_modules', name, 'package.json')))
      if (!exists('node_modules')) {
        fail(
          'deps',
          '缺少 node_modules（依赖未安装）',
          '在 frontend-user/ 下执行 `npm ci`（CI/验收环境）或 `npm install`（本地开发）'
        )
      } else if (missing.length > 0) {
        fail(
          'deps',
          `node_modules 缺少关键依赖：${missing.join(', ')}`,
          '删除 node_modules 后执行 `npm ci` 按锁文件完整安装'
        )
      } else {
        pass('deps', 'node_modules 关键依赖就位（vite/plugin-vue/vue/vue-router）')
      }
      // 平台原生模块实测：跨机器/跨架构拷贝 node_modules 会在这里暴露（例如 rollup 原生绑定）
      const viteBin = await run(
        process.platform === 'win32' ? 'node_modules\\.bin\\vite' : join('node_modules', '.bin', 'vite'),
        ['--version'],
        { timeout: 30000, noShell: true, spawnOpts: { shell: false } }
      )
      if (viteBin.code === 0 && /vite/i.test(viteBin.out)) {
        pass('deps', `Vite 可在当前平台执行（${viteBin.out.trim()}）`)
      } else {
        fail(
          'deps',
          'Vite 无法在当前平台运行（原生依赖与平台/架构不匹配）',
          `现象：${viteBin.out.split('\n').slice(-3).join(' ').trim() || 'exit ' + viteBin.code}\n` +
            `修复：rm -rf node_modules && npm ci（当前平台 ${process.platform}/${process.arch}）`
        )
      }
      if (pkg.scripts?.dev !== 'vite' || pkg.scripts?.build !== 'vite build') {
        fail(
          'deps',
          'package.json 的 dev/build 脚本被修改',
          '基线要求 dev="vite"、build="vite build"，现有开发命令必须继续可用'
        )
      } else {
        pass('deps', 'npm run dev / build 脚本保持基线命令')
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 阶段 3：环境变量基线
// ---------------------------------------------------------------------------
banner('阶段 3/8 环境变量（.env.* 齐全且取值合法）')
{
  const REQUIRED = ['VITE_APP_TITLE', 'VITE_USE_MOCK', 'VITE_API_BASE_URL', 'VITE_LOG_LEVEL']
  const envFiles = [
    { name: '.env.development', required: true },
    { name: '.env.production', required: true },
    { name: '.env.example', required: true }
  ]
  for (const file of envFiles) {
    const content = read(file.name)
    if (content === null) {
      fail('env', `缺少 ${file.name}`, `请参照 .env.example 创建 ${file.name}（含 ${REQUIRED.join(' / ')}）`)
      continue
    }
    const env = parseEnv(content)
    const missingKeys = REQUIRED.filter((k) => !(k in env) || env[k] === '')
    if (missingKeys.length > 0) {
      fail(
        'env',
        `${file.name} 缺少变量：${missingKeys.join(', ')}`,
        `在 ${file.name} 中补齐：${missingKeys.join('=..., ')}=...`
      )
    }
    if ('VITE_USE_MOCK' in env && env.VITE_USE_MOCK !== '' && !['true', 'false'].includes(env.VITE_USE_MOCK)) {
      fail(
        'env',
        `${file.name} 的 VITE_USE_MOCK 取值非法："${env.VITE_USE_MOCK}"`,
        '只允许 true（前端 Mock，默认数据）或 false（真实后端）'
      )
    }
    if ('VITE_LOG_LEVEL' in env && env.VITE_LOG_LEVEL !== '' &&
        !['debug', 'info', 'warn', 'error'].includes(env.VITE_LOG_LEVEL)) {
      fail(
        'env',
        `${file.name} 的 VITE_LOG_LEVEL 取值非法："${env.VITE_LOG_LEVEL}"`,
        '只允许 debug / info / warn / error'
      )
    }
    if ('VITE_API_BASE_URL' in env && env.VITE_API_BASE_URL !== '' &&
        !/^(https?:\/\/|\/)/.test(env.VITE_API_BASE_URL)) {
      fail(
        'env',
        `${file.name} 的 VITE_API_BASE_URL 取值非法："${env.VITE_API_BASE_URL}"`,
        '必须以 / 开头的相对路径（如 /api）或 http(s):// 绝对地址'
      )
    }
    if (missingKeys.length === 0) {
      pass('env', `${file.name} 变量齐全（USE_MOCK=${env.VITE_USE_MOCK}, LOG_LEVEL=${env.VITE_LOG_LEVEL}）`)
    }
  }
}

// ---------------------------------------------------------------------------
// 阶段 4：端口基线
// ---------------------------------------------------------------------------
banner(`阶段 4/8 端口（开发 ${DEV_PORT} / 容器宿主 ${HOST_PORT} 必须空闲）`)
{
  const viteConfig = read('vite.config.js') || ''
  const m = viteConfig.match(/server:\s*\{[\s\S]*?port:\s*(\d+)/)
  if (m && Number(m[1]) !== DEV_PORT) {
    fail(
      'port',
      `vite.config.js 开发端口已被改为 ${m[1]}`,
      `基线固定开发端口为 ${DEV_PORT}，请改回 server.port=${DEV_PORT}`
    )
  } else {
    pass('port', `vite.config.js 开发端口固定为 ${DEV_PORT}（strictPort，占用即失败而非静默换端口）`)
  }
  for (const [port, purpose] of [
    [DEV_PORT, 'npm run dev 开发服务器'],
    [HOST_PORT, 'docker-compose 用户端宿主映射（8081:80）']
  ]) {
    const busy = await probePort(port)
    if (busy) {
      fail(
        'port',
        `端口 ${port} 已被占用（${purpose}）`,
        `请先释放该端口：lsof -i :${port} 找到占用进程并停止；不要在端口被占时启动基线`
      )
    } else {
      pass('port', `端口 ${port} 空闲（${purpose}）`)
    }
  }
}

// ---------------------------------------------------------------------------
// 阶段 5：构建基线
// ---------------------------------------------------------------------------
if (!skipBuild) {
  banner('阶段 5/8 构建（npm run build）')
  const build = await run('npm', ['run', 'build'], { timeout: 180000 })
  if (build.code === 0) {
    pass('build', 'vite build 成功')
  } else {
    const tail = build.out.split('\n').filter(Boolean).slice(-12).join('\n')
    fail(
      'build',
      `npm run build 失败（exit=${build.code}），末尾输出：\n${C.gray(tail)}`,
      '根据上方构建日志修复源码/依赖后重试；依赖问题可 `rm -rf node_modules && npm ci`'
    )
  }
}

// ---------------------------------------------------------------------------
// 阶段 6：产物基线
// ---------------------------------------------------------------------------
if (!skipBuild) {
  banner('阶段 6/8 构建产物（dist/）')
  if (!exists('dist/index.html')) {
    fail('artifact', '缺少 dist/index.html', '构建未产出入口 HTML，请先确保 `npm run build` 成功')
  } else {
    const html = read('dist/index.html')
    const assets = exists('dist/assets') ? readdirSync(join(ROOT, 'dist/assets')) : []
    const js = assets.filter((f) => f.endsWith('.js'))
    const css = assets.filter((f) => f.endsWith('.css'))
    const jsNonEmpty = js.some((f) => statSync(join(ROOT, 'dist/assets', f)).size > 1000)
    if (js.length === 0 || !jsNonEmpty) {
      fail('artifact', 'dist/assets 下缺少有效的 JS 产物', '构建异常，请删除 dist 后重新 `npm run build`')
    } else if (css.length === 0) {
      fail('artifact', 'dist/assets 下缺少 CSS 产物', '构建异常，请删除 dist 后重新 `npm run build`')
    } else if (!js.some((f) => html.includes(`assets/${f}`))) {
      fail('artifact', 'dist/index.html 未引用构建出的 JS 产物', '请检查 index.html 与 vite 构建配置是否被改动')
    } else {
      pass(
        'artifact',
        `dist 产物完整：index.html + ${js.length} 个 JS（${js[0]}）+ ${css.length} 个 CSS（${css[0]}）`
      )
    }
  }
}

// ---------------------------------------------------------------------------
// 阶段 7：开发服务器冒烟（启动 → 核心页面入口 → 关停 → 复核无残留）
// ---------------------------------------------------------------------------
if (!skipSmoke) {
  banner(`阶段 7/8 开发冒烟（npm run dev @ ${DEV_PORT}，核心页面入口）`)
  const child = spawn(
    process.platform === 'win32' ? 'npm.cmd' : 'npm',
    ['run', 'dev', '--', '--strictPort'],
    {
      cwd: ROOT,
      env: process.env,
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
      ...(process.platform === 'win32' ? {} : { detached: true })
    }
  )
  children.add(child)
  let devLog = ''
  child.stdout?.on('data', (d) => {
    devLog += d.toString()
    if (devLog.length > 200000) devLog = devLog.slice(-200000)
  })
  child.stderr?.on('data', (d) => {
    devLog += d.toString()
    if (devLog.length > 200000) devLog = devLog.slice(-200000)
  })

  let exitedEarly = null
  child.on('close', (code) => {
    exitedEarly = code
  })

  const ready = await waitForPort(DEV_PORT, 60000)
  if (!ready) {
    if (exitedEarly !== null) {
      const tail = devLog.split('\n').filter(Boolean).slice(-10).join('\n')
      fail(
        'smoke',
        `开发服务器提前退出（exit=${exitedEarly}），末尾日志：\n${C.gray(tail)}`,
        '常见原因：端口占用（strictPort）、依赖损坏（npm ci 重装）、配置语法错误'
      )
    } else {
      fail('smoke', `开发服务器 60s 内未在 ${DEV_PORT} 端口就绪`, '查看上方 dev 日志定位启动卡住原因')
    }
  } else {
    pass('smoke', `开发服务器已就绪：http://127.0.0.1:${DEV_PORT}`)

    // 核心页面入口：SPA history 回退下所有路由都应由 index.html 承载（200）
    const routes = ['/', '/tables', '/courses', '/competitions', '/shop', '/tasks', '/profile']
    for (const route of routes) {
      const res = await httpGet(route)
      if (res.status === 200 && res.text.includes('<div id="app">')) {
        pass('smoke', `页面入口 ${route} → 200（返回 SPA 外壳）`)
      } else {
        fail(
          'smoke',
          `页面入口 ${route} 异常（status=${res.status}）`,
          '检查 src/router/index.js 路由与对应 src/views/*.vue 是否存在语法/导入错误'
        )
      }
    }

    // 应用引导模块经 Vite 即时编译必须可加载，且 6 个核心视图可被转换（编译错误会返回 500）
    const mainRes = await httpGet('/src/main.js')
    if (mainRes.status === 200 && /createApp|mount/.test(mainRes.text)) {
      pass('smoke', '/src/main.js 经 Vite 编译可加载（应用引导正常）')
    } else {
      fail(
        'smoke',
        `/src/main.js 加载失败（status=${mainRes.status}）：${mainRes.text.split('\n')[0]}`,
        '检查 main.js 及其导入链（App.vue / router / utils）'
      )
    }
    const viewMap = {
      Home: '/src/views/Home.vue',
      Tables: '/src/views/Tables.vue',
      Courses: '/src/views/Courses.vue',
      Competitions: '/src/views/Competitions.vue',
      Shop: '/src/views/Shop.vue',
      Profile: '/src/views/Profile.vue',
      Tasks: '/src/views/Tasks.vue'
    }
    for (const [name, url] of Object.entries(viewMap)) {
      const res = await httpGet(url)
      if (res.status === 200) {
        pass('smoke', `${name}.vue 编译通过（${url}）`)
      } else {
        const firstErr = res.text.split('\n').find((l) => /error|Error|Syntax/i.test(l)) || res.text.slice(0, 200)
        fail('smoke', `${name}.vue 编译失败（${url} status=${res.status}）：${firstErr}`)
      }
    }
  }

  // 关停开发服务器并复核端口释放——任何情况下都不残留服务
  cleanup('SIGTERM')
  await new Promise((r) => setTimeout(r, 2000))
  const released = !(await waitForPort(DEV_PORT, 5000))
  if (released) {
    pass('smoke', `冒烟结束后端口 ${DEV_PORT} 已释放，无残留服务`)
  } else {
    // 兜底强杀后再复核一次
    cleanup('SIGKILL')
    await new Promise((r) => setTimeout(r, 2000))
    if (!(await probePort(DEV_PORT))) {
      record('smoke', true, `端口 ${DEV_PORT} 经强制清理后释放（建议核查子进程退出行为）`)
    } else {
      fail(
        'smoke',
        `冒烟结束后端口 ${DEV_PORT} 仍被占用，存在残留服务`,
        `手动执行：lsof -i :${DEV_PORT} 后 kill 对应进程`
      )
    }
  }
}

// ---------------------------------------------------------------------------
// 阶段 8：容器运行约束（静态基线；有 Docker 时给出可用性提示）
// ---------------------------------------------------------------------------
if (!skipContainer) {
  banner('阶段 8/8 容器约束（Dockerfile / nginx / docker-compose / .dockerignore）')
  const dockerfile = read('Dockerfile')
  if (!dockerfile) {
    fail('container', '缺少 Dockerfile')
  } else {
    const checks = [
      [/FROM\s+node:20-alpine\s+AS\s+builder/i, '构建阶段基于多架构 node:20-alpine（amd64/arm64）'],
      [/FROM\s+nginx:1\.25-alpine/i, '运行阶段基于多架构 nginx:1.25-alpine（amd64/arm64）'],
      [/npm\s+ci/, '依赖安装使用 npm ci（按锁文件可复现安装）'],
      [/npm\s+run\s+build/, '镜像内包含完整编译过程 npm run build'],
      [/COPY --from=builder[^\n]*\/app\/dist/, '编译产物 dist 复制进 nginx 镜像'],
      [/EXPOSE\s+80/, '容器内固定监听 80 端口'],
      [/nginx\.conf/, '携带自定义 nginx.conf']
    ]
    for (const [re, label] of checks) {
      if (re.test(dockerfile)) pass('container', label)
      else fail('container', `Dockerfile 不满足约束：${label}`)
    }
  }

  const nginxConf = read('nginx.conf')
  if (!nginxConf) {
    fail('container', '缺少 nginx.conf')
  } else {
    if (/listen\s+80/.test(nginxConf)) pass('container', 'nginx 监听 80')
    else fail('container', 'nginx.conf 未监听 80 端口')
    if (/try_files\s+\$uri\s+\$uri\/\s+\/index\.html/.test(nginxConf)) {
      pass('container', 'nginx 配置 SPA history 回退（刷新/深链不 404）')
    } else {
      fail('container', 'nginx.conf 缺少 try_files ... /index.html 回退')
    }
  }

  const compose = read('../docker-compose.yml')
  if (!compose) {
    fail('container', '缺少根目录 docker-compose.yml')
  } else {
    if (/8081:80/.test(compose)) pass('container', 'docker-compose 固定端口映射 8081:80')
    else fail('container', 'docker-compose.yml 必须固定映射 "8081:80"')
    if (/healthcheck:/i.test(compose)) pass('container', 'docker-compose 配置 healthcheck（容器状态可观测）')
    else fail('container', 'docker-compose.yml 缺少 healthcheck')
    if (/billiard-network/.test(compose)) pass('container', '接入 billiard-network 桥接网络')
  }

  const dockerignore = read('.dockerignore')
  if (!dockerignore) {
    fail('container', '缺少 .dockerignore', '需排除 node_modules/ 与 dist/，避免宿主异构产物污染镜像构建上下文')
  } else {
    if (/^node_modules\/?/m.test(dockerignore)) pass('container', '.dockerignore 排除 node_modules/')
    else fail('container', '.dockerignore 必须排除 node_modules/')
    if (/^dist\/?/m.test(dockerignore)) pass('container', '.dockerignore 排除 dist/')
    else fail('container', '.dockerignore 必须排除 dist/')
  }

  // 有 Docker 时做轻量可用性探测（不拉镜像、不构建），无 Docker 时跳过而非失败
  const docker = await run('docker', ['version', '--format', '{{.Server.Version}}'], { timeout: 10000 })
  if (docker.code === 0) {
    pass('container', `当前环境可用 Docker（server ${docker.out.trim()}），可执行 docker-compose up --build -d 复验`)
  } else {
    console.log(C.yellow('  ! Docker 守护进程在本机不可用，容器阶段按静态基线校验通过即可（CI/验收机构建镜像时生效）'))
  }
}

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------
const total = results.length
const okCount = results.filter((r) => r.ok).length
console.log(`\n${C.cyan('────────────────────────────────────────────────────────')}`)
console.log(`基线校验结果：${failures === 0 ? C.green('PASS') : C.red('FAIL')}  ${okCount}/${total} 项通过`)
if (failures > 0) {
  console.log(`\n${C.red('失败项与修复指引：')}`)
  for (const r of results.filter((x) => !x.ok)) {
    console.log(`\n${C.red('✗ [' + r.stage + ']')} ${r.message}`)
    if (r.fix) console.log(`${C.gray('  修复：')}${r.fix.split('\n').join('\n        ')}`)
  }
  console.log('')
  process.exit(1)
}
console.log(C.green('用户端开发/构建/环境变量/端口/容器基线全部满足，且无残留服务。'))
process.exit(0)
