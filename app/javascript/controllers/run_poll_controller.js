import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { active: Boolean, etag: String, interval: { type: Number, default: 3000 }, url: String }

  connect() {
    if (!this.activeValue) return

    this.timer = window.setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
  }

  async refresh() {
    if (document.hidden || this.refreshing) return
    this.refreshing = true

    try {
      const headers = { "Accept": "text/html", "Turbo-Frame": this.element.id }
      if (this.etagValue) headers["If-None-Match"] = this.etagValue
      const response = await fetch(this.urlValue, {
        headers,
        cache: "no-store"
      })
      if (response.status === 304) return
      if (!response.ok) return

      const parsed = new DOMParser().parseFromString(await response.text(), "text/html")
      const replacement = parsed.getElementById(this.element.id)
      if (replacement) {
        replacement.dataset.runPollEtagValue = response.headers.get("ETag") || ""
        this.element.replaceWith(replacement)
      }
    } catch {
      // A later poll can recover from a transient navigation or network failure.
    } finally {
      this.refreshing = false
    }
  }
}
