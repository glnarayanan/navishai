module ApplicationHelper
  def role_label(role)
    role.to_s == "viewer" ? "Viewer / Auditor" : role.to_s.titleize
  end

  def case_status_label(status)
    {
      "waiting_customer" => "Waiting on customer",
      "waiting_internal" => "Waiting internally",
      "awaiting_human_review" => "Awaiting human review"
    }.fetch(status.to_s, status.to_s.titleize)
  end

  def audit_action_label(action)
    action.to_s.tr(".", "_").humanize
  end
end
