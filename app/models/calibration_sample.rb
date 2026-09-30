class CalibrationSample < ImmutableRecord
  belongs_to :workspace
  belongs_to :corpus
  belongs_to :calibration_set
  belongs_to :grader_version
  belongs_to :eval_case_check
  belongs_to :created_by, class_name: "User"
  has_one :calibration_prediction
  has_one :calibration_judge_run
  has_many :human_labels
  validates :cohort, inclusion: { in: %w[development held_out] }
  validate -> { SupportOutput.validate!(output) }

  def latest_labels
    human_labels.where(id: human_labels.select("MAX(id)").group(:labelled_by_id))
  end

  def label!(membership:, previous_id:, decision:, rationale:)
    corpus.with_lock do
      corpus.authorize_writer!(membership)
      raise EvalCase::Invalid, "Source retention ended. This sample is no longer available." if corpus.eval_definitions_expired?
      latest = human_labels.where(labelled_by: membership.user).order(id: :desc).first
      raise EvalCase::Invalid, "Your label changed. Reload before saving." unless latest&.id.to_s == previous_id.to_s
      return latest if latest && latest.decision == decision && latest.rationale == rationale
      label = human_labels.create!(workspace:, corpus:, labelled_by: membership.user, decision:, rationale:, created_at: Time.current)
      AuditEvent.record!(action: "calibration.labelled", source: :web, workspace:, actor: membership.user, subject: label)
      label
    end
  end
end
