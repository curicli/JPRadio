// FM 刻度尺（canvas 版）。iOS 端 ios/JPRadio/Views/FrequencyDialView.swift 的等价物。
//
// 与 iOS 端同一个画法要点：**只画可见范围**，每个刻度的 x 由「离中心频率多远」直接算出
// （`(f - center) * PX_PER_MHZ + 宽/2`），所以刻度天然对齐正中央那根指针，不需要把一条
// 比容器宽的尺子整体平移 —— 那条路在 SwiftUI 里踩过对不齐的坑，canvas 里同样没必要。
//
// 拖动结束吸附到最近的台；同频台（日本很常见）在同一处依次轮换，否则第二个台永远选不到。

const PX_PER_MHZ = 52
const BRAND = '#ff662e'

class Dial {
  constructor(canvas, onSelect) {
    this.canvas = canvas
    this.ctx = canvas.getContext('2d')
    this.onSelect = onSelect
    this.stations = []
    this.selectedID = null
    this.center = 80
    this.target = 80
    this.dragging = false
    this.dragFrom = 0
    this.dragCenter = 80
    this.bounds = [76, 95]

    canvas.addEventListener('pointerdown', (e) => this.down(e))
    canvas.addEventListener('pointermove', (e) => this.move(e))
    canvas.addEventListener('pointerup', (e) => this.up(e))
    canvas.addEventListener('pointercancel', () => this.cancel())
    canvas.addEventListener('wheel', (e) => this.wheel(e), { passive: false })
    window.addEventListener('resize', () => this.resize())
    this.resize()
    requestAnimationFrame(() => this.tick())
  }

  setStations(stations, selectedID) {
    this.stations = stations.slice().sort((a, b) => a.frequency - b.frequency)
    const freqs = this.stations.map((s) => s.frequency)
    // 可调范围由拨盘上的电台决定，两端各留 1.2MHz 余量：不让刻度滑进大片没有台的空白。
    this.bounds = freqs.length
      ? [Math.max(freqs[0] - 1.2, 76), Math.min(freqs[freqs.length - 1] + 1.2, 95)]
      : [76, 95]
    this.setSelected(selectedID, true)
  }

  setSelected(id, jump = false) {
    this.selectedID = id
    const hit = this.stations.find((s) => s.id === id) ?? this.stations[0]
    if (!hit) return
    this.target = this.clamp(hit.frequency)
    if (jump) this.center = this.target
  }

  clamp(f) {
    return Math.min(Math.max(f, this.bounds[0]), this.bounds[1])
  }

  // MARK: - 交互

  down(e) {
    this.dragging = true
    this.dragFrom = e.clientX
    this.dragCenter = this.center
    this.canvas.setPointerCapture?.(e.pointerId)
  }

  move(e) {
    if (!this.dragging) return
    // 手指右移 → 频率变小（尺子跟着手走），和实体收音机的手感一致。
    this.center = this.clamp(this.dragCenter - (e.clientX - this.dragFrom) / PX_PER_MHZ)
    this.target = this.center
  }

  up() {
    if (!this.dragging) return
    this.dragging = false
    this.snap(this.center)
  }

  cancel() {
    this.dragging = false
    this.target = this.center
  }

  wheel(e) {
    e.preventDefault()
    this.center = this.clamp(this.center + Math.sign(e.deltaY) * 0.1)
    this.target = this.center
    clearTimeout(this.wheelTimer)
    this.wheelTimer = setTimeout(() => this.snap(this.center), 220)
  }

  /// 吸附到最近的台；同频重叠时轮换到下一个。
  snap(freq) {
    if (!this.stations.length) return
    let nearest = this.stations[0]
    for (const s of this.stations) {
      if (Math.abs(s.frequency - freq) < Math.abs(nearest.frequency - freq)) nearest = s
    }
    const cluster = this.stations.filter((s) => Math.abs(s.frequency - nearest.frequency) < 0.001)
    let pick = nearest
    if (cluster.length > 1) {
      const idx = cluster.findIndex((s) => s.id === this.selectedID)
      if (idx >= 0) pick = cluster[(idx + 1) % cluster.length]
    }
    this.target = this.clamp(pick.frequency)
    if (pick.id !== this.selectedID) {
      this.selectedID = pick.id
      this.onSelect?.(pick.id)
    }
  }

  // MARK: - 绘制

  resize() {
    const dpr = window.devicePixelRatio || 1
    const w = this.canvas.clientWidth || 320
    // 高度问 CSS 要（宽屏那套布局会把尺子加高），别写死 —— 写死的话画出来的东西
    // 要么被裁掉一截，要么下半截空着。
    const h = this.canvas.clientHeight || 96
    this.canvas.width = Math.round(w * dpr)
    this.canvas.height = Math.round(h * dpr)
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    this.w = w
    this.h = h
  }

  tick() {
    // 松手后用指数逼近滑到目标频率（≈ SwiftUI 那条 spring 的观感），差得足够近就停。
    if (!this.dragging && Math.abs(this.target - this.center) > 0.0005) {
      this.center += (this.target - this.center) * 0.18
    } else if (!this.dragging) {
      this.center = this.target
    }
    // 尺寸变了要重取位图大小。不能只听 window 的 resize：宽屏那套布局一生效，
    // 这条尺子的容器宽度就变了（右边多出一栏台列表），而窗口本身没动过 ——
    // 位图还是旧尺寸的话画出来会被整体拉伸，px/MHz 就不对了。
    // 每 10 帧问一次（读 clientWidth 会触发一次样式计算，没必要每帧都来）。
    if ((this.frame = (this.frame ?? 0) + 1) % 10 === 0) {
      const w = this.canvas.clientWidth
      const h = this.canvas.clientHeight
      if (w && h && (w !== this.w || h !== this.h)) this.resize()
    }
    this.draw()
    requestAnimationFrame(() => this.tick())
  }

