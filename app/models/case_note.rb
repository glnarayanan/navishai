class CaseNote < ApplicationRecord
  belongs_to :workspace
  belongs_to :support_case
  belongs_to :author, class_name: "User"

  validates :body, presence: true

  after_create_commit :recalculate_account_health

  def readonly?
    persisted?
  end

  private
    def recalculate_account_health
      AccountHealthRecalculationJob.enqueue_after_commit(support_case.conversation.contact.account)
    end
end
