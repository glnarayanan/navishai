class AccountHealthRecalculationJob < ApplicationJob
  queue_as :background

  def self.enqueue_after_commit(account)
    return unless account

    ActiveRecord.after_all_transactions_commit do
      perform_later(account.canonical.id)
    rescue ActiveJob::EnqueueError
      Rails.logger.error("Account health recalculation enqueue failed for account #{account.id}")
    end
  end

  def perform(account_id)
    account = Account.find(account_id).canonical
    return if account.workspace.deletion_requested?

    AccountHealth.recalculate!(workspace: account.workspace, account:, trigger_kind: "input_change")
  end
end
