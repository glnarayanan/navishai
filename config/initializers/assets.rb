# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Host Geist from the application asset path. Do not load fonts from a CDN.
Rails.application.config.assets.paths << Rails.root.join("app/assets/fonts")
