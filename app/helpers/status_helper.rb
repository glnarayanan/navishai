module StatusHelper
  TONES = {
    "pass" => "pass", "fail" => "fail", "error" => "fail",
    "abstain" => "warn", "incomplete" => "warn", "interrupted" => "warn",
    "running" => "info", "queued" => "neutral", "complete" => "neutral"
  }.freeze

  def status_pill(value, label: nil)
    tag.span(label || value.to_s.humanize, class: "status-pill status-#{TONES.fetch(value.to_s, "neutral")}")
  end
end
