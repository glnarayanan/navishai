import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "panel", "line"]
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.index = 0
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    if (!this.reduced) this.start()
    this.show(0)
  }

  disconnect() {
    this.stop()
  }

  start() {
    this.stop()
    this.timer = window.setInterval(() => this.advance(), this.intervalValue)
  }

  stop() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
  }

  select(event) {
    const index = Number(event.currentTarget.dataset.featureIndex)
    this.show(index)
    if (!this.reduced) this.start()
  }

  keyselect(event) {
    if (event.key !== "Enter" && event.key !== " ") return
    event.preventDefault()
    this.select(event)
  }

  advance() {
    this.show((this.index + 1) % this.itemTargets.length)
  }

  show(index) {
    this.index = index
    this.itemTargets.forEach((item, i) => {
      const selected = i === index
      item.classList.toggle("is-active", selected)
      item.setAttribute("aria-selected", selected ? "true" : "false")
      item.tabIndex = selected ? 0 : -1
    })
    this.panelTargets.forEach((panel, i) => {
      panel.hidden = i !== index
    })
    this.lineTargets.forEach((line, i) => {
      const selected = i === index
      line.style.animation = "none"
      line.offsetHeight
      if (selected && this.timer) {
        line.style.transform = "scaleX(0)"
        line.style.animation = `feature-line ${this.intervalValue}ms linear forwards`
      } else {
        line.style.transform = selected ? "scaleX(1)" : "scaleX(0)"
      }
    })
  }
}
