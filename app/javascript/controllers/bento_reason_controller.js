import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["stack", "dots", "response"]

  connect() {
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) this.answer()
        else this.reset()
      })
    }, { threshold: 0.35 })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    if (this.timer) window.clearTimeout(this.timer)
  }

  answer() {
    if (this.timer) window.clearTimeout(this.timer)
    this.timer = window.setTimeout(() => {
      if (this.hasDotsTarget) this.dotsTarget.hidden = true
      if (this.hasResponseTarget) this.responseTarget.hidden = false
      this.stackTarget.classList.add("is-answered")
    }, this.reduced ? 0 : 1000)
  }

  reset() {
    if (this.timer) window.clearTimeout(this.timer)
    if (this.hasDotsTarget) this.dotsTarget.hidden = false
    if (this.hasResponseTarget) this.responseTarget.hidden = true
    this.stackTarget.classList.remove("is-answered")
  }
}
