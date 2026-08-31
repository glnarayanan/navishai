import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["provider", "authMode", "apiKeyField", "apiKey", "model", "description"]

  connect() {
    this.sync()
  }

  providerChanged() {
    const option = this.providerTarget.selectedOptions[0]
    if (!option) return

    const modes = (option.dataset.authModes || "").split(",").filter(Boolean)
    const current = this.authModeTarget.value
    this.authModeTarget.replaceChildren(...modes.map((mode) => {
      const item = document.createElement("option")
      item.value = mode
      item.textContent = this.label(mode)
      item.selected = mode === current
      return item
    }))
    if (!modes.includes(current)) this.authModeTarget.value = modes[0] || ""
    this.descriptionTarget.textContent = option.dataset.description || ""
    this.modelTarget.required = option.dataset.modelRequired === "true"
    this.apiKeyTarget.dataset.secretConfigured = option.dataset.secretConfigured || "false"
    this.sync()
  }

  authChanged() {
    this.sync()
  }

  sync() {
    const usesKey = this.authModeTarget.value === "api_key"
    this.apiKeyFieldTarget.hidden = !usesKey
    this.apiKeyTarget.disabled = !usesKey
    this.apiKeyTarget.required = usesKey && this.secretConfigured() !== "true"
  }

  secretConfigured() {
    if (this.hasProviderTarget) {
      return this.providerTarget.selectedOptions[0]?.dataset.secretConfigured || "false"
    }
    return this.apiKeyTarget.dataset.secretConfigured || "false"
  }

  label(value) {
    if (value === "api_key") return "API key"
    return value.split("_").map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`).join(" ")
  }
}
