import { Controller } from "@hotwired/stimulus"

const COOKIE = "navishai_theme"
const THEMES = ["system", "light", "dark"]

export default class extends Controller {
  static targets = ["option"]

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
    this.selectTheme(event.currentTarget.dataset.themeValue)
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
    this.optionTargets.forEach((option) => {
      const selected = option.dataset.themeValue === theme
      option.setAttribute("aria-checked", selected ? "true" : "false")
      option.tabIndex = selected ? 0 : -1
    })
  }
}
