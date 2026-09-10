class SupportCaseProduct < ApplicationRecord
  belongs_to :workspace
  belongs_to :support_case
  belongs_to :product
end
