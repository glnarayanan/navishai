module ApplicationHelper
  def color_theme_options
    [ [ "System", "system" ], [ "Light", "light" ], [ "Dark", "dark" ] ]
  end

  def role_label(role)
    role.to_s == "viewer" ? "Viewer / Auditor" : role.to_s.titleize
  end
end
