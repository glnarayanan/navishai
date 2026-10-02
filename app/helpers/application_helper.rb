module ApplicationHelper
  def color_theme_options
    [ [ "System", "system" ], [ "Light", "light" ], [ "Dark", "dark" ] ]
  end

  def color_theme_label
    { "light" => "Light", "dark" => "Dark" }.fetch(color_theme, "System")
  end

  def role_label(role)
    role.to_s == "viewer" ? "Viewer / Auditor" : role.to_s.titleize
  end
end
