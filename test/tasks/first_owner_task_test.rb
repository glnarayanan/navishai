require "test_helper"
require "rake"

class FirstOwnerTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("navishai:first_owner:renewable")
    @task = Rake::Task["navishai:first_owner:renewable"]
  end

  teardown do
    @task.reenable
  end

  test "aborts once any organisation, user, or installation state exists" do
    error = assert_raises(SystemExit) { @task.invoke }

    assert_not error.success?
  end

  test "succeeds while nothing has been bootstrapped" do
    original = FirstOwnerBootstrap.method(:renewable?)
    FirstOwnerBootstrap.define_singleton_method(:renewable?) { true }

    assert_output(/may be renewed/) { @task.invoke }
  ensure
    FirstOwnerBootstrap.define_singleton_method(:renewable?, original)
  end
end
