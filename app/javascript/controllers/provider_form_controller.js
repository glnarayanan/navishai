import { Controller } from "@hotwired/stimulus"

const MODEL_DISCOVERY_TIMEOUT_MS = 22_000

export default class extends Controller {
  static targets = [
    "provider", "authMode", "apiKeyField", "apiKey", "model", "modelLabel", "modelHint", "apiKeyHint", "description",
    "executionField", "executionMode", "executionHint", "modelDiscovery", "modelRefresh", "modelState", "modelSelectField",
    "discoveredModels", "manualModelField"
  ]

  connect() {
    this.disconnected = false
    this.modelsAbortController = null
    this.modelsTimeout = null
    this.modelsGeneration = 0
    this.beforeCache = () => this.prepareForCache()
    document.addEventListener("turbo:before-cache", this.beforeCache)
    this.sync()
    if (this.hasModelDiscoveryTarget) {
      this.discoveryBlocked = false
      this.syncDiscoveryAvailability()
      if (!this.discoveryBlocked) {
        this.refreshModels()
      }
    } else {
      this.discoveryBlocked = false
    }
  }

  disconnect() {
    this.disconnected = true
    this.modelsGeneration += 1
    if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
    this.modelsTimeout = null
    this.modelsAbortController?.abort()
    document.removeEventListener("turbo:before-cache", this.beforeCache)
    this.modelsAbortController = null
  }

  providerChanged() {
    const option = this.providerMetadata()
    if (!option) return

    this.modelTarget.value = ""
    this.apiKeyTarget.value = ""
    const modes = this.dataList(option, "authModes")
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
    this.modelTarget.dataset.modelRequired = modelRequired.toString()
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

    this.syncDiscoveryAvailability()
  }

  executionChanged() {
    this.sync()
    if (!this.hasModelDiscoveryTarget) return

    this.syncDiscoveryAvailability()
  }

