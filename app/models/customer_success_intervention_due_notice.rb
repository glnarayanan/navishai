class CustomerSuccessInterventionDueNotice < ApplicationRecord
  DUE_STATES = %w[due overdue].freeze

  belongs_to :workspace
  belongs_to :customer_success_intervention
  belongs_to :recipient_membership, class_name: "Membership"
  belongs_to :source_audit_event, class_name: "AuditEvent"

  enum :due_state, DUE_STATES.index_by(&:itself), validate: true, prefix: true

  validates :target_on, :notified_at, presence: true
  validates :due_state, uniqueness: { scope: [ :customer_success_intervention_id, :recipient_membership_id, :target_on ] }
end
