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

  NAV_ICONS = {
    "Cases" => "M2 3.2h12v2H2zm0 3.4h12v7.2H2zm1.5 1.5v4.2h9V8.1z",
    "Accounts" => "M8 1.7 14.2 4.8v6.4L8 14.3 1.8 11.2V4.8L8 1.7zm0 1.8L3.6 5.6v5l4.4 2.2 4.4-2.2v-5L8 3.5z",
    "Knowledge" => "M3 2.2h4.2c1.2 0 2.2.7 2.2 1.8v9.2c-.8-.6-1.6-.9-2.2-.9H3zm6.6 0H13v10.1h-3.2c-.6 0-1.4.3-2.2.9V4c0-1.1 1-1.8 2-1.8z",
    "Memory" => "M3.2 3.2h9.6v2.1H3.2zm0 3.7h9.6v2.1H3.2zm0 3.8h6.4V13H3.2z",
    "Scorecard" => "M8 1.6A6.4 6.4 0 1 1 1.6 8 6.4 6.4 0 0 1 8 1.6zm-.7 3.2h1.4v3.2l2.2 2.2-.9.9-2.7-2.7z",
    "Crews" => "M8 1.8a2.2 2.2 0 1 1 0 4.4 2.2 2.2 0 0 1 0-4.4zM3.2 4.2a1.7 1.7 0 1 1 0 3.4 1.7 1.7 0 0 1 0-3.4zm9.6 0a1.7 1.7 0 1 1 0 3.4 1.7 1.7 0 0 1 0-3.4zM8 7.6c2.3 0 4.4 1.2 4.4 3.2v1.6H3.6V10.8C3.6 8.8 5.7 7.6 8 7.6z",
    "Runtimes" => "M6.2 1.8h3.6l.8 2.4H14v3.2h-2.1l-.8 2.4H4.9l-.8-2.4H2V4.2h3.4zm1 8.4h1.6V14H7.2z",
    "Email" => "M2 3.4h12v9.2H2zm1.5 1.5 4.5 3.2 4.5-3.2V11H3.5z",
    "Intercom" => "M3 3.2h10v7.2H8.2L5.4 13v-2.6H3z",
    "Webhooks" => "M8 1.6a3.2 3.2 0 0 1 2.8 4.7l1.9 1.9-1.1 1.1-1.9-1.9A3.2 3.2 0 1 1 8 1.6zM4.4 8.4a3.2 3.2 0 1 1 .9 4.4l-1.9 1.9-1.1-1.1 1.9-1.9a3.2 3.2 0 0 1 .2-1.3z",
    "Data" => "M8 1.6 13.6 4v3.1c0 3.4-2.3 5.8-5.6 6.7C4.7 12.9 2.4 10.5 2.4 7.1V4zm0 1.7L4 4.8v2.3c0 2.4 1.6 4.2 4 4.9 2.4-.7 4-2.5 4-4.9V4.8z",
    "Notifications" => "M8 1.8c1.8 0 3.3 1.4 3.3 3.2v2.3l1.4 1.8v.9H3.3v-.9l1.4-1.8V5c0-1.8 1.5-3.2 3.3-3.2zm-1.6 9.4h3.2A1.6 1.6 0 0 1 8 12.8a1.6 1.6 0 0 1-1.6-1.6z",
    "Workspaces" => "M2.2 3.2h5.1v4.2H2.2zm6.5 0h5.1v4.2H8.7zM2.2 8.6h5.1v4.2H2.2zm6.5 0h5.1v4.2H8.7z"
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
    link_to path, **html, class: css, aria: aria do
      safe_join([ nav_icon(label), tag.span(label, class: "nav-label") ])
    end
  end

  def nav_icon(label)
    path = NAV_ICONS[label]
    return "".html_safe unless path

    tag.svg(class: "nav-icon", width: 16, height: 16, viewBox: "0 0 16 16", aria: { hidden: true }) do
      tag.path(fill: "currentColor", d: path)
    end
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
