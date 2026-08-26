import "turbo_progress_guard"
import "@hotwired/turbo-rails"
import "turbo_progress"
import "controllers"

function resetHorizontalRouteScroll() {
  document.documentElement.scrollLeft = 0
  document.body.scrollLeft = 0
  if (window.scrollX) window.scrollTo(0, window.scrollY)
}

document.addEventListener("turbo:before-render", resetHorizontalRouteScroll)
document.addEventListener("turbo:render", resetHorizontalRouteScroll)
document.addEventListener("turbo:load", resetHorizontalRouteScroll)
