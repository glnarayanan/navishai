import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "indicator"]

  connect() {
    this.manual = false
    this.jumpTimer = null
    this.activeId = null
    this.activeLink = null
    this.scrolled = null
    this.scrollFrame = null
    this.headerWrap = this.element.querySelector(".site-header-wrap")
    this.links = this.hasMenuTarget ? [...this.menuTarget.querySelectorAll("a")] : []
    this.sections = this.links.filter((link) => link.hasAttribute("data-landing-section")).map((link) => ({
      link,
      section: document.getElementById(link.dataset.landingSection)
    }))
    this.onScroll = () => {
      if (this.scrollFrame !== null) return
      this.scrollFrame = window.requestAnimationFrame(() => {
        this.scrollFrame = null
        this.update()
      })
    }
    this.onResize = () => this.placeIndicator()
    window.addEventListener("scroll", this.onScroll, { passive: true })
    window.addEventListener("resize", this.onResize)
    this.update()
  }

  disconnect() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
    if (this.scrollFrame !== null) window.cancelAnimationFrame(this.scrollFrame)
    if (this.jumpTimer != null) {
      window.clearTimeout(this.jumpTimer)
      this.jumpTimer = null
    }
  }

  update() {
    const scrolled = window.scrollY > 10
    if (this.scrolled !== scrolled) {
      this.headerWrap?.classList.toggle("is-scrolled", scrolled)
      this.scrolled = scrolled
    }
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
    if (this.jumpTimer != null) window.clearTimeout(this.jumpTimer)
    this.jumpTimer = window.setTimeout(() => {
      this.manual = false
      this.jumpTimer = null
    }, 500)
  }

  syncActive() {
    if (!this.hasMenuTarget) return
    let active = this.sections[0]?.link
    let min = Infinity
    this.sections.forEach(({ link, section }) => {
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
    if (this.activeId === id && this.activeLink === link) return
    this.activeId = id
    this.activeLink = link
    this.links.forEach((anchor) => {
      const selected = anchor === link
      anchor.classList.toggle("is-active", selected)
      if (selected) anchor.setAttribute("aria-current", "true")
      else anchor.removeAttribute("aria-current")
    })
    this.placeIndicator(link)
  }

  placeIndicator(link) {
    if (!this.hasIndicatorTarget || !this.hasMenuTarget) return
    const active = link || this.links.find((anchor) => anchor.classList.contains("is-active")) || this.links[0]
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
