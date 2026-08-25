module ApplicationHelper
  def color_theme_options
    [
      [ "System", "system" ],
      [ "Light", "light" ],
      [ "Dark", "dark" ]
    ]
  end

  def color_theme_label
    { "light" => "Light", "dark" => "Dark" }.fetch(color_theme, "System")
  end

  def landing_page?
    controller_name == "pages"
  end

  def nav_current?(*names)
    controller_name.in?(names.map(&:to_s))
  end

  def nav_link(label, path, *controllers)
    link_to label, path, aria: { current: nav_current?(*controllers) ? "page" : nil }
  end

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

  def shared_email_inbox_status_label(inbox)
    return "Paused" unless inbox.active?

    inbox.webhook_ready? ? "Ready" : "Needs secret"
  end

  def knowledge_source_kind_label(kind)
    {
      "url" => "URL snapshot",
      "intercom_help_center" => "Intercom Help Center"
    }.fetch(kind.to_s, kind.to_s.humanize)
  end

  def knowledge_source_status(source)
    return [ "Deleted", "status-danger" ] if source.deleted?
    return [ "Stale", "status-warning" ] if source.stale?

    [ "Current", "status-success" ]
  end
end
