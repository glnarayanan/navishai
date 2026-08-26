import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tooltip", "stem", "fill", "line", "dot"]
  static values = {
    scores: { type: Array, default: [20, 30, 25, 45, 40, 55, 75] },
    tooltips: { type: Array, default: [1234, 1678, 2101, 2534, 2967, 3400, 3833] }
  }

  connect() {
    this.index = Math.floor(this.scoresValue.length / 2)
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    this.draw()
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) this.start()
        else this.stop()
      })
    }, { threshold: 0.4 })
    this.observer.observe(this.element)
  }

  disconnect() {
    this.observer?.disconnect()
    this.stopTimer()
    this.stage()?.classList.remove("is-on")
  }

  start() {
    this.stage()?.classList.add("is-on")
    this.render()
    if (this.reduced) return
    this.stopTimer()
    this.timer = window.setInterval(() => {
      this.index = (this.index + 1) % this.scoresValue.length
      this.render()
    }, 1800)
  }

  stage() {
    return this.element.querySelector(".health-stage")
  }

  stopTimer() {
    if (this.timer) window.clearInterval(this.timer)
    this.timer = null
  }

  stop() {
    this.stage()?.classList.remove("is-on")
    this.stopTimer()
  }

  draw() {
    const width = 600
    const height = 200
    const scores = this.scoresValue
    const max = Math.max(...scores, 1)
    const points = scores.map((score, i) => ({
      x: (i / Math.max(scores.length - 1, 1)) * width,
      y: height - (score / max) * height * 0.8
    }))
    this.points = points
    const line = this.smoothPath(points)
    const fill = `${line} L ${width} ${height} L 0 ${height} Z`
    if (this.hasLineTarget) this.lineTarget.setAttribute("d", line)
    if (this.hasFillTarget) this.fillTarget.setAttribute("d", fill)
  }

  smoothPath(points) {
    if (points.length === 0) return ""
    return points.reduce((path, point, i, arr) => {
      if (i === 0) return `M ${point.x} ${point.y}`
      const prev = arr[i - 1]
      const next = arr[i + 1] || point
      const cp1x = prev.x + (point.x - prev.x) * 0.35
      const cp1y = prev.y + (point.y - prev.y) * 0.35
      const cp2x = point.x - ((next.x - prev.x) * 0.15)
      const cp2y = point.y - ((next.y - prev.y) * 0.15)
      return `${path} C ${cp1x} ${cp1y} ${cp2x} ${cp2y} ${point.x} ${point.y}`
    }, "")
  }

  render() {
    const point = this.points?.[this.index]
    if (!point) return
    const score = this.tooltipsValue[this.index] || this.scoresValue[this.index]
    if (this.hasTooltipTarget) {
      this.tooltipTarget.textContent = String(score)
      this.tooltipTarget.style.left = `calc(${(point.x / 600) * 100}% - 1.5rem)`
      this.tooltipTarget.style.top = `calc(${(point.y / 200) * 70}% + 1.5rem)`
    }
    if (this.hasDotTarget) {
      this.dotTarget.setAttribute("cx", String(point.x))
      this.dotTarget.setAttribute("cy", String(point.y))
    }
    this.element.querySelectorAll(".chart-pulse").forEach((pulse) => {
      pulse.setAttribute("cx", String(point.x))
      pulse.setAttribute("cy", String(point.y))
    })
    if (this.hasStemTarget) {
      this.stemTarget.style.left = `${(point.x / 600) * 100}%`
      this.stemTarget.style.top = `calc(${(point.y / 200) * 70}% + 2.25rem)`
    }
  }
}
