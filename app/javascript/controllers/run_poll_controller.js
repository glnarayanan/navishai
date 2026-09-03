import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { active: Boolean, etag: String, interval: { type: Number, default: 3000 }, url: String }

  connect() {
    if (!this.activeValue) return

    this.timer = window.setInterval(() => this.refresh(), this.intervalValue)
  }

  disconnect() {
    if (this.timer) window.clearInterval(this.timer)
    this.abortController?.abort()
    this.abortController = null
  }

  async refresh() {
    if (document.hidden || this.refreshing) return
    this.refreshing = true
    this.abortController = new AbortController()
    const { signal } = this.abortController

    try {
      const headers = { "Accept": "text/html", "Turbo-Frame": this.element.id }
      if (this.etagValue) headers["If-None-Match"] = this.etagValue
      const response = await fetch(this.urlValue, {
        headers,
        cache: "no-store",
        signal
      })
      if (response.status === 304) {
        this.clearPollError()
        return
      }
      if (!response.ok) {
        this.showPollError()
        return
      }

      const parsed = new DOMParser().parseFromString(await response.text(), "text/html")
      const replacement = parsed.getElementById(this.element.id)
      if (replacement) {
        replacement.dataset.runPollEtagValue = response.headers.get("ETag") || ""
        const openDetails = [...this.element.querySelectorAll("details")].map((details) => details.open)
        replacement.querySelectorAll("details").forEach((details, index) => {
          if (openDetails[index]) details.open = true
        })
        this.element.replaceWith(replacement)
      }
    } catch (error) {
      if (error?.name === "AbortError") return
      this.showPollError()
    } finally {
      if (this.abortController?.signal === signal) this.abortController = null
      this.refreshing = false
    }
  }

  showPollError() {
    if (!this.element.isConnected || this.element.querySelector(".run-poll-error")) return
    const template = this.element.querySelector("[data-run-poll-error-template]")
    const heading = this.element.querySelector(".execution-heading")
    const notice = template?.content.firstElementChild?.cloneNode(true)
    if (!notice || !heading) return
    heading.after(notice)
  }

  clearPollError() {
    this.element.querySelector(".run-poll-error")?.remove()
  }
}
