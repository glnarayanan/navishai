class CaseNote < ApplicationRecord
  belongs_to :workspace
  belongs_to :support_case
  belongs_to :author, class_name: "User"

  validates :body, presence: true

  def readonly?
    persisted?
  end
end
