require "test_helper"

class IdentityMatchReviewTest < ActiveSupport::TestCase
  setup do
    create_matched_identity(contacts(:alice_duplicate), "duplicate", "alice@example.com")
    @identity = SourceIdentityResolver.resolve!(
      workspace: workspaces(:acme_support),
      entity_kind: :contact,
      source_namespace: "intercom:primary",
      source_record_type: :contact,
      source_record_id: "ambiguous",
      keys: { email: "alice@example.com" }
    ).source_identity
  end

  test "manager-or-higher review resolves a recorded candidate once" do
    assert_difference "AuditEvent.count", 1 do
      selected = IdentityMatchReview.resolve!(
        workspace: workspaces(:acme_support),
        source_identity: @identity,
        target: contacts(:alice),
        membership: memberships(:owner_support)
      )
      assert_equal contacts(:alice), selected
    end

    assert @identity.reload.matched?
    assert @identity.reviewed?
    assert_equal users(:owner), @identity.resolved_by
    assert_raises(ActiveRecord::RecordInvalid) do
      IdentityMatchReview.resolve!(
        workspace: workspaces(:acme_support),
        source_identity: @identity,
        target: contacts(:alice),
        membership: memberships(:owner_support)
      )
    end
  end

  test "member and cross-workspace review fail without changing state" do
    member = Membership.create!(workspace: workspaces(:acme_support), user: users(:outsider), role: :member)
    beta_manager = Membership.create!(workspace: workspaces(:beta_support), user: users(:owner), role: :manager)

    assert_no_difference "AuditEvent.count" do
      assert_raises(Current::RoleAccessDenied) do
        IdentityMatchReview.resolve!(
          workspace: workspaces(:acme_support),
          source_identity: @identity,
          target: contacts(:alice),
          membership: member
        )
      end
      assert_raises(ActiveRecord::RecordNotFound) do
        IdentityMatchReview.resolve!(
          workspace: workspaces(:beta_support),
          source_identity: @identity,
          target: contacts(:alice),
          membership: beta_manager
        )
      end
    end
    assert @identity.reload.ambiguous?
  end

  private
    def create_matched_identity(contact, source_record_id, email)
      identity = SourceIdentity.create!(
        workspace: contact.workspace,
        entity_kind: :contact,
        source_namespace: "manual_import",
        source_record_type: :contact,
        source_record_id: source_record_id,
        status: :matched,
        contact: contact,
        resolution_method: :created,
        resolved_at: Time.current
      )
      identity.source_identity_keys.create!(workspace: contact.workspace, kind: :email, normalized_value: email)
    end
end
