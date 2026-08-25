require "test_helper"
require "pg"
require "timeout"

class CustomerIdentityGraphTest < ActiveSupport::TestCase
  test "workspace graph lock serializes concurrent identity decisions" do
    workspace = workspaces(:acme_support)
    lock_name = CustomerIdentityGraph.send(:lock_name, workspace)
    first_acquired = Queue.new
    release_first = Queue.new
    second_started = Queue.new
    second_acquired = Queue.new

    first = Thread.new do
      connection = PG.connect(dbname: ActiveRecord::Base.connection.current_database)
      connection.exec("BEGIN")
      connection.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", [ lock_name ])
      first_acquired << true
      release_first.pop
      connection.exec("COMMIT")
    ensure
      connection&.close
    end
    first_acquired.pop

    second = Thread.new do
      connection = PG.connect(dbname: ActiveRecord::Base.connection.current_database)
      connection.exec("BEGIN")
      second_started << true
      connection.exec_params("SELECT pg_advisory_xact_lock(hashtext($1))", [ lock_name ])
      second_acquired << true
      connection.exec("COMMIT")
    ensure
      connection&.close
    end
    second_started.pop

    assert_raises(Timeout::Error) { Timeout.timeout(0.1) { second_acquired.pop } }
    release_first << true
    assert Timeout.timeout(2) { second_acquired.pop }
    first.join
    second.join
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end
end
