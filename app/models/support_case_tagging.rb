class SupportCaseTagging < ApplicationRecord
  belongs_to :workspace
  belongs_to :support_case
  belongs_to :tag

  validates :tag_id, uniqueness: { scope: :support_case_id }
end
