class KnowledgeApplicabilityProduct < ApplicationRecord
  belongs_to :workspace
  belongs_to :knowledge_applicability
  belongs_to :product
end
