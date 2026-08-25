module ApplicationHelper
  NAV_SECTION_LABELS = {
    "support_cases" => "Cases",
    "support_case_commands" => "Cases",
    "accounts" => "Accounts",
    "account_imports" => "Accounts",
    "knowledge_sources" => "Knowledge",
    "memory_records" => "Memory",
    "memory_corrections" => "Memory",
    "health_scorecards" => "Scorecard",
    "crew_templates" => "Crews",
    "agent_profiles" => "Crews",
    "crew_tasks" => "Crews",
    "runtime_installations" => "Runtimes",
    "shared_email_inboxes" => "Email",
    "intercom_connections" => "Intercom",
    "outbound_webhook_endpoints" => "Webhooks",
    "workspace_data_controls" => "Data",
    "notifications" => "Notifications",
    "workspaces" => "Workspaces",
    "workspace_invitations" => "Invitations"
  }.freeze

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

  def body_controllers
    controllers = [ "theme" ]
    controllers << "landing-header" if landing_page?
    controllers << "nav-drawer" if landing_page? || authenticated?
    controllers.join(" ")
  end

  def nav_current?(*names)
    controller_name.in?(names.map(&:to_s))
  end

  def nav_link(label, path, *controllers, **html)
    current = nav_current?(*controllers)
    css = [ "nav-item", html.delete(:class), ("is-current" if current) ].compact.join(" ")
    aria = { current: current ? "page" : nil }.merge(html.delete(:aria) || {})
    link_to label, path, **html, class: css, aria: aria
  end

  def current_nav_section
    NAV_SECTION_LABELS.fetch(controller_name, controller_name.titleize)
  end

  def unread_notification_count
    return 0 unless Current.workspace

    @unread_notification_count ||= Current.require_membership!.notifications.unread.count
  end

  def workspace_runtime_needs_review?
    return false unless Current.workspace

    @workspace_runtime_needs_review ||= Current.workspace.runtime_installations
      .where("health_status <> ? OR compatibility_status = ?", "available", "incompatible")
      .exists?
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
