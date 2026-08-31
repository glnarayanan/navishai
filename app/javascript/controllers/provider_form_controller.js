import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "provider", "authMode", "apiKeyField", "apiKey", "model", "modelLabel", "modelHint", "apiKeyHint", "description",
    "modelDiscovery", "modelRefresh", "modelState", "modelSelectField", "discoveredModels"
  ]

  connect() {
    this.disconnected = false
    this.modelsAbortController = null
    this.modelsGeneration = 0
    this.beforeCache = () => this.prepareForCache()
    document.addEventListener("turbo:before-cache", this.beforeCache)
    this.sync()
    if (this.hasModelDiscoveryTarget) {
      this.discoveryBlocked = this.modelStateTarget.dataset.state === "blocked" ||
        this.authModeTarget.value !== this.modelDiscoveryTarget.dataset.savedAuthMode
      if (this.discoveryBlocked) {
        this.blockModelDiscovery()
      } else {
        this.refreshModels()
      }
    } else {
      this.discoveryBlocked = false
    }
  }

  disconnect() {
    this.disconnected = true
    this.modelsGeneration += 1
    this.modelsAbortController?.abort()
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    this.modelsAbortController = null
  }

  providerChanged() {
    const option = this.providerTarget.selectedOptions[0]
    if (!option) return

    this.modelTarget.value = ""
    this.apiKeyTarget.value = ""
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
    const modelRequired = option.dataset.modelRequired === "true"
    this.modelTarget.required = modelRequired
    this.modelLabelTarget.textContent = this.modelLabel(modelRequired)
    this.modelHintTarget.textContent = this.modelHint(modelRequired)
    const secretConfigured = option.dataset.secretConfigured || "false"
    this.apiKeyTarget.dataset.secretConfigured = secretConfigured
    this.apiKeyHintTarget.textContent = this.apiKeyHint(secretConfigured)
    this.sync()
  }

  authChanged() {
    this.apiKeyTarget.value = ""
    this.modelTarget.value = ""
    this.sync()
    if (!this.hasModelDiscoveryTarget) return

    this.blockModelDiscovery()
  }

  async refreshModels(event) {
    event?.preventDefault()
    if (!this.hasModelDiscoveryTarget || this.discoveryBlocked) return

    this.modelsAbortController?.abort()
    const controller = new AbortController()
    const generation = ++this.modelsGeneration
    this.modelsAbortController = controller
    this.modelRefreshTarget.disabled = true
    this.modelRefreshTarget.textContent = "Finding models…"
    this.modelDiscoveryTarget.setAttribute("aria-busy", "true")
    this.modelSelectFieldTarget.hidden = true
    this.setModelState("Checking available models…", "loading")

    try {
      const response = await fetch(this.modelDiscoveryTarget.dataset.modelsUrl, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": this.csrfToken(),
          "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8"
        },
        body: new URLSearchParams({ adapter_key: this.adapterKey() }),
        signal: controller.signal
      })

      if (!response.ok) {
        if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return
        this.showModelState(response.status === 503 ? "unavailable" : "failed")
        return
      }

      const payload = await response.json()
      if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return
      this.renderModels(payload)
    } catch (error) {
      if (error.name === "AbortError" || this.disconnected) return
      if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return
      this.showModelState("unavailable")
    } finally {
      if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return
      this.modelsAbortController = null
      this.modelRefreshTarget.disabled = false
      this.modelRefreshTarget.textContent = "Refresh models"
      this.modelDiscoveryTarget.removeAttribute("aria-busy")
    }
  }

  modelDiscovered() {
    const model = this.discoveredModelsTarget.value
    if (!model) return

    this.modelTarget.value = model
    this.modelTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  prepareForCache() {
    if (this.hasApiKeyTarget) this.apiKeyTarget.value = ""
    this.modelsGeneration += 1
    this.modelsAbortController?.abort()
    this.modelsAbortController = null
    if (!this.hasModelDiscoveryTarget) return

    this.modelDiscoveryTarget.removeAttribute("aria-busy")
    if (this.discoveryBlocked) {
      this.modelRefreshTarget.disabled = true
      this.modelRefreshTarget.textContent = "Refresh after saving"
      return
    }

    this.modelRefreshTarget.disabled = false
    this.modelRefreshTarget.textContent = "Refresh models"
    if (this.modelStateTarget.dataset.state === "loading") {
      this.setModelState("Model suggestions load here when available.", "idle")
    }
  }

  adapterKey() {
    return this.element.querySelector("[name='provider_connection[adapter_key]']")?.value || ""
  }

  csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content || ""
  }

  renderModels(payload) {
    if (!payload || !["available", "unsupported", "failed"].includes(payload.status)) {
      this.showModelState("failed")
      return
    }

    if (payload.status !== "available") {
      this.showModelState(payload.status)
      return
    }

    const models = Array.isArray(payload.models) ? payload.models.filter((model) => this.validModel(model)) : []
    if (models.length === 0) {
      this.showModelState("failed")
      return
    }

    this.resetDiscoveredModels()
    models.forEach((model) => {
      const option = document.createElement("option")
      option.value = model.id
      option.textContent = `${model.label} (${model.id})${model.default ? " — default" : ""}`
      this.discoveredModelsTarget.append(option)
    })
    this.modelSelectFieldTarget.hidden = false
    this.setModelState("Models found. Choose one to copy its exact ID, or enter an exact ID manually.", "available")
  }

  validModel(model) {
    return model && typeof model.id === "string" && model.id.length > 0 &&
      typeof model.label === "string" && model.label.length > 0 &&
      !/[\u0000-\u001f\u007f]/.test(model.id) && !/[\u0000-\u001f\u007f]/.test(model.label)
  }

  showModelState(status) {
    const messages = {
      unsupported: "Model suggestions are not available for this provider. Enter the exact model ID manually.",
      failed: "Models could not be loaded. Enter the exact model ID manually or refresh.",
      unavailable: "Model discovery is unavailable. Enter the exact model ID manually or refresh."
    }
    this.modelSelectFieldTarget.hidden = true
    this.setModelState(messages[status] || messages.failed, status)
  }

  setModelState(message, state) {
    this.modelStateTarget.textContent = message
    this.modelStateTarget.dataset.state = state
  }

  blockModelDiscovery() {
    this.discoveryBlocked = true
    this.modelsGeneration += 1
    this.modelsAbortController?.abort()
    this.modelsAbortController = null
    this.modelSelectFieldTarget.hidden = true
    this.resetDiscoveredModels()
    this.modelRefreshTarget.disabled = true
    this.modelRefreshTarget.textContent = "Refresh after saving"
    this.modelDiscoveryTarget.removeAttribute("aria-busy")
    this.setModelState("Save sign-in changes before refreshing models.", "blocked")
  }

  resetDiscoveredModels() {
    const placeholder = document.createElement("option")
    placeholder.value = ""
    placeholder.textContent = "Choose a model to copy its exact ID"
    this.discoveredModelsTarget.replaceChildren(placeholder)
  }

  modelLabel(required) {
    return required ? "Model ID" : "Model override (optional)"
  }

  modelHint(required) {
    return required
      ? "Enter the exact model ID enabled for this account. Choose a suggestion when available, or enter an ID manually."
      : "Leave blank to use the provider default. Enter an exact model ID only to override it."
  }

  apiKeyHint(secretConfigured) {
    return secretConfigured === "true"
      ? "A key is already saved. Leave this blank to keep it."
      : "Stored encrypted on this self-hosted deployment and never shown again."
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