  async refreshModels(event) {
    event?.preventDefault()
    if (!this.hasModelDiscoveryTarget || this.discoveryBlocked) return

    this.modelsAbortController?.abort()
    if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
    this.modelsTimeout = null
    const controller = new AbortController()
    const generation = ++this.modelsGeneration
    let timedOut = false
    this.modelsAbortController = controller
    this.modelsTimeout = setTimeout(() => {
      if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return

      timedOut = true
      controller.abort()
    }, MODEL_DISCOVERY_TIMEOUT_MS)
    this.modelRefreshTarget.disabled = true
    this.modelRefreshTarget.textContent = "Finding models…"
    this.modelDiscoveryTarget.setAttribute("aria-busy", "true")
    this.modelSelectFieldTarget.hidden = true
    this.useManualModel()
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
        body: new URLSearchParams({ adapter_key: this.adapterKey(), execution_mode: this.executionModeTarget.value }),
        signal: controller.signal
      })

      if (!response.ok) {
        if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return
        if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
        this.modelsTimeout = null
        this.showModelState(response.status === 503 ? "unavailable" : response.status === 409 ? "conflict" : "failed")
        return
      }

      const payload = await response.json()
      if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return
      if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
      this.modelsTimeout = null
      this.renderModels(payload)
    } catch (error) {
      if (this.modelsGeneration !== generation || this.modelsAbortController !== controller || this.disconnected) return
      if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
      this.modelsTimeout = null
      if (error.name === "AbortError") {
        if (timedOut) this.showModelState("unavailable")
        return
      }
      this.showModelState("unavailable")
    } finally {
      if (this.modelsGeneration !== generation || this.modelsAbortController !== controller) return
      if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
      this.modelsTimeout = null
      this.modelsAbortController = null
      this.modelRefreshTarget.disabled = false
      this.modelRefreshTarget.textContent = "Refresh models"
      this.modelDiscoveryTarget.removeAttribute("aria-busy")
    }
  }

  modelDiscovered() {
    const option = this.discoveredModelsTarget.selectedOptions[0]
    const model = option?.value || ""
    if (!model || option?.dataset.manual === "true") {
      this.useManualModel()
      return
    }

    this.modelTarget.value = model
    this.modelTarget.disabled = true
    this.modelTarget.removeAttribute("name")
    this.manualModelFieldTarget.hidden = true
    this.discoveredModelsTarget.disabled = false
    this.discoveredModelsTarget.name = "provider_connection[model]"
    this.modelTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  prepareForCache() {
    if (this.hasApiKeyTarget) this.apiKeyTarget.value = ""
    this.modelsGeneration += 1
    if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
    this.modelsTimeout = null
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

  providerMetadata() {
    if (!this.hasProviderTarget) return null

    return this.providerTarget.selectedOptions?.[0] || this.providerTarget
  }

  dataList(element, name) {
    return (element?.dataset?.[name] || "").split(",").filter(Boolean)
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

    const currentModel = this.modelTarget.value
    this.resetDiscoveredModels()
    const discoveredIds = new Set(models.map((model) => model.id))
    if (currentModel && !discoveredIds.has(currentModel)) {
      const currentOption = document.createElement("option")
      currentOption.value = currentModel
      currentOption.textContent = `Current model (${currentModel})`
      currentOption.selected = true
      this.discoveredModelsTarget.append(currentOption)
    }
    models.forEach((model) => {
      const option = document.createElement("option")
      option.value = model.id
      option.selected = model.id === currentModel
      option.textContent = `${model.label} (${model.id})${model.default ? " — default" : ""}`
      this.discoveredModelsTarget.append(option)
    })
    this.modelSelectFieldTarget.hidden = false
    this.modelTarget.disabled = true
    this.modelTarget.removeAttribute("name")
    this.manualModelFieldTarget.hidden = true
    this.discoveredModelsTarget.disabled = false
    this.discoveredModelsTarget.name = "provider_connection[model]"
    this.discoveredModelsTarget.required = false
    this.setModelState("Models found. Choose one, or enter an exact ID manually.", "available")
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
      unavailable: "Model discovery is unavailable. Enter the exact model ID manually or refresh.",
      conflict: "Provider settings changed. Save the current sign-in method and execution boundary before refreshing models."
    }
    this.modelSelectFieldTarget.hidden = true
    this.resetDiscoveredModels()
    this.useManualModel()
    this.setModelState(messages[status] || messages.failed, status)
  }

  setModelState(message, state) {
    this.modelStateTarget.textContent = message
    this.modelStateTarget.dataset.state = state
  }

  blockModelDiscovery() {
    this.discoveryBlocked = true
    this.modelsGeneration += 1
    if (this.modelsTimeout !== null) clearTimeout(this.modelsTimeout)
    this.modelsTimeout = null
    this.modelsAbortController?.abort()
    this.modelsAbortController = null
    this.modelSelectFieldTarget.hidden = true
    this.resetDiscoveredModels()
    this.useManualModel()
    this.modelRefreshTarget.disabled = true
    this.modelRefreshTarget.textContent = "Refresh after saving"
    this.modelDiscoveryTarget.removeAttribute("aria-busy")
    this.setModelState("Save sign-in or execution-boundary changes before refreshing models.", "blocked")
  }

  syncDiscoveryAvailability() {
    const settingsChanged = this.authModeTarget.value !== this.modelDiscoveryTarget.dataset.savedAuthMode ||
      this.executionModeTarget.value !== this.modelDiscoveryTarget.dataset.savedExecutionMode
    if (settingsChanged) {
      this.blockModelDiscovery()
      return
    }

    if (!this.discoveryBlocked) return

    this.discoveryBlocked = false
    this.modelRefreshTarget.disabled = false
    this.modelRefreshTarget.textContent = "Refresh models"
    this.modelDiscoveryTarget.removeAttribute("aria-busy")
    this.setModelState("Model suggestions load here when available.", "idle")
  }

  resetDiscoveredModels() {
    const placeholder = document.createElement("option")
    placeholder.value = ""
    placeholder.textContent = "Choose a discovered model"
    const manual = document.createElement("option")
    manual.value = ""
    manual.dataset.manual = "true"
    manual.textContent = "Enter an exact model ID manually"
    this.discoveredModelsTarget.replaceChildren(placeholder, manual)
    this.discoveredModelsTarget.disabled = true
    this.discoveredModelsTarget.removeAttribute("name")
  }

  useManualModel() {
    const shouldFocus = !this.modelSelectFieldTarget.hidden
    this.modelTarget.disabled = false
    this.modelTarget.name = "provider_connection[model]"
    this.manualModelFieldTarget.hidden = false
    this.discoveredModelsTarget.disabled = this.modelSelectFieldTarget.hidden
    this.discoveredModelsTarget.removeAttribute("name")
    this.discoveredModelsTarget.required = false
    this.sync()
    if (shouldFocus) this.modelTarget.focus()
  }

  modelLabel(required) {
    if (required && this.hasModelDiscoveryTarget) return "Exact model ID (manual)"
    return required ? "Model ID" : "Model override (optional)"
  }

  modelHint(required) {
    if (required && this.hasModelDiscoveryTarget) return "Use this only when the model is not listed above."
    return required
      ? "Save without a model to load live choices, or enter an exact model ID now."
      : "Leave blank to use the provider default. Enter an exact model ID only to override it."
  }

  apiKeyHint(secretConfigured) {
    return secretConfigured === "true"
      ? "A key is already saved. Leave this blank to keep it."
      : "Stored encrypted on this self-hosted deployment and never shown again."
  }

  sync() {
    this.syncExecutionMode()
    const usesKey = this.authModeTarget.value === "api_key"
    const modelRequired = this.modelTarget.dataset.modelRequired === "true" || usesKey
    this.apiKeyFieldTarget.hidden = !usesKey
    this.apiKeyTarget.disabled = !usesKey
    this.apiKeyTarget.required = usesKey && this.secretConfigured() !== "true"
    this.modelTarget.required = false
    this.modelLabelTarget.textContent = this.modelLabel(modelRequired)
    this.modelHintTarget.textContent = this.modelHint(modelRequired)
  }

  secretConfigured() {
    return this.providerMetadata()?.dataset.secretConfigured || this.apiKeyTarget.dataset.secretConfigured || "false"
  }

  syncExecutionMode() {
    if (!this.hasExecutionModeTarget) return

    const metadata = this.providerMetadata()
    const supported = this.dataList(metadata, "supportedExecutionModes")
    const usesKey = this.authModeTarget.value === "api_key"
    if (this.hasExecutionFieldTarget) this.executionFieldTarget.hidden = usesKey
    const modes = supported.filter((mode) => usesKey ? mode === "bounded" : mode !== "bounded")
    const current = this.executionModeTarget.value
    const selected = modes.includes(current)
      ? current
      : usesKey
        ? modes[0] || ""
        : modes.length === 1
          ? modes[0]
          : ""

    const options = []
    if (!selected) {
      const option = document.createElement("option")
      option.value = ""
      option.textContent = modes.length === 0 ? "No runnable boundary reported; reconfigure the runner" : "Choose an execution boundary"
      option.selected = true
      options.push(option)
    }
    options.push(...modes.map((mode) => {
      const option = document.createElement("option")
      option.value = mode
      option.textContent = this.executionModeLabel(mode)
      option.selected = mode === selected
      return option
    }))
    this.executionModeTarget.replaceChildren(...options)
    this.executionModeTarget.value = selected
    this.executionModeTarget.disabled = modes.length === 0
    this.executionModeTarget.required = modes.length > 0
    this.executionHintTarget.textContent = this.executionModeHint(selected, usesKey, modes.length)
  }

  executionModeLabel(mode) {
    return {
      bounded: "Bounded HTTPS",
      host_trusted: "Host-trusted",
      strong_isolated: "Strong-isolated"
    }[mode] || this.label(mode)
  }

  executionModeHint(mode, usesKey, modeCount) {
    if (modeCount === 0) return "No runnable execution boundary was reported for this sign-in method. Reconfigure the runner before saving."
    if (usesKey) return "API-key connections use the runner's bounded HTTPS path."
    if (mode === "host_trusted") {
      return "Uses the runner user's existing provider session. This process is not isolated from that account."
    }
    if (mode === "strong_isolated") {
      return "Uses the runner's strong-isolated provider boundary. This choice appears only when the runner reports it."
    }
    return "Choose an execution boundary reported by this runner."
  }

  label(value) {
    if (value === "api_key") return "API key"
    return value.split("_").map((part) => `${part.charAt(0).toUpperCase()}${part.slice(1)}`).join(" ")
  }
}
