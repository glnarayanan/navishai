import { Turbo } from "@hotwired/turbo-rails"

function disableInlineProgressBar() {
  const bar = Turbo.navigator?.delegate?.adapter?.progressBar
  if (!bar || bar.datasetDisabled) return
  bar.datasetDisabled = true
  bar.show = () => {}
  bar.hide = () => {}
  bar.setValue = () => {}
  bar.installStylesheetElement = () => {}
  bar.uninstallStylesheetElement = () => {}
}

function markFetching(busy) {
  document.documentElement.classList.toggle("is-fetching", busy)
}

disableInlineProgressBar()
document.addEventListener("turbo:load", disableInlineProgressBar)
document.addEventListener("turbo:before-fetch-request", () => markFetching(true))
document.addEventListener("turbo:before-fetch-response", () => markFetching(false))
document.addEventListener("turbo:fetch-request-error", () => markFetching(false))
document.addEventListener("turbo:load", () => markFetching(false))
