require "test_helper"

class SupportCaseTest < ActiveSupport::TestCase
  test "database rejects an assignee from another workspace" do
    support_case = new_case

    assert_raises(ActiveRecord::StatementInvalid) do
      SupportCase.transaction(requires_new: true) do
        support_case.update_column(:assigned_membership_id, memberships(:outsider_beta).id)
      end
    end
  end

  test "requires timestamps that match terminal state" do
    support_case = new_case
    support_case.status = :resolved

    assert_not support_case.valid?
    assert_includes support_case.errors[:resolved_at], "does not match status"

    support_case.resolved_at = Time.current
    assert support_case.valid?
  end

  test "tag names are case insensitive only within one workspace" do
    Tag.create!(workspace: workspaces(:acme_support), name: "Billing")

    duplicate = Tag.new(workspace: workspaces(:acme_support), name: "billing")
    assert_not duplicate.valid?
    assert Tag.create!(workspace: workspaces(:beta_support), name: "billing")
  end

  private
    def new_case
      ConversationThread.start!(
        workspace: workspaces(:acme_support), contact: contacts(:alice),
        membership: memberships(:owner_support), occurred_at: Time.current
      ).support_case
    end
end
