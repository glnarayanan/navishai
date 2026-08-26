import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "panel", "line", "carousel", "card", "mobileCanvas", "mobileLine"]
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.index = 0
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.onKey = (event) => this.shortcut(event)
    this.element.addEventListener("keydown", this.onKey)
    if (!this.reduced) this.start()
    this.show(0)
  }

  disconnect() {
    this.stop()
    this.element.removeEventListener("keydown", this.onKey)
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
    this.scrollCard(index)
    if (!this.reduced) this.start()
  }

  keyselect(event) {
    if (event.key !== "Enter" && event.key !== " ") return
    event.preventDefault()
    this.select(event)
  }

  shortcut(event) {
    if (event.key === "ArrowRight") {
      event.preventDefault()
      this.show((this.index + 1) % this.itemTargets.length)
      this.scrollCard(this.index)
      if (!this.reduced) this.start()
    } else if (event.key === "ArrowLeft") {
      event.preventDefault()
      this.show((this.index - 1 + this.itemTargets.length) % this.itemTargets.length)
      this.scrollCard(this.index)
      if (!this.reduced) this.start()
    }
  }

  advance() {
    const next = (this.index + 1) % this.itemTargets.length
    this.show(next)
    this.scrollCard(next)
  }

  scrollCard(index) {
    if (!this.hasCarouselTarget) return
    const card = this.cardTargets[index]
    if (!card) return
    const cardRect = card.getBoundingClientRect()
    const carouselRect = this.carouselTarget.getBoundingClientRect()
    const offset = cardRect.left - carouselRect.left - (carouselRect.width - cardRect.width) / 2
    this.carouselTarget.scrollTo({
      left: this.carouselTarget.scrollLeft + offset,
      behavior: this.reduced ? "auto" : "smooth"
    })
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
      const selected = i === index
      panel.hidden = !selected
      panel.classList.toggle("is-active", selected)
    })
    if (this.hasMobileCanvasTarget) {
      this.mobileCanvasTargets.forEach((canvas, i) => {
        const selected = i === index
        canvas.hidden = !selected
        canvas.classList.toggle("is-active", selected)
      })
    }
    if (this.hasCardTarget) {
      this.cardTargets.forEach((card, i) => card.classList.toggle("is-active", i === index))
    }
    this.restartLines(this.lineTargets, index)
    if (this.hasMobileLineTarget) this.restartLines(this.mobileLineTargets, index)
  }

  restartLines(lines, index) {
    lines.forEach((line, i) => {
      line.classList.remove("is-running")
      void line.offsetWidth
      if (i === index && !this.reduced) line.classList.add("is-running")
    })
  }
}
