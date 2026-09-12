require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @workspace = workspaces(:acme_support)
    @account = accounts(:acme)
    sign_in_as users(:owner)
  end

  test "shows scoped accounts and a complete deterministic signal record" do
    assessment = AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: memberships(:owner_support))

    get workspace_accounts_path(@workspace)
    assert_response :success
    assert_select "a", text: /#{@account.name}/
    assert_select "a", text: /#{accounts(:beta).name}/, count: 0

    get workspace_account_path(@workspace, @account)
    assert_response :success
    assert_select ".health-score-panel strong", text: /#{assessment.score}/
    assert_select ".health-signals tbody tr", count: assessment.signals.count
    assert_select "small", text: assessment.signals.first.citation_uri
    assert_select ".health-context dd", text: "Version #{assessment.health_scorecard_version.version_number}"
    assert_select "h2", text: "Renewal-risk work"

    signal = assessment.signals.find_by!(signal_key: "open_cases")
    get health_evidence_workspace_account_path(
      @workspace, @account, assessment_id: assessment.id, signal_key: signal.signal_key
    )
    assert_response :success
    assert_select "h1", text: "Open support cases"
    assert_select "code", text: signal.citation_uri
  end

  test "health evidence rejects foreign Accounts assessments and signals" do
    assessment = AccountHealth.recalculate!(workspace: @workspace, account: @account,
      trigger_kind: "human_request", membership: memberships(:owner_support))
    beta = workspaces(:beta_support)
    beta_assessment = AccountHealth.recalculate!(workspace: beta, account: accounts(:beta),
      trigger_kind: "human_request", membership: memberships(:outsider_beta))

    get health_evidence_workspace_account_path(
      @workspace, @account, assessment_id: beta_assessment.id, signal_key: "open_cases"
    )
    assert_response :not_found
    get health_evidence_workspace_account_path(
      @workspace, accounts(:beta), assessment_id: assessment.id, signal_key: "open_cases"
    )
    assert_response :not_found
  end

  test "index stays name-ordered without a work-queue view" do
    zebra = @workspace.accounts.create!(name: "Zebra Queue")
    alpha = @workspace.accounts.create!(name: "Alpha Queue")

    get workspace_accounts_path(@workspace)
    assert_response :success
    names = css_select(".account-list-name strong").map(&:text)
    assert_operator names.index(alpha.name), :<, names.index(zebra.name)
    assert_select ".account-work-queue", count: 0
  end

  test "paginates accounts without loading contacts or assessment history" do
    51.times { |index| @workspace.accounts.create!(name: "Page account #{index.to_s.rjust(2, "0")}") }
    12.times do |index|
      AccountHealth.recalculate!(workspace: @workspace, account: @account,
        trigger_kind: "schedule", at: index.minutes.ago)
    end
    instantiated = Hash.new(0)
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      instantiated[payload[:class_name]] += payload[:record_count]
    end

    ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      get workspace_accounts_path(@workspace)
    end

    assert_response :success
    assert_select ".account-list [role='listitem']", count: 50
    assert_select "nav[aria-label='Account pages'] a", text: "Next"
    assert_equal 0, instantiated["Contact"]
    assert_equal 1, instantiated["AccountHealthAssessment"]

    get workspace_accounts_path(@workspace, page: 2)
    assert_response :success
    assert_select ".account-list [role='listitem']", count: 3
    assert_select "nav[aria-label='Account pages'] a", text: "Previous"
  end

  test "imports CSV and JSON inputs and rejects foreign accounts" do
    csv = Rack::Test::UploadedFile.new(
      StringIO.new("source_id,account_name,renewal_on\ncontroller-csv,Controller Import,#{(Date.current + 30).iso8601}\n"),
      "text/csv", original_filename: "accounts.csv"
    )
    post workspace_account_imports_path(@workspace), params: { file: csv }
    assert_redirected_to workspace_accounts_path(@workspace)
    assert @workspace.accounts.exists?(name: "Controller Import")

    post workspace_account_api_inputs_path(@workspace), params: {
      records: [ { source_id: "controller-api", account_name: "API Import", active_users: 30 } ]
    }, as: :json
    assert_response :created
    assert_equal 1, response.parsed_body.fetch("imported_accounts")

    post workspace_account_api_inputs_path(@workspace), params: { records: "not-an-array" }, as: :json
    assert_response :unprocessable_content
    assert_equal "API payload must contain 1 to 500 records.", response.parsed_body.fetch("error")

    get workspace_account_path(@workspace, accounts(:beta))
    assert_response :not_found
  end

  test "viewer can inspect but cannot recalculate or import" do
    viewer = User.create!(email_address: "account-viewer@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: viewer, role: :viewer)
    sign_in_as viewer
    get workspace_account_path(@workspace, @account)
    assert_response :success
    assert_select "form[action=?]", recalculate_workspace_account_path(@workspace, @account), count: 0

    post recalculate_workspace_account_path(@workspace, @account)
    assert_response :forbidden

    post workspace_account_api_inputs_path(@workspace), params: { records: [ {
      source_id: "viewer", account_name: "Nope", active_users: 1
    } ] }, as: :json
    assert_response :forbidden
  end

  test "renders the source-backed dossier and resolves an ambiguous identity through recorded candidates" do
    duplicate = contacts(:alice_duplicate)
    identity = @workspace.source_identities.create!(
      entity_kind: :contact, source_namespace: "intercom:primary", source_record_type: :contact,
      source_record_id: "account-dossier-ambiguous", status: :ambiguous
    )
    identity.source_identity_keys.create!(workspace: @workspace, kind: :email, normalized_value: "alice@example.com")
    identity.identity_match_candidates.create!(workspace: @workspace, contact: contacts(:alice), key_kind: :email)
    identity.identity_match_candidates.create!(workspace: @workspace, contact: duplicate, key_kind: :email)

    get workspace_account_path(@workspace, @account)

    assert_response :success
    assert_select "#account-dossier h2", text: "Account dossier"
    assert_select ".dossier-record-conflict", text: /Competing identity matches/
    assert_select "form[action=?]", resolve_identity_workspace_account_path(
      @workspace, @account, source_identity_id: identity.id
    ), count: 2

    post resolve_identity_workspace_account_path(
      @workspace, @account, source_identity_id: identity.id
    ), params: { target_id: contacts(:alice).id }

    assert_redirected_to workspace_account_path(@workspace, @account, anchor: "account-dossier")
    assert identity.reload.matched?
    assert_equal contacts(:alice), identity.contact
    assert identity.reviewed?
  end

  test "member sees an identity conflict but cannot resolve it" do
    member = User.create!(email_address: "dossier-member@example.com", password: "password12345", verified_at: Time.current)
    @workspace.memberships.create!(user: member, role: :member)
    identity = @workspace.source_identities.create!(
      entity_kind: :contact, source_namespace: "intercom:primary", source_record_type: :contact,
      source_record_id: "member-ambiguous", status: :ambiguous
    )
    identity.source_identity_keys.create!(workspace: @workspace, kind: :email, normalized_value: "alice@example.com")
    identity.identity_match_candidates.create!(workspace: @workspace, contact: contacts(:alice), key_kind: :email)
    sign_in_as member

    get workspace_account_path(@workspace, @account)
    assert_response :success
    assert_select ".dossier-record-conflict", text: /Manager must choose/
    assert_select "form[action=?]", resolve_identity_workspace_account_path(
      @workspace, @account, source_identity_id: identity.id
    ), count: 0

    post resolve_identity_workspace_account_path(
      @workspace, @account, source_identity_id: identity.id
    ), params: { target_id: contacts(:alice).id }
    assert_response :forbidden
    assert identity.reload.ambiguous?
  end

  test "cannot resolve an identity from another Account through this dossier" do
    other_account = @workspace.accounts.create!(name: "Other Account")
    other_contact = @workspace.contacts.create!(account: other_account, name: "Other Contact")
    identity = @workspace.source_identities.create!(
      entity_kind: :contact, source_namespace: "intercom:primary", source_record_type: :contact,
      source_record_id: "other-account-ambiguous", status: :ambiguous
    )
    identity.identity_match_candidates.create!(workspace: @workspace, contact: other_contact, key_kind: :email)

    post resolve_identity_workspace_account_path(
      @workspace, @account, source_identity_id: identity.id
    ), params: { target_id: other_contact.id }

    assert_response :not_found
    assert identity.reload.ambiguous?
  end
end
