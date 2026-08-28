require "test_helper"

class WorkspaceDeletionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class FailingQueueAdapter
    def enqueue(_job)
      raise ActiveJob::EnqueueError
    end

    def enqueue_at(_job, _timestamp)
      raise ActiveJob::EnqueueError
    end
  end

  test "requires the exact slug and an owner before blocking access" do
    workspace = workspaces(:acme_support)

    assert_no_difference [ "WorkspaceDeletionRequest.count", "AuditEvent.count" ] do
      assert_raises(ArgumentError) do
        WorkspaceDeletion.request!(
          workspace:, membership: memberships(:owner_support), confirmation: "wrong"
        )
      end
    end
    assert_nil workspace.reload.deletion_requested_at

    assert_raises(Current::RoleAccessDenied) do
      WorkspaceDeletion.request!(
        workspace:, membership: workspace.memberships.create!(user: users(:teammate), role: :member),
        confirmation: workspace.slug
      )
    end
  end

  test "queues deletion and blocks the workspace at once" do
    workspace = workspaces(:acme_support)
    requested_at = Time.zone.parse("2026-08-24 12:00:00")

    assert_enqueued_with job: WorkspaceDeletionJob do
      @request = WorkspaceDeletion.request!(
        workspace:, membership: memberships(:owner_support), confirmation: workspace.slug, requested_at:
      )
    end

    assert_equal requested_at, workspace.reload.deletion_requested_at
    assert @request.pending?
    assert_equal users(:owner), @request.requested_by
    assert_equal "workspace.deletion_requested", workspace.audit_events.order(:id).last.action
    refute_includes Workspace.active, workspace
  end

  test "keeps an enqueue failure visible for retry" do
    workspace = workspaces(:acme_support)
    original_adapter = WorkspaceDeletionJob.queue_adapter
    WorkspaceDeletionJob.queue_adapter = FailingQueueAdapter.new

    @request = WorkspaceDeletion.request!(
      workspace:, membership: memberships(:owner_support), confirmation: workspace.slug
    )

    assert @request.reload.failed?
    assert_equal "enqueue_error", @request.failure_code
    assert_equal "workspace.deletion_failed", workspace.audit_events.order(:id).last.action
  ensure
    WorkspaceDeletionJob.queue_adapter = original_adapter if original_adapter
  end

  test "removes workspace records and retains an immutable global tombstone" do
    workspace = workspaces(:acme_support)
    workspace_id = workspace.id
    user = users(:owner)
    owner = memberships(:owner_support)
    account = accounts(:acme)
    at = Time.current.change(usec: 0)
    before_assessment = AccountHealth.recalculate!(
      workspace:, account:, trigger_kind: "human_request", membership: owner, at:
    )
    plan, = create_reviewed_intervention_plan(
      workspace:, account:, membership: owner, assessment: before_assessment
    )
    intervention = propose_test_intervention(
      workspace:, account:, membership: owner, assessment: before_assessment,
      artifact: plan, at: at + 1.minute
    )
    CustomerSuccessInterventionWorkflow.approve!(
      workspace:, membership: owner, intervention:, at: at + 2.minutes
    )
    CustomerSuccessInterventionWorkflow.complete!(
      workspace:, membership: owner, intervention:, at: at + 3.minutes
    )
    after_assessment = AccountHealth.recalculate!(
      workspace:, account:, trigger_kind: "human_request", membership: owner, at: at + 4.minutes
    )
    review = CustomerSuccessInterventionWorkflow.review!(
      workspace:, membership: owner, intervention:, after_assessment:,
      uncertainty: "Deletion must remove this frozen review.", at: at + 5.minutes
    )
    intervention_id = intervention.id
    review_id = review.id
    purged = []
    request = WorkspaceDeletion.request!(
      workspace:, membership: memberships(:owner_support), confirmation: workspace.slug
    )

    tombstone = WorkspaceDeletion.perform!(
      request:, engine: Object.new, object_purger: ->(blob) { purged << blob.key }
    )

    assert_not_nil tombstone
    refute Workspace.exists?(workspace_id)
    refute Membership.exists?(workspace_id:)
    refute CustomerSuccessIntervention.exists?(intervention_id)
    refute CustomerSuccessInterventionOutcomeReview.exists?(review_id)
    assert_empty purged
    assert User.exists?(user.id)
    assert_equal workspace_id, tombstone.former_workspace_id
    assert_equal user, tombstone.deleted_by
    assert_operator tombstone.record_count, :>, 0
    audit = AuditEvent.find_by!(
      action: "workspace.deleted", subject_type: "WorkspaceTombstone", subject_id: tombstone.id
    )
    assert_nil audit.workspace_id
    assert_equal user, audit.actor
    assert_raises(ActiveRecord::StatementInvalid) do
      WorkspaceTombstone.where(id: tombstone.id).update_all(record_count: 0)
    end
  end

  test "keeps a failed deletion visible for an owner retry" do
    workspace = workspaces(:acme_support)
    content = "delete me"
    attachment = workspace.stored_attachments.create!(
      source: :user_upload, uploaded_by_membership: memberships(:owner_support), uploaded_by_user: users(:owner),
      filename: "delete.txt", byte_size: content.bytesize, content_sha256: Digest::SHA256.hexdigest(content),
      detected_content_type: "text/plain", scan_status: :available, scan_result_code: "clean", scanned_at: Time.current
    )
    attachment.file.attach(io: StringIO.new(content), filename: "delete.txt", content_type: "text/plain")
    request = WorkspaceDeletion.request!(
      workspace:, membership: memberships(:owner_support), confirmation: workspace.slug
    )

    assert_nil WorkspaceDeletion.perform!(request:, object_purger: ->(*) { raise Timeout::Error })

    assert request.reload.failed?
    assert_equal "timeout_error", request.failure_code
    assert Workspace.exists?(workspace.id)
    assert_equal "workspace.deletion_failed", workspace.audit_events.order(:id).last.action

    assert_enqueued_with job: WorkspaceDeletionJob do
      WorkspaceDeletion.retry!(workspace:, membership: memberships(:owner_support))
    end
    assert request.reload.pending?

    request.update!(status: :failed, failure_code: "timeout_error", completed_at: Time.current)
    assert_nil WorkspaceDeletion.perform!(request:, object_purger: ->(*) { flunk "retried without an owner" })
    assert_equal 1, request.reload.attempt_count
  end
end
