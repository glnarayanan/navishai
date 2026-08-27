require "test_helper"

class SupportCasesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @membership = memberships(:owner_support)
    @support_case = create_support_case
    add_inbound_message(@support_case)
    sign_in_as users(:owner)
  end

  test "authentication is required" do
    delete session_path

    get workspace_support_cases_path(@workspace)

    assert_redirected_to new_session_path
  end

  test "queue and case workspace render tenant-scoped work" do
    get workspace_support_cases_path(@workspace)

    assert_response :success
    assert_select "h2", text: "Case queue"
    assert_select "a", text: /Cannot sign in/

    get workspace_support_case_path(@workspace, @support_case)

    assert_response :success
    assert_select "h1", text: "Cannot sign in"
    assert_select ".message-body", text: /still cannot access/
    assert_select "aside[aria-label='Case context']"
    assert_select ".account-context-card", text: /Account context/
    assert_select ".account-context-card a", text: "Full dossier"
    assert_select "input, textarea, button", text: /Reply|Send/, count: 0
  end

  test "queue filters by status, priority, assignment, and tag" do
    other_case = create_support_case(subject: "Invoice question")
    other_case.update!(priority: :urgent, assigned_membership: @membership)
    tag = CaseWorkflow.create_tag!(workspace: @workspace, membership: @membership, name: "Billing")
    CaseWorkflow.tag!(workspace: @workspace, support_case: other_case, membership: @membership, tag: tag)

    get workspace_support_cases_path(@workspace, priority: "urgent", assignment: "mine", tag_id: tag.id)

    assert_response :success
    assert_select "a", text: /Invoice question/
    assert_select "a", text: /Cannot sign in/, count: 0

    get workspace_support_cases_path(@workspace, status: "closed")
    assert_select "h2", text: "No cases match these filters"
    assert_select "a", text: "Clear filters"
  end

  test "another workspace case is not found" do
    beta_case = create_support_case(
      workspace: workspaces(:beta_support),
      contact: contacts(:bob),
      membership: memberships(:outsider_beta)
    )

    get workspace_support_case_path(@workspace, beta_case)

    assert_response :not_found
  end

  test "viewer sees read-only case and forged writes return forbidden" do
    viewer = User.create!(email_address: "case-viewer@example.com", password: "password12345", verified_at: Time.current)
    Membership.create!(workspace: @workspace, user: viewer, role: :viewer)
    sign_in_as viewer

    get workspace_support_case_path(@workspace, @support_case)
    assert_response :success
    assert_select ".read-only-notice", text: /Read-only access/
    assert_select "form.compact-form", count: 0
  end

  test "read failures render a neutral service unavailable state" do
    original_load_queue = SupportCasesController.instance_method(:load_queue)
    SupportCasesController.define_method(:load_queue) { |**| raise ActiveRecord::StatementInvalid, "private database detail" }

    get workspace_support_cases_path(@workspace)

    assert_response :service_unavailable
    assert_select "h1", text: "Cases couldn’t be loaded"
    assert_no_match(/private database detail/, response.body)
  ensure
    SupportCasesController.define_method(:load_queue, original_load_queue) if original_load_queue
  end

  test "show lookup failures render a neutral service unavailable state" do
    original_set_support_case = SupportCasesController.instance_method(:set_support_case)
    SupportCasesController.define_method(:set_support_case) { raise ActiveRecord::StatementInvalid, "private database detail" }

    get workspace_support_case_path(@workspace, @support_case)

    assert_response :service_unavailable
    assert_select "h1", text: "Cases couldn’t be loaded"
    assert_no_match(/private database detail/, response.body)
  ensure
    SupportCasesController.define_method(:set_support_case, original_set_support_case) if original_set_support_case
  end

  test "render-time database failures render a neutral service unavailable state" do
    original_body = ConversationMessage.instance_method(:body)
    ConversationMessage.define_method(:body) { raise ActiveRecord::StatementInvalid, "private database detail" }

    get workspace_support_case_path(@workspace, @support_case)

    assert_response :service_unavailable
    assert_select "h1", text: "Cases couldn’t be loaded"
    assert_no_match(/private database detail/, response.body)
  ensure
    ConversationMessage.define_method(:body, original_body) if original_body
  end

  test "queue instantiates only the latest message in each conversation" do
    3.times do |index|
      add_inbound_message(@support_case, body: "Message #{index + 2}", occurred_at: index.minutes.from_now)
    end
    instantiated_messages = 0
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      instantiated_messages += payload[:record_count] if payload[:class_name] == "ConversationMessage"
    end

    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      get workspace_support_cases_path(@workspace)
    end

    assert_response :success
    assert_equal 1, instantiated_messages
    assert_select ".case-row-excerpt", text: "Message 4"
  end
end
