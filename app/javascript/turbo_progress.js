import { Turbo } from "@hotwired/turbo-rails"

function disableProgressBar(bar) {
  if (!bar || bar.datasetDisabled) return
  bar.datasetDisabled = true
  bar.show = () => {}
  bar.hide = () => {}
  bar.setValue = () => {}
  bar.refresh = () => {}
  bar.installStylesheetElement = () => {}
  bar.uninstallStylesheetElement = () => {}
  bar.installProgressElement = () => {}
  bar.startTrickling = () => {}
  const proto = Object.getPrototypeOf(bar)
  if (proto && proto !== Object.prototype) {
    proto.show = () => {}
    proto.hide = () => {}
    proto.setValue = () => {}
    proto.refresh = () => {}
    proto.installStylesheetElement = () => {}
    proto.uninstallStylesheetElement = () => {}
    proto.installProgressElement = () => {}
    proto.startTrickling = () => {}
  }
}

function disableInlineProgressBar() {
  disableProgressBar(Turbo.navigator?.delegate?.adapter?.progressBar)
  disableProgressBar(Turbo.session?.adapter?.progressBar)
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
