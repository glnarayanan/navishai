module ReliabilityCockpitsHelper
  def reliability_status_label(status)
    {
      "healthy" => "Healthy",
      "attention" => "Attention",
      "blocked" => "Blocked",
      "unknown" => "Unknown",
      "not_configured" => "Not configured"
    }.fetch(status)
  end

  def reliability_overall_copy(status)
    {
      "healthy" => "No section needs operator action.",
      "attention" => "Review the bounded work listed below.",
      "blocked" => "At least one operation cannot continue safely.",
      "unknown" => "At least one external effect lacks a definite result.",
      "not_configured" => "No operational evidence has been configured."
    }.fetch(status)
  end
end
