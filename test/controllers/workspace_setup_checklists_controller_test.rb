require "test_helper"
require_relative "../test_helpers/fake_clamd_daemon"
require_relative "../test_helpers/fake_memory_engine"

class WorkspaceSetupChecklistsControllerTest < ActionDispatch::IntegrationTest
  test "shows honest checklist states to an Owner" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)

    get workspace_setup_checklist_path(workspace)

    assert_response :success
    assert_select "h1", "Setup checklist"
    assert_select "strong", "AI providers"
    assert_select "strong", "Memory"
    assert_select "strong", "Public-web search"
    assert_select "strong", "Attachments"
    assert_select "strong", "System email"
    assert_select "a[aria-label='Open AI providers']"
    assert_select "strong", "Memory"
    assert_select "span", { text: "Skipped", count: 5 }
  end

  test "offers a memory test once self-hosted memory is configured and shows tested only after a pass" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)
    engine = FakeMemoryEngine.new
    original = SupermemoryEngine.method(:default)
    SupermemoryEngine.define_singleton_method(:default) { engine }

    with_memory do
      get workspace_setup_checklist_path(workspace)
      assert_response :success
      assert_select "form[action='#{memory_check_workspace_setup_checklist_path(workspace)}'] button", "Test memory"
      assert_select "span.status-configured", "Configured"

      post memory_check_workspace_setup_checklist_path(workspace)
      assert_redirected_to workspace_setup_checklist_path(workspace)
      assert_match(/Memory verification passed/, flash[:notice])

      get workspace_setup_checklist_path(workspace)
      assert_select "span.status-tested", "Tested"
      assert_select "span", /Live service proof is separate/
    end

    with_memory(address: "http://127.0.0.1:6768") do
      get workspace_setup_checklist_path(workspace)
      assert_select "span.status-configured", "Configured"
    end
  ensure
    SupermemoryEngine.define_singleton_method(:default, original) if original
  end

  test "keeps pending and failed memory checks from counting as tested" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)
    engine = FakeMemoryEngine.new
    engine.index_status = "queued"
    original = SupermemoryEngine.method(:default)
    SupermemoryEngine.define_singleton_method(:default) { engine }

    with_memory do
      post memory_check_workspace_setup_checklist_path(workspace)
      assert_match(/not complete/, flash[:alert])
      get workspace_setup_checklist_path(workspace)
      assert_select "span.status-configured", "Configured"
      assert_select "span", /Pending is not verified/
    end

    engine.index_status = "done"
    engine.search_miss = true
    with_memory do
      post memory_check_workspace_setup_checklist_path(workspace)
      assert_match(/failed/, flash[:alert])
      get workspace_setup_checklist_path(workspace)
      assert_select "span.status-blocked", "Blocked"
      assert_select "span.status-tested", count: 0
    end
  ensure
    SupermemoryEngine.define_singleton_method(:default, original) if original
  end

  test "refuses a memory test without configuration or for a Member" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)

    post memory_check_workspace_setup_checklist_path(workspace)
    assert_redirected_to workspace_setup_checklist_path(workspace)
    assert_match(/Configure self-hosted memory/, flash[:alert])

    sign_in_as users(:outsider)
    post memory_check_workspace_setup_checklist_path(workspaces(:beta_support))
    assert_response :forbidden
    assert_equal 0, OperationalCheck.where(check_kind: "memory_verification").count
  end

  test "offers a scanner test once ClamAV is configured and shows tested only after a pass" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)
    daemon = FakeClamdDaemon.new([ "stream: OK\0", "stream: Eicar-Test-Signature FOUND\0" ])

    with_scanner(daemon) do
      get workspace_setup_checklist_path(workspace)
      assert_response :success
      assert_select "form[action='#{scanner_check_workspace_setup_checklist_path(workspace)}'] button", "Test scanner"
      assert_select "span.status-configured", "Configured"

      post scanner_check_workspace_setup_checklist_path(workspace)
      assert_redirected_to workspace_setup_checklist_path(workspace)
      assert_match(/Scanner test passed/, flash[:notice])

      get workspace_setup_checklist_path(workspace)
      assert_select "span.status-tested", "Tested"
      assert_select "span", /not real-malware coverage/
    end
    daemon.close

    with_scanner(daemon, address: "tcp://127.0.0.1:1") do
      get workspace_setup_checklist_path(workspace)
      assert_select "span.status-configured", "Configured"

      post scanner_check_workspace_setup_checklist_path(workspace)
      assert_match(/Scanner unreachable/, flash[:alert])

      get workspace_setup_checklist_path(workspace)
      assert_select "span.status-blocked", "Blocked"
      assert_select "span", /Files stay quarantined/
    end
  end

  test "refuses a scanner test without a configured scanner or for a Member" do
    workspace = workspaces(:acme_support)
    sign_in_as users(:owner)

    post scanner_check_workspace_setup_checklist_path(workspace)
    assert_redirected_to workspace_setup_checklist_path(workspace)
    assert_match(/Configure ClamAV/, flash[:alert])

    sign_in_as users(:outsider)
    post scanner_check_workspace_setup_checklist_path(workspaces(:beta_support))
    assert_response :forbidden
    assert_equal 0, OperationalCheck.where(check_kind: "attachment_scanner").count
  end

  test "forbids a Member from opening the checklist" do
    sign_in_as users(:outsider)

    get workspace_setup_checklist_path(workspaces(:beta_support))

    assert_response :forbidden
  end

  private
    def with_scanner(daemon, address: daemon.address, source_commit: "c" * 40)
      original = ENV.to_h.slice("NAVISHAI_ATTACHMENT_SCANNER", "NAVISHAI_CLAMD_ADDRESS", "NAVISHAI_SOURCE_COMMIT")
      ENV["NAVISHAI_ATTACHMENT_SCANNER"] = "clamd"
      ENV["NAVISHAI_CLAMD_ADDRESS"] = address
      ENV["NAVISHAI_SOURCE_COMMIT"] = source_commit
      yield
    ensure
      %w[NAVISHAI_ATTACHMENT_SCANNER NAVISHAI_CLAMD_ADDRESS NAVISHAI_SOURCE_COMMIT].each do |key|
        original.key?(key) ? ENV[key] = original[key] : ENV.delete(key)
      end
    end

    def with_memory(address: "http://127.0.0.1:6767", source_commit: "c" * 40)
      original = ENV.to_h.slice("NAVISHAI_SUPERMEMORY_ADDRESS", "NAVISHAI_SUPERMEMORY_API_KEY", "NAVISHAI_SOURCE_COMMIT", "NAVISHAI_MEMORY_PENDING")
      ENV["NAVISHAI_SUPERMEMORY_ADDRESS"] = address
      ENV["NAVISHAI_SUPERMEMORY_API_KEY"] = "sm_#{"a" * 32}"
      ENV["NAVISHAI_SOURCE_COMMIT"] = source_commit
      ENV.delete("NAVISHAI_MEMORY_PENDING")
      yield
    ensure
      %w[NAVISHAI_SUPERMEMORY_ADDRESS NAVISHAI_SUPERMEMORY_API_KEY NAVISHAI_SOURCE_COMMIT NAVISHAI_MEMORY_PENDING].each do |key|
        original.key?(key) ? ENV[key] = original[key] : ENV.delete(key)
      end
    end
end
