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
  }

  disconnect() {
    this.media?.removeEventListener("change", this.mediaListener)
  }

  choose(event) {
    const theme = event.currentTarget.dataset.themeValue
    if (!THEMES.includes(theme)) return
    this.persist(theme)
    this.apply(theme)
    this.sync()
    event.currentTarget.closest("details")?.removeAttribute("open")
  }

  cycle() {
    const next = THEMES[(THEMES.indexOf(this.storedTheme()) + 1) % THEMES.length]
    this.persist(next)
    this.apply(next)
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
    document.documentElement.style.colorScheme = resolved
  }

  sync() {
    const theme = this.storedTheme()
    if (this.hasLabelTarget) {
      this.labelTarget.textContent = this.caption(theme)
    }
    this.optionTargets.forEach((option) => {
      const selected = option.dataset.themeValue === theme
      option.setAttribute("aria-checked", selected ? "true" : "false")
      option.classList.toggle("is-selected", selected)
    })
  }

  caption(theme) {
    if (theme === "light") return "Light"
    if (theme === "dark") return "Dark"
    return "System"
  }
}
