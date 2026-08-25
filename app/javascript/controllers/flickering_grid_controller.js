import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    color: { type: String, default: "128,128,128" },
    squareSize: { type: Number, default: 3 },
    gridGap: { type: Number, default: 3 },
    flickerChance: { type: Number, default: 0.12 },
    maxOpacity: { type: Number, default: 0.16 }
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
    if (this.reduced) this.paint()
  }

  draw(time) {
    const delta = Math.min(0.05, ((time - (this.lastTime || time)) / 1000))
    this.lastTime = time
    for (let i = 0; i < this.squares.length; i += 1) {
      if (Math.random() < this.flickerChanceValue * delta * 12) {
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
      ctx.fillStyle = `rgba(${this.colorValue},${this.squares[i]})`
      ctx.fillRect(col * cell, row * cell, this.squareSizeValue, this.squareSizeValue)
    }
  }
}
