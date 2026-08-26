import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    color: { type: String, default: "107,114,128" },
    squareSize: { type: Number, default: 3 },
    gridGap: { type: Number, default: 3 },
    flickerChance: { type: Number, default: 0.12 },
    maxOpacity: { type: Number, default: 0.16 },
    text: { type: String, default: "" },
    fontSize: { type: Number, default: 90 }
  }

  connect() {
    this.canvas = this.element.querySelector("canvas")
    if (!this.canvas) return
    this.ctx = this.canvas.getContext("2d")
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.resize = () => this.layout()
    this.observer = new ResizeObserver(this.resize)
    this.observer.observe(this.element)
    this.layout()
    if (!this.reduced) this.frame = requestAnimationFrame((time) => this.draw(time))
  }

  disconnect() {
    this.observer?.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
  }

  layout() {
    const rect = this.element.getBoundingClientRect()
    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    this.width = Math.max(1, Math.floor(rect.width))
    this.height = Math.max(1, Math.floor(rect.height))
    this.dpr = dpr
    this.canvas.width = this.width * dpr
    this.canvas.height = this.height * dpr
    this.canvas.style.width = `${this.width}px`
    this.canvas.style.height = `${this.height}px`
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    const cell = this.squareSizeValue + this.gridGapValue
    this.cols = Math.ceil(this.width / cell)
    this.rows = Math.ceil(this.height / cell)
    this.squares = new Float32Array(this.cols * this.rows)
    for (let i = 0; i < this.squares.length; i += 1) {
      this.squares[i] = Math.random() * this.maxOpacityValue
    }
    this.prepareMask()
    if (this.reduced) this.paint()
  }

  prepareMask() {
    this.mask = null
    if (!this.textValue) return
    const mask = document.createElement("canvas")
    mask.width = this.width
    mask.height = this.height
    const ctx = mask.getContext("2d")
    const size = window.matchMedia("(max-width: 64rem)").matches ? Math.min(70, this.fontSizeValue) : this.fontSizeValue
    ctx.fillStyle = "white"
    ctx.font = `600 ${size}px Geist, ui-sans-serif, system-ui, sans-serif`
    ctx.textAlign = "center"
    ctx.textBaseline = "middle"
    ctx.fillText(this.textValue, this.width / 2, this.height / 2)
    this.mask = ctx.getImageData(0, 0, this.width, this.height).data
  }

  draw(time) {
    const delta = Math.min(0.05, ((time - (this.lastTime || time)) / 1000))
    this.lastTime = time
    for (let i = 0; i < this.squares.length; i += 1) {
      if (Math.random() < this.flickerChanceValue * delta) {
        this.squares[i] = Math.random() * this.maxOpacityValue
      }
    }
    this.paint()
    this.frame = requestAnimationFrame((next) => this.draw(next))
  }

  paint() {
    const ctx = this.ctx
    const cell = this.squareSizeValue + this.gridGapValue
    ctx.clearRect(0, 0, this.width, this.height)
    for (let i = 0; i < this.squares.length; i += 1) {
      const col = i % this.cols
      const row = Math.floor(i / this.cols)
      const x = col * cell
      const y = row * cell
      let opacity = this.squares[i]
      if (this.mask) {
        const mx = Math.min(this.width - 1, Math.floor(x + this.squareSizeValue / 2))
        const my = Math.min(this.height - 1, Math.floor(y + this.squareSizeValue / 2))
        const alpha = this.mask[(my * this.width + mx) * 4]
        if (alpha > 0) opacity = Math.min(1, opacity * 3 + 0.4)
      }
      ctx.fillStyle = `rgba(${this.colorValue},${opacity})`
      ctx.fillRect(x, y, this.squareSizeValue, this.squareSizeValue)
    }
  }
}
