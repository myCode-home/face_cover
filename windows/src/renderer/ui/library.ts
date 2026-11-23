// 录像库窗口控制器。对齐 macOS 版 RecordingLibrary/LibraryView：
// 扫描排序、缩略图与时长、删除进回收站、定位高亮状态机（0.20 → 1.4s 后收 0.07）。

import { api, LibraryEntryDTO } from '../api.js'
import { createdAtText, durationText, sizeText } from '../core/format.js'

const $ = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T

interface Probed {
  duration: number | null
  thumb: string | null
}

let entries: LibraryEntryDTO[] = []
let scanning = false
let highlightName: string | null = null
let highlightSettled = false
let highlightTimer: ReturnType<typeof setTimeout> | null = null
let pendingHighlightName: string | null = null

const thumbs = new Map<string, Probed>() // key = path + mtime

void bootstrap()

function bootstrap(): void {
  wireTitlebar()
  $('btn-refresh').addEventListener('click', () => void refresh())
  $('btn-open-dir').addEventListener('click', () => void api.openRecordingsDir())
  $('banner-ok').addEventListener('click', () => $('banner').classList.remove('show'))
  $('confirm-yes').addEventListener('click', () => {
    const dialog = $('confirm-dialog') as HTMLDialogElement
    const path = dialog.dataset.path
    dialog.close()
    if (path) void trashEntry(path)
  })
  $('confirm-no').addEventListener('click', () => ($('confirm-dialog') as HTMLDialogElement).close())
  api.onLibraryHighlight((name) => {
    pendingHighlightName = name || null
    highlightName = pendingHighlightName
    highlightSettled = false
    armHighlightTimer()
    scrollToHighlight()
    render()
  })
  void refresh()
}

function wireTitlebar(): void {
  $('tl-close').addEventListener('click', () => api.closeWindow())
  $('tl-min').addEventListener('click', () => api.minimize())
  $('tl-max').addEventListener('click', () => api.maximizeToggle())
}

// ---------- 扫描 ----------

async function refresh(): Promise<void> {
  if (scanning) return
  scanning = true
  $('scan-spinner').classList.remove('hidden')
  ;($('btn-refresh') as HTMLButtonElement).disabled = true
  try {
    const fresh = await api.scanRecordings()
    const hadNew = fresh.length > entries.length
    entries = fresh
    console.log(`[library] 扫描完成：${entries.length} 条录像`)
    render()
    if (pendingHighlightName || highlightName) {
      scrollToHighlight()
      if (hadNew) setTimeout(scrollToHighlight, 300)
    }
  } finally {
    scanning = false
    $('scan-spinner').classList.add('hidden')
    ;($('btn-refresh') as HTMLButtonElement).disabled = false
  }
}

// ---------- 渲染 ----------

function render(): void {
  const list = $('list')
  list.innerHTML = ''
  if (entries.length === 0) {
    const dir = document.createElement('div')
    dir.className = 'empty'
    dir.innerHTML = '<div class="glyph">🎬</div><div class="headline">还没有录像</div><div class="sub">录完第一段之后，它会出现在这里。<br>文件都存在录像目录里。</div>'
    list.appendChild(dir)
  }
  let totalSize = 0
  for (const entry of entries) {
    totalSize += entry.sizeBytes
    list.appendChild(buildRow(entry))
  }
  $('stats').textContent = entries.length === 0 ? '还没有录像' : `共 ${entries.length} 个 · ${sizeText(totalSize)}`
  void probePending()
}

function buildRow(entry: LibraryEntryDTO): HTMLElement {
  const row = document.createElement('div')
  row.className = 'entry'
  row.dataset.name = entry.name
  row.dataset.path = entry.path
  const probed = thumbs.get(thumbKey(entry))

  const title = document.createElement('div')
  title.className = 'name'
  title.textContent = entry.name.replace(/\.[^.]+$/, '')
  title.title = entry.name

  const sub = document.createElement('div')
  sub.className = 'sub'
  const dur = probed?.duration
  sub.textContent = `⏱ ${durationText(dur ?? undefined)} · 💾 ${sizeText(entry.sizeBytes)}`

  const created = document.createElement('div')
  created.className = 'created'
  created.textContent = createdAtText(new Date(entry.birthMs))

  const meta = document.createElement('div')
  meta.className = 'meta'
  meta.append(title, sub, created)

  const thumb = document.createElement('div')
  thumb.className = 'thumb'
  if (probed?.thumb) {
    const img = document.createElement('img')
    img.src = probed.thumb
    thumb.appendChild(img)
  }

  const play = document.createElement('button')
  play.className = 'btn'
  play.style.flex = 'none'
  play.textContent = '▶ 播放'
  play.addEventListener('click', () => void api.playItem(entry.path))

  const more = document.createElement('button')
  more.className = 'more-btn'
  more.textContent = '⋯'
  more.addEventListener('click', (e) => {
    e.stopPropagation()
    showMenu(e.clientX, e.clientY, entry)
  })

  const actions = document.createElement('div')
  actions.className = 'actions'
  actions.append(play, more)

  row.append(thumb, meta, actions)
  row.addEventListener('contextmenu', (e) => {
    e.preventDefault()
    showMenu(e.clientX, e.clientY, entry)
  })
  thumb.addEventListener('click', () => void api.playItem(entry.path))

  if (highlightName === entry.name) {
    row.classList.add('highlight')
    row.style.setProperty('--tint', String(highlightSettled ? 0.07 : 0.2))
  }
  return row
}

