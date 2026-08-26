import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tooltip"]
  static values = { scores: { type: Array, default: [64, 71, 68, 76, 81, 79, 86, 84, 91, 88] } }

  connect() {
    this.index = 0
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) this.start()
        else this.stop()
      })
    }, { threshold: 0.4 })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    this.stopTimer()
    this.stage()?.classList.remove("is-on")
  }

  start() {
    this.stage()?.classList.add("is-on")
    if (this.reduced) {
      this.render()
      return
    }
    this.stopTimer()
    this.timer = window.setInterval(() => {
      this.index = (this.index + 1) % this.scoresValue.length
      this.render()
    }, 2000)
    this.render()
  }

  stage() {
    return this.element.querySelector(".health-stage")
  }

  stopTimer() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
  }

  stop() {
    this.stage()?.classList.remove("is-on")
    this.stopTimer()
  }

  render() {
    if (this.hasTooltipTarget) this.tooltipTarget.textContent = String(this.scoresValue[this.index])
  }
}
