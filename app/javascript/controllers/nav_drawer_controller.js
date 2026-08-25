import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "panel", "trigger"]

  connect() {
    this.previouslyFocused = null
    this.onClose = () => this.afterClose()
    if (this.hasDialogTarget) {
      this.dialogTarget.addEventListener("close", this.onClose)
    }
  }

  disconnect() {
    this.dialogTarget?.removeEventListener("close", this.onClose)
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

  afterClose() {
    this.element.classList.remove("is-nav-open")
    document.documentElement.classList.remove("is-nav-open")
    this.triggerTargets.forEach((trigger) => trigger.setAttribute("aria-expanded", "false"))
    if (this.previouslyFocused && typeof this.previouslyFocused.focus === "function") {
      this.previouslyFocused.focus()
    }
    this.previouslyFocused = null
  }

  focusFirst() {
    const first = this.panelTarget.querySelector("a, button, select, input, [tabindex]:not([tabindex='-1'])")
    first?.focus()
  }
}
