ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    available_workers = (Concurrent.available_processor_count || Concurrent.processor_count).floor
    parallelize(workers: [ available_workers, 4 ].min)
    fixtures :all
  end
end
