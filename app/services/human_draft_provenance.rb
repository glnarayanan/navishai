class HumanDraftProvenance
  MAX_RECORD_ID = 9_223_372_036_854_775_807
  ATTRIBUTES = %i[
    source_crew_artifact generated_body_digest generated_contract_result_state
    human_edited_by_membership human_edited_by_user human_edited_at
  ].freeze

  def self.apply!(draft:, workspace:, support_case:, membership:, body:, source_crew_artifact_id: nil,
    adopt_source: false, follow_up: false, changed_at: Time.current)
    new(
      draft:, workspace:, support_case:, membership:, body:, source_crew_artifact_id:,
      adopt_source:, follow_up:, changed_at:
    ).apply!
  end

  def self.delivery_attributes(draft)
    ATTRIBUTES.to_h { |name| [ name, draft.public_send(name) ] }
  end

  def initialize(draft:, workspace:, support_case:, membership:, body:, source_crew_artifact_id:,
    adopt_source:, follow_up:, changed_at:)
    @draft = draft
    @workspace = workspace
    @support_case = support_case
    @membership = membership
    @body = body
    @source_crew_artifact_id = source_crew_artifact_id
    @adopt_source = adopt_source
    @follow_up = follow_up
    @changed_at = changed_at
  end

  def apply!
    active_source = @follow_up ? nil : @draft.source_crew_artifact
    selected_source = source_artifact if @source_crew_artifact_id.present?

    if @adopt_source
      raise ArgumentError, "Choose an AI draft to use." unless selected_source
      raise ArgumentError, "The AI draft body changed. Choose it again." unless @body == selected_source.body

      assign_source(selected_source)
    else
      if selected_source && selected_source != active_source
        raise ArgumentError, "Choose Use this AI draft before editing its text."
      end
      active_source ? preserve_source(active_source) : clear_source
    end
    @draft
  end

  private
    def source_artifact
      raw_id = @source_crew_artifact_id.to_s
      unless raw_id.match?(/\A[1-9][0-9]{0,18}\z/) && raw_id.to_i <= MAX_RECORD_ID
        raise ActiveRecord::RecordNotFound
      end

      artifact = @workspace.crew_artifacts.includes(:crew_task).find(raw_id)
      task = artifact.crew_task
      unless artifact.draft? && task.scope_kind == "support_case" && task.support_case_id == @support_case.id
        raise ActiveRecord::RecordNotFound
      end
      artifact
    end

    def assign_source(source)
      @draft.assign_attributes(
        source_crew_artifact: source,
        generated_body_digest: Digest::SHA256.hexdigest(source.body),
        generated_contract_result_state: source.contract_result_state,
        human_edited_by_membership: nil,
        human_edited_by_user: nil,
        human_edited_at: nil
      )
    end

    def preserve_source(source)
      return if @draft.human_edited_at?
      return if @draft.generated_body_digest == Digest::SHA256.hexdigest(@body.to_s)

      @draft.assign_attributes(
        source_crew_artifact: source,
        human_edited_by_membership: @membership,
        human_edited_by_user: @membership.user,
        human_edited_at: @changed_at
      )
    end

    def clear_source
      @draft.assign_attributes(ATTRIBUTES.index_with(nil))
    end
end
