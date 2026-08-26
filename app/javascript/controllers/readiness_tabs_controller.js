import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "supportOnly", "successOnly"]

  select(event) {
    const value = event.currentTarget.dataset.readinessTab
    this.tabTargets.forEach((tab) => {
      const selected = tab === event.currentTarget
      tab.classList.toggle("is-active", selected)
      tab.setAttribute("aria-selected", selected ? "true" : "false")
    })
    this.supportOnlyTargets.forEach((node) => { node.hidden = value !== "support" })
    this.successOnlyTargets.forEach((node) => { node.hidden = value !== "success" })
  }
}
