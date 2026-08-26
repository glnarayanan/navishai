module ColorTheme
  extend ActiveSupport::Concern

  THEMES = %w[system light dark].freeze
  COOKIE = :navishai_theme

  included do
    helper_method :color_theme
  end

  private
    def color_theme
      requested = cookies[COOKIE].to_s
      THEMES.include?(requested) ? requested : "system"
    end
end
