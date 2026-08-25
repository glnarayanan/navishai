import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dialog", "panel"]

  connect() {
    this.previouslyFocused = null
  }

  open() {
    this.previouslyFocused = document.activeElement
    this.dialogTarget.showModal()
    this.panelTarget.querySelector("a, button")?.focus()
  }

  close() {
    if (this.dialogTarget.open) this.dialogTarget.close()
    this.previouslyFocused?.focus?.()
  }

  backdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }

  keydown(event) {
    if (event.key === "Escape") this.close()
  }
}
