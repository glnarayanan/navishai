const STYLE_MARK = ".turbo-progress-bar"
const BAR_CLASS = "turbo-progress-bar"

function isTurboProgressStyle(node) {
  return node instanceof HTMLStyleElement && (node.textContent || "").includes(STYLE_MARK)
}

function isTurboProgressBar(node) {
  return node instanceof HTMLElement && node.classList?.contains(BAR_CLASS)
}

function muteInlineStyle(element) {
  if (element.__navishaiStyleMuted) return
  element.__navishaiStyleMuted = true
  const dummy = new Proxy({}, {
    get(_target, prop) {
      if (prop === "setProperty" || prop === "removeProperty" || prop === "getPropertyValue") {
        return () => ""
      }
      return ""
    },
    set() {
      return true
    }
  })
  Object.defineProperty(element, "style", {
    configurable: true,
    get() { return dummy }
  })
}

function shouldSwallow(node) {
  return isTurboProgressStyle(node) || isTurboProgressBar(node)
}

const nativeInsertBefore = Node.prototype.insertBefore
Node.prototype.insertBefore = function (node, child) {
  if (shouldSwallow(node)) return node
  return nativeInsertBefore.call(this, node, child)
}

const nativeAppendChild = Node.prototype.appendChild
Node.prototype.appendChild = function (node) {
  if (shouldSwallow(node)) return node
  return nativeAppendChild.call(this, node)
}

const nativeAppend = Element.prototype.append
Element.prototype.append = function (...nodes) {
  const allowed = nodes.filter((node) => !shouldSwallow(node))
  if (!allowed.length) return
  return nativeAppend.apply(this, allowed)
}

const classNameDescriptor = Object.getOwnPropertyDescriptor(Element.prototype, "className")
if (classNameDescriptor?.set) {
  Object.defineProperty(Element.prototype, "className", {
    configurable: true,
    enumerable: classNameDescriptor.enumerable,
    get() { return classNameDescriptor.get.call(this) },
    set(value) {
      classNameDescriptor.set.call(this, value)
      if (String(value).includes(BAR_CLASS)) muteInlineStyle(this)
    }
  })
}
