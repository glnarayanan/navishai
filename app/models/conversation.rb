class Conversation < ApplicationRecord
  belongs_to :workspace
  belongs_to :contact

  has_many :conversation_messages, -> { order(occurred_at: :asc, id: :asc) }, dependent: :restrict_with_exception
  has_one :support_case, dependent: :restrict_with_exception

  normalizes :subject, with: ->(subject) { subject.strip }
  validates :subject, length: { maximum: 500 }, allow_nil: true
  validates :started_at, presence: true
end