  /// 圆角矩形。`roundRect` 不是所有浏览器都有（老 Safari），退回自己拼一条路径。
  capsule(x, y, w, h) {
    const ctx = this.ctx
    const r = h / 2
    ctx.beginPath()
    if (ctx.roundRect) return void ctx.roundRect(x, y, w, h, r)
    ctx.moveTo(x + r, y)
    ctx.arcTo(x + w, y, x + w, y + h, r)
    ctx.arcTo(x + w, y + h, x, y + h, r)
    ctx.arcTo(x, y + h, x, y, r)
    ctx.arcTo(x, y, x + w, y, r)
    ctx.closePath()
  }

  // 版式跟 iOS 端一致：刻度**从上边缘往下垂**（不是立在底线上），整数刻度下面标数字，
  // 有电台的频率在下方点一颗品牌色圆点，正中央一根带光晕的指针，底部一枚读数胶囊。
  draw() {
    const { ctx, w, h } = this
    if (!w) return
    ctx.clearRect(0, 0, w, h)
    const mid = w / 2
    const x = (f) => (f - this.center) * PX_PER_MHZ + mid
    const dotFreqs = new Map()
    for (const s of this.stations) dotFreqs.set(s.frequency.toFixed(1), s)

    const tickTop = 14
    const capH = 22
    const capTop = h - capH
    const dotsY = capTop - 8
    const labelY = tickTop + 30 + 11

    ctx.textAlign = 'center'
    ctx.textBaseline = 'alphabetic'

    // 0.1MHz 一格：整数最长、半格中等、其余最短，越细越淡。
    const from = Math.floor((this.center - w / 2 / PX_PER_MHZ) * 10) / 10
    const to = Math.ceil((this.center + w / 2 / PX_PER_MHZ) * 10) / 10
    for (let f = from; f <= to + 0.001; f = Math.round((f + 0.1) * 10) / 10) {
      if (f < this.bounds[0] - 0.5 || f > this.bounds[1] + 0.5) continue
      const isWhole = Math.abs(f - Math.round(f)) < 0.001
      const isHalf = Math.abs((f * 10) % 5) < 0.001
      const len = isWhole ? 30 : isHalf ? 18 : 10
      ctx.strokeStyle = isWhole ? 'rgba(255,255,255,.9)' : isHalf ? 'rgba(255,255,255,.5)' : 'rgba(255,255,255,.3)'
      ctx.lineWidth = isWhole ? 2 : 1
      ctx.beginPath()
      ctx.moveTo(x(f), tickTop)
      ctx.lineTo(x(f), tickTop + len)
      ctx.stroke()
      if (isWhole) {
        ctx.fillStyle = 'rgba(255,255,255,.7)'
        ctx.font = '12px ui-rounded, "SF Pro Rounded", system-ui, sans-serif'
        ctx.fillText(String(Math.round(f)), x(f), labelY)
      }
      // 这一格上有台：点一颗品牌色圆点（当前选中的那颗大一圈）。
      const hit = dotFreqs.get(f.toFixed(1))
      if (hit) {
        const on = this.stations.some((s) => s.id === this.selectedID && s.frequency.toFixed(1) === f.toFixed(1))
        ctx.fillStyle = BRAND
        ctx.globalAlpha = on ? 1 : 0.65
        ctx.beginPath()
        ctx.arc(x(f), dotsY, on ? 4.5 : 3.5, 0, Math.PI * 2)
        ctx.fill()
        ctx.globalAlpha = 1
      }
    }

    // 中央指针：上面一个三角，下面一条带光晕的线（iOS 端也是这两件）。
    ctx.save()
    ctx.shadowColor = 'rgba(255, 102, 46, .8)'
    ctx.shadowBlur = 6
    ctx.fillStyle = BRAND
    ctx.beginPath()
    ctx.moveTo(mid - 7, 0)
    ctx.lineTo(mid + 7, 0)
    ctx.lineTo(mid, 9)
    ctx.closePath()
    ctx.fill()
    ctx.strokeStyle = BRAND
    ctx.lineWidth = 2.5
    ctx.beginPath()
    ctx.moveTo(mid, 7)
    ctx.lineTo(mid, dotsY + 7)
    ctx.stroke()
    ctx.restore()

    // 读数胶囊。显示的是**指针所在的频率**（拖动中会连续变），所以它跟卡片上那个
    // 大号频率不是一回事 —— 拖的时候正好能看出正在经过哪儿。
    const text = `${this.center.toFixed(1)} MHz`
    ctx.font = '700 13px ui-rounded, "SF Pro Rounded", system-ui, sans-serif'
    const cw = Math.max(88, ctx.measureText(text).width + 26)
    ctx.fillStyle = 'rgba(255,255,255,.12)'
    this.capsule(mid - cw / 2, capTop, cw, capH)
    ctx.fill()
    ctx.fillStyle = '#fff'
    ctx.fillText(text, mid, capTop + 15)
  }
}
