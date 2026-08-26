import { Controller } from "@hotwired/stimulus"

const COOKIE = "navishai_theme"
const THEMES = ["system", "light", "dark"]

export default class extends Controller {
  static targets = ["label", "option"]

  connect() {
    this.sync()
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.mediaListener = () => {
      if (this.storedTheme() === "system") this.apply("system")
    }
    this.media.addEventListener("change", this.mediaListener)
    this.placeListener = () => this.placeOpenMenus()
    window.addEventListener("resize", this.placeListener)
  }

  disconnect() {
    this.media?.removeEventListener("change", this.mediaListener)
    window.removeEventListener("resize", this.placeListener)
  }

  placeMenu(event) {
    const details = event.currentTarget
    if (!details.open) return
    requestAnimationFrame(() => this.placeDetails(details))
  }

  placeOpenMenus() {
    this.element.querySelectorAll("details.theme-control[open]").forEach((details) => this.placeDetails(details))
  }

  placeDetails(details) {
    const menu = details.querySelector(".theme-menu")
    if (!menu) return

    menu.classList.remove("is-drop-up", "is-drop-down")
    const toggle = details.querySelector("summary")
    const toggleRect = toggle.getBoundingClientRect()
    const menuHeight = Math.max(menu.scrollHeight, menu.offsetHeight)
    const spaceBelow = window.innerHeight - toggleRect.bottom
    const spaceAbove = toggleRect.top
    const dropUp = spaceBelow < menuHeight + 8 && spaceAbove > spaceBelow
    menu.classList.add(dropUp ? "is-drop-up" : "is-drop-down")
  }

  choose(event) {
    this.selectTheme(event.currentTarget.dataset.themeValue)
    event.currentTarget.closest("details")?.removeAttribute("open")
  }

  move(event) {
    const group = event.currentTarget
    const options = [...group.querySelectorAll('[role="radio"]')]
    const current = event.target.closest('[role="radio"]')
    if (!current || !options.includes(current)) return

    const index = options.indexOf(current)
    let next = index
    if (event.key === "ArrowDown" || event.key === "ArrowRight") next = (index + 1) % options.length
    else if (event.key === "ArrowUp" || event.key === "ArrowLeft") next = (index - 1 + options.length) % options.length
    else if (event.key === "Home") next = 0
    else if (event.key === "End") next = options.length - 1
    else return

    event.preventDefault()
    const option = options[next]
    this.selectTheme(option.dataset.themeValue)
    option.focus()
  }

  cycle() {
    const next = THEMES[(THEMES.indexOf(this.storedTheme()) + 1) % THEMES.length]
    this.selectTheme(next)
  }

  selectTheme(theme) {
    if (!THEMES.includes(theme)) return
    this.persist(theme)
    this.apply(theme)
    this.sync()
  }

  storedTheme() {
    return document.documentElement.getAttribute("data-theme") || "system"
  }

  persist(theme) {
    document.cookie = `${COOKIE}=${theme}; path=/; max-age=31536000; SameSite=Lax`
    document.documentElement.setAttribute("data-theme", theme)
  }

  apply(theme) {
    const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches
    const resolved = theme === "dark" || (theme === "system" && prefersDark) ? "dark" : "light"
    document.documentElement.classList.toggle("dark", resolved === "dark")
  }

  sync() {
    const theme = this.storedTheme()
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.caption(theme)
    }
    this.optionTargets.forEach((option) => {
      const selected = option.dataset.themeValue === theme
      option.setAttribute("aria-checked", selected ? "true" : "false")
      option.tabIndex = selected ? 0 : -1
      option.classList.toggle("is-selected", selected)
    })
  }

  caption(theme) {
    if (theme === "light") return "Light"
    if (theme === "dark") return "Dark"
    return "System"
  }
}
