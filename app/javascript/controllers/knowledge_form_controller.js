import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "kind", "urlFields", "externalFields", "uploadFields", "contentFields" ]

  connect() {
    this.sync()
  }

  sync() {
    const kind = this.hasKindTarget ? this.kindTarget.value : "manual"
    this.toggle(this.urlFieldsTargets, kind === "url")
    this.toggle(this.externalFieldsTargets, kind === "intercom_help_center")
    this.toggle(this.uploadFieldsTargets, kind === "upload")
    this.toggle(this.contentFieldsTargets, kind !== "upload")
  }

  toggle(elements, visible) {
    elements.forEach((element) => {
      element.hidden = !visible
    })
  }
}
