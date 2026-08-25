seed_demo = Rails.env.development? || ENV["NAVISHAI_SEED_DEMO"] == "1"

if seed_demo
  require_relative "seeds/demo"
  DemoSeed.load!
end
