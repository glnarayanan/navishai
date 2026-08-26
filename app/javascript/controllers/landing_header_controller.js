import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame", "bar", "menu", "indicator"]

  connect() {
    this.manual = false
    this.onScroll = () => this.update()
    this.onResize = () => this.placeIndicator()
    window.addEventListener("scroll", this.onScroll, { passive: true })
    window.addEventListener("resize", this.onResize)
    this.update()
    this.placeIndicator()
  }

  disconnect() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
  }

  update() {
    const scrolled = window.scrollY > 10
    this.element.querySelector(".site-header-wrap")?.classList.toggle("is-scrolled", scrolled)
    if (!this.manual) this.syncActive()
  }

  jump(event) {
    const href = event.currentTarget.getAttribute("href")
    if (!href?.startsWith("#")) return
    const target = document.querySelector(href)
    if (!target) return
    event.preventDefault()
    this.manual = true
    this.setActive(href.substring(1), event.currentTarget)
    const top = target.getBoundingClientRect().top + window.pageYOffset - 100
    window.scrollTo({ top, behavior: this.reducedMotion() ? "auto" : "smooth" })
    window.setTimeout(() => { this.manual = false }, 500)
  }

  syncActive() {
    if (!this.hasMenuTarget) return
    const links = [...this.menuTarget.querySelectorAll("a[data-landing-section]")]
    let active = links[0]
    let min = Infinity
    links.forEach((link) => {
      const id = link.dataset.landingSection
      const section = document.getElementById(id)
      if (!section) return
      const distance = Math.abs(section.getBoundingClientRect().top - 100)
      if (distance < min) {
        min = distance
        active = link
      }
    })
    if (active) this.setActive(active.dataset.landingSection, active)
  }

  setActive(id, link) {
    if (!this.hasMenuTarget) return
    this.menuTarget.querySelectorAll("a").forEach((anchor) => {
      const selected = anchor === link
      anchor.classList.toggle("is-active", selected)
      if (selected) anchor.setAttribute("aria-current", "true")
      else anchor.removeAttribute("aria-current")
    })
    this.placeIndicator(link)
  }

  placeIndicator(link) {
    if (!this.hasIndicatorTarget || !this.hasMenuTarget) return
    const active = link || this.menuTarget.querySelector("a.is-active") || this.menuTarget.querySelector("a")
    const item = active?.parentElement
    if (!item || item === this.indicatorTarget) return
    const duration = this.reducedMotion() ? 0 : 280
    this.indicatorTarget.animate(
      { left: `${item.offsetLeft}px`, width: `${item.getBoundingClientRect().width}px` },
      { duration, fill: "forwards", easing: "cubic-bezier(0.22, 1, 0.36, 1)" }
    )
    this.indicatorTarget.classList.add("is-ready")
  }

  reducedMotion() {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }
}
