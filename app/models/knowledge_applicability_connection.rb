class KnowledgeApplicabilityConnection < ApplicationRecord
  belongs_to :workspace
  belongs_to :knowledge_applicability
  belongs_to :intercom_connection
end
