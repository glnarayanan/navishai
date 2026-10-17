module StatusHelper
  TONES = {
    "pass" => "pass", "fail" => "fail", "error" => "fail", "failed" => "fail",
    "abstain" => "warn", "incomplete" => "warn", "interrupted" => "warn", "stale" => "warn",
    "running" => "info", "queued" => "neutral", "complete" => "neutral",
    "approve" => "pass", "reject" => "fail", "merge" => "neutral", "needs_review" => "warn"
  }.freeze

  REVIEW_LABELS = { "approve" => "Approved", "reject" => "Rejected", "merge" => "Merged", "needs_review" => "Needs review" }.freeze

  def status_pill(value, label: nil)
    tag.span(label || value.to_s.humanize, class: "status-pill status-#{TONES.fetch(value.to_s, "neutral")}")
  end

  # Scenario reviews are expert decisions, so the pill names the decision rather than a run state.
  def scenario_review_pill(decision)
    key = decision.presence || "needs_review"
    status_pill(key, label: REVIEW_LABELS.fetch(key, key.humanize))
  end

  def importance_label(importance)
    importance == "normal" ? tag.span("Normal", class: "muted") : tag.strong(importance.humanize)
  end
end