function showMenu(x: number, y: number, entry: LibraryEntryDTO): void {
  closeMenu()
  const menu = document.createElement('div')
  menu.className = 'menu'
  menu.id = 'context-menu'
  const item = (label: string, fn: () => void, destructive = false): void => {
    const button = document.createElement('button')
    button.className = `menu-item${destructive ? ' destructive' : ''}`
    button.textContent = label
    button.addEventListener('click', () => {
      closeMenu()
      fn()
    })
    menu.appendChild(button)
  }
  item('播放', () => void api.playItem(entry.path))
  item('在文件夹中显示', () => void api.revealItem(entry.path))
  item('复制文件路径', () => void api.copyText(entry.path))
  const hr = document.createElement('hr')
  menu.appendChild(hr)
  item('删除（移到回收站）', () => confirmTrash(entry), true)
  document.body.appendChild(menu)
  // 贴着屏幕边收进来
  const rect = menu.getBoundingClientRect()
  menu.style.left = `${Math.min(x, window.innerWidth - rect.width - 8)}px`
  menu.style.top = `${Math.min(y, window.innerHeight - rect.height - 8)}px`
  setTimeout(() => window.addEventListener('click', closeMenu, { once: true }), 0)
}

function closeMenu(): void {
  document.getElementById('context-menu')?.remove()
}

function confirmTrash(entry: LibraryEntryDTO): void {
  const dialog = $('confirm-dialog') as HTMLDialogElement
  dialog.dataset.path = entry.path
  $('confirm-content').textContent = `${entry.name}\n\n会放进回收站，需要的话还能捞回来。`
  dialog.showModal()
}

async function trashEntry(path: string): Promise<void> {
  const result = await api.trashItem(path)
  if (!result.ok) {
    $('banner-text').textContent = `删不掉「${path.split(/[\\/]/).pop()}」：${result.error}`
    $('banner').classList.add('show')
  }
  await refresh()
}

// ---------- 缩略图 / 时长 ----------

function thumbKey(entry: LibraryEntryDTO): string {
  return `${entry.path}|${entry.mtimeMs}`
}

async function probePending(): Promise<void> {
  const pending = entries.filter((e) => !thumbs.has(thumbKey(e)))
  for (const entry of pending) {
    // 串行探测，别让十几个 video 元素同时解码
    const probed = await probeVideo(entry.path)
    thumbs.set(thumbKey(entry), probed)
    const row = document.querySelector(`.entry[data-path="${CSS.escape(entry.path)}"]`)
    if (row) {
      const thumb = row.querySelector('.thumb')
      const sub = row.querySelector('.sub')
      if (thumb instanceof HTMLElement && probed.thumb) {
        thumb.innerHTML = ''
        const img = document.createElement('img')
        img.src = probed.thumb
        thumb.appendChild(img)
      }
      if (sub) sub.textContent = `⏱ ${durationText(probed.duration ?? undefined)} · 💾 ${sizeText(entry.sizeBytes)}`
    }
  }
}

function fileUrl(path: string): string {
  return 'file://' + path.replace(/\\/g, '/').split('/').map(encodeURIComponent).join('/')
}

function probeVideo(path: string): Promise<Probed> {
  return new Promise((resolve) => {
    const video = document.createElement('video')
    video.preload = 'metadata'
    video.muted = true
    let settled = false
    const finish = (probed: Probed): void => {
      if (settled) return
      settled = true
      video.removeAttribute('src')
      video.load()
      resolve(probed)
    }
    const timeout = setTimeout(() => finish({ duration: null, thumb: null }), 8000)
    video.addEventListener('loadedmetadata', () => {
      const duration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : null
      if (duration === null || duration <= 0.05) {
        clearTimeout(timeout)
        finish({ duration, thumb: null })
        return
      }
      video.addEventListener(
        'seeked',
        () => {
          clearTimeout(timeout)
          try {
            const canvas = document.createElement('canvas')
            const scale = Math.min(1, 480 / video.videoWidth)
            canvas.width = Math.max(2, Math.round(video.videoWidth * scale))
            canvas.height = Math.max(2, Math.round(video.videoHeight * scale))
            const ctx = canvas.getContext('2d')!
            ctx.drawImage(video, 0, 0, canvas.width, canvas.height)
            finish({ duration, thumb: canvas.toDataURL('image/jpeg', 0.7) })
          } catch {
            finish({ duration, thumb: null })
          }
        },
        { once: true },
      )
      video.currentTime = Math.min(1.0, duration * 0.25)
    })
    video.addEventListener('error', () => {
      clearTimeout(timeout)
      finish({ duration: null, thumb: null })
    })
    video.src = fileUrl(path)
  })
}

// ---------- 定位高亮（状态机对齐 macOS 版） ----------

function armHighlightTimer(): void {
  if (highlightTimer) clearTimeout(highlightTimer)
  highlightTimer = setTimeout(() => {
    highlightSettled = true
    applyHighlightTint()
  }, 1400)
}

function applyHighlightTint(): void {
  const row = findHighlightRow()
  if (row) row.style.setProperty('--tint', String(highlightSettled ? 0.07 : 0.2))
}

function findHighlightRow(): HTMLElement | null {
  if (!highlightName) return null
  return document.querySelector(`.entry[data-name="${CSS.escape(highlightName)}"]`)
}

function scrollToHighlight(): void {
  const row = findHighlightRow()
  if (row) {
    row.scrollIntoView({ behavior: 'smooth', block: 'center' })
    applyHighlightTint()
  }
}
