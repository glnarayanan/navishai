import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "panel", "trigger"]

  connect() {
    this.previouslyFocused = null
    this.onClose = () => this.afterClose()
    this.onKey = (event) => this.trap(event)
    if (this.hasDialogTarget) {
      this.dialogTarget.addEventListener("close", this.onClose)
      this.dialogTarget.addEventListener("keydown", this.onKey)
    }
  }

  disconnect() {
    if (this.hasDialogTarget) {
      this.dialogTarget.removeEventListener("close", this.onClose)
      this.dialogTarget.removeEventListener("keydown", this.onKey)
    }
    document.documentElement.classList.remove("is-nav-open")
  }

  open(event) {
    if (!this.hasDialogTarget || this.dialogTarget.open) return

    this.previouslyFocused = event?.currentTarget || document.activeElement
    this.dialogTarget.showModal()
    this.element.classList.add("is-nav-open")
    document.documentElement.classList.add("is-nav-open")
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", "true"))
    this.focusFirst()
  }

  close() {
    if (this.hasDialogTarget && this.dialogTarget.open) this.dialogTarget.close()
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  trap(event) {
    if (event.key !== "Tab" || !this.hasPanelTarget) return
    const nodes = this.focusables()
    if (!nodes.length) return
    const first = nodes[0]
    const last = nodes[nodes.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  focusables() {
    return [...this.panelTarget.querySelectorAll("a, button, select, input, textarea, [tabindex]:not([tabindex='-1'])")]
      .filter((node) => !node.disabled && node.getClientRects().length > 0)
  }

  afterClose() {
    this.element.classList.remove("is-nav-open")
    document.documentElement.classList.remove("is-nav-open")
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", "false"))
    const restore = this.previouslyFocused
    this.previouslyFocused = null
    queueMicrotask(() => {
      if (restore && typeof restore.focus === "function") restore.focus()
    })
  }

  focusFirst() {
    this.focusables()[0]?.focus()
  }
}
