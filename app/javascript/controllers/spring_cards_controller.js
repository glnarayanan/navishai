import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["cursor", "card"]

  connect() {
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => this.element.classList.toggle("is-on", entry.isIntersecting))
    }, { threshold: 0.3 })
    this.observer.observe(this.element)
    this.reset()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  move(event) {
    if (this.reduced || !this.hasCursorTarget) return
    const rect = this.element.getBoundingClientRect()
    const x = event.clientX - rect.left
    this.cursorTarget.animate(
      { left: `${x}px` },
      { duration: 200, fill: "forwards", easing: "cubic-bezier(0.22, 1, 0.36, 1)" }
    )
  }

  reset() {
    if (!this.hasCursorTarget) return
    this.cursorTarget.animate(
      { left: "50%" },
      { duration: this.reduced ? 0 : 200, fill: "forwards", easing: "cubic-bezier(0.22, 1, 0.36, 1)" }
    )
  }
}
