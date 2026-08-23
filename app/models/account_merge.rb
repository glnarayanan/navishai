class AccountMerge < ApplicationRecord
  belongs_to :workspace
  belongs_to :source, class_name: "Account"
  belongs_to :target, class_name: "Account"
  belongs_to :merged_by, class_name: "User"
  belongs_to :unmerged_by, class_name: "User", optional: true

  scope :active, -> { where(unmerged_at: nil) }
end
