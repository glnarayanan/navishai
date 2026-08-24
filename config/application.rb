require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Navishai
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Preserve PostgreSQL constraints and triggers that enforce security invariants.
    config.active_record.schema_format = :sql

    # Files are available only through workspace-authorized controllers.
    config.active_storage.draw_routes = false

    config.action_dispatch.default_headers = {
      "X-Frame-Options" => "DENY",
      "X-XSS-Protection" => "0",
      "X-Content-Type-Options" => "nosniff",
      "X-Permitted-Cross-Domain-Policies" => "none",
      "Referrer-Policy" => "no-referrer",
      "Cross-Origin-Opener-Policy" => "same-origin",
      "Cross-Origin-Resource-Policy" => "same-origin",
      "Permissions-Policy" => "camera=(), geolocation=(), microphone=(), payment=(), usb=()"
    }

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
