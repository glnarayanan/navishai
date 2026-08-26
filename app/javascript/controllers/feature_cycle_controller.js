import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item", "panel", "line", "carousel", "card", "mobileCanvas", "mobileLine", "pause"]
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.index = 0
    this.holding = false
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.userPaused = this.reduced
    this.onKey = (event) => this.shortcut(event)
    this.onHold = () => this.hold()
    this.onRelease = (event) => this.release(event)
    this.element.addEventListener("keydown", this.onKey)
    this.element.addEventListener("pointerenter", this.onHold)
    this.element.addEventListener("pointerleave", this.onRelease)
    this.element.addEventListener("focusin", this.onHold)
    this.element.addEventListener("focusout", this.onRelease)
    this.show(0)
    this.syncPauseControl()
    if (!this.userPaused) this.start()
  }

  disconnect() {
    this.stop()
    this.element.removeEventListener("keydown", this.onKey)
    this.element.removeEventListener("pointerenter", this.onHold)
    this.element.removeEventListener("pointerleave", this.onRelease)
    this.element.removeEventListener("focusin", this.onHold)
    this.element.removeEventListener("focusout", this.onRelease)
  }

  start() {
    this.stop()
    if (this.userPaused || this.holding) return
    this.timer = window.setInterval(() => this.advance(), this.intervalValue)
  }

  stop() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
  }

  hold() {
    this.holding = true
    this.stop()
  }

  release(event) {
    if (event.type === "focusout" && this.element.contains(event.relatedTarget)) return
    this.holding = false
    this.start()
  }

  togglePause() {
    this.userPaused = !this.userPaused
    this.syncPauseControl()
    if (this.userPaused) {
      this.stop()
      return
    }
    this.holding = false
    this.start()
  }

  syncPauseControl() {
    if (!this.hasPauseTarget) return
    this.pauseTarget.setAttribute("aria-pressed", this.userPaused ? "true" : "false")
    this.pauseTarget.textContent = this.userPaused ? "Play slideshow" : "Pause slideshow"
  }

  select(event) {
    const index = Number(event.currentTarget.dataset.featureIndex)
    this.show(index)
    this.scrollCard(index)
    this.start()
  }

  keyselect(event) {
    if (event.key !== "Enter" && event.key !== " ") return
    event.preventDefault()
    this.select(event)
  }

  shortcut(event) {
    if (!this.itemTargets.includes(event.target)) return

    const current = this.itemTargets.indexOf(event.target)
    const last = this.itemTargets.length - 1
    let next = current
    if (event.key === "ArrowRight" || event.key === "ArrowDown") next = (current + 1) % this.itemTargets.length
    else if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = (current - 1 + this.itemTargets.length) % this.itemTargets.length
    else if (event.key === "Home") next = 0
    else if (event.key === "End") next = last
    else return

    event.preventDefault()
    this.show(next)
    this.scrollCard(next)
    this.itemTargets[next].focus()
    this.start()
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
      panel.tabIndex = selected ? 0 : -1
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
