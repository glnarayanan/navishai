import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.bar = this.element.querySelector(".site-header-wrap")
    this.onScroll = () => this.update()
    window.addEventListener("scroll", this.onScroll, { passive: true })
    this.update()
  }

  disconnect() {
    window.removeEventListener("scroll", this.onScroll)
  }

  update() {
    this.bar?.classList.toggle("is-scrolled", window.scrollY > 12)
  }

  jump(event) {
    const href = event.currentTarget.getAttribute("href")
    if (!href?.startsWith("#")) return
    const target = document.querySelector(href)
    if (!target) return
    event.preventDefault()
    target.scrollIntoView({ behavior: this.reducedMotion() ? "auto" : "smooth", block: "start" })
  }

  reducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }
}
