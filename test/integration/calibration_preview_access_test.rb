require "test_helper"
require_relative "../test_helpers/calibration_preview_fixture"

class CalibrationPreviewAccessTest < ActionDispatch::IntegrationTest
  include CalibrationPreviewFixture
  setup do
    build_calibration_preview
    sign_in_as users(:owner)
  end

  test "preview GET is read-only scopes candidate and keeps baseline report and review states" do
    writes = []
    observer = ->(event) { writes << event.payload[:sql] if event.payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i) }
    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      assert_no_enqueued_jobs { preview }
    end
    assert_empty writes
    assert_response :success
    assert_select "#fixed-report td", text: "2 true positives"
    assert_select "#fixed-report .judge-threshold", text: "Not applicable — deterministic grader"
    assert_select "#candidate-report td", text: "1 false negatives"
    assert_select "#candidate-report .judge-threshold", text: "Not applicable — deterministic grader"
    assert_select "#candidate-report", text: /original fixed requirements/
    assert_select "#review-samples [data-review-state=aligned]", count: 3
    assert_select "option[selected]", value: @preview_candidate.id.to_s
    preview(cohort: "held_out")
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /development samples only/
    assert_select "#candidate-report", count: 0
    assert_select "#fixed-report td", text: "1 true negatives"
    preview(candidate: @outcome_grader.current_version_id)
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /same grader/
    preview(candidate: -1)
    assert_response :not_found
  end

  test "a writer without personal labels cannot identify candidate disagreements before their first label" do
    @workspace.memberships.create!(user: users(:teammate), role: "member")
    sign_in_as users(:teammate)
    preview
    assert_response :success
    assert_select "#candidate-report td", text: "1 false negatives"
    assert_select "#candidate-report li", count: 0
    assert_select "#review-samples [data-review-state=unlabelled]", count: 3
  end

  test "viewer may inspect a read-only preview but foreign corpus workspace and expiry remain hidden" do
    @workspace.memberships.create!(user: users(:teammate), role: "viewer")
    sign_in_as users(:teammate)
    assert_no_difference -> { AuditEvent.count } do
      preview
    end
    assert_response :success
    assert_select "#candidate-report td", text: "1 false negatives"
    assert_select "#review-samples form", count: 0
    other = @workspace.corpora.create!(name: "Foreign corpus")
    get workspace_corpus_calibration_set_path(@workspace, other, @preview_set), params: { cohort: "development", candidate_version_id: @preview_candidate.id }
    assert_response :not_found
    get workspace_corpus_calibration_set_path(workspaces(:beta_support), @corpus, @preview_set), params: { cohort: "development", candidate_version_id: @preview_candidate.id }
    assert_response :not_found
    @knowledge.source_snapshot.source.update!(expires_at: 1.second.ago)
    preview
    assert_response :not_found
  end

  private
    def preview(cohort: "development", candidate: @preview_candidate.id)
      get workspace_corpus_calibration_set_path(@workspace, @corpus, @preview_set), params: { cohort:, candidate_version_id: candidate }
    end
end
