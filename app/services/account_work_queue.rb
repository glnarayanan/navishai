class AccountWorkQueue
  VIEWS = %w[
    needs_attention
    renewal_approaching
    interventions_awaiting_approval
    interventions_overdue
    completed_awaiting_outcome_review
    all_accounts
  ].freeze
  PAGE_SIZE = 50
  REASONS = %w[
    health_unknown
    material_change
    open_investigation
    renewal_approaching
    intervention_awaiting_approval
    intervention_overdue
    completed_awaiting_outcome_review
  ].freeze

  Row = Data.define(
    :account, :assessment, :open_investigation, :relevant_intervention, :inclusion_reasons, :as_of, :view
  ) do
    def health_unknown? = assessment.nil?
    def renewal_unknown? = assessment.nil? || assessment.renewal_on.nil?
    def comparable_material_change? = assessment&.material_change? && assessment.previous_assessment_id.present?
    def accountable_membership = relevant_intervention&.accountable_membership
    def action_anchor
      case view
      when "interventions_awaiting_approval", "interventions_overdue", "completed_awaiting_outcome_review"
        "customer-success-interventions"
      when "renewal_approaching"
        "health-assessment"
      else
        return "risk-reviews" if inclusion_reasons.include?("open_investigation")
        return "customer-success-interventions" if inclusion_reasons.intersect?(
          %w[intervention_awaiting_approval intervention_overdue completed_awaiting_outcome_review]
        )

        "health-assessment" if assessment
      end
    end
  end

  Page = Data.define(:view, :rows, :page, :has_next_page, :as_of)

  def initialize(workspace:, as_of: Date.current)
    @workspace = workspace
    @as_of = as_of
    @renewal_until = as_of + AccountHealth::RENEWAL_WINDOW_DAYS
  end

  def counts
    row = Account.connection.select_one(
      Account.sanitize_sql_array(
        [
          <<~SQL.squish,
            SELECT
              COUNT(*) FILTER (WHERE #{needs_attention_sql}) AS needs_attention,
              COUNT(*) FILTER (WHERE #{renewal_sql}) AS renewal_approaching,
              COUNT(*) FILTER (WHERE #{awaiting_approval_sql}) AS interventions_awaiting_approval,
              COUNT(*) FILTER (WHERE #{overdue_sql}) AS interventions_overdue,
              COUNT(*) FILTER (WHERE #{outcome_review_sql}) AS completed_awaiting_outcome_review,
              COUNT(*) AS all_accounts
            FROM accounts
            WHERE workspace_id = ?
          SQL
          @workspace.id
        ]
      )
    )
    VIEWS.index_with { |view| row.fetch(view).to_i }
  end

  def page(view:, page: 1)
    view = view.to_s
    raise ArgumentError, "Unknown account work view" unless VIEWS.include?(view)

    page = [ page.to_i, 1 ].max
    ids = account_ids_for(view:, page:)
    has_next = ids.length > PAGE_SIZE
    ids = ids.first(PAGE_SIZE)
    Page.new(view:, rows: rows_for(ids, view:), page:, has_next_page: has_next, as_of: @as_of)
  end

  private
    def account_ids_for(view:, page:)
      filter = view_filter_sql(view)
      offset = (page - 1) * PAGE_SIZE
      Account.connection.select_values(
        Account.sanitize_sql_array(
          [
            <<~SQL.squish,
              SELECT accounts.id
              FROM accounts
              WHERE accounts.workspace_id = ?
                AND #{filter}
              ORDER BY
                CASE WHEN #{overdue_sql} THEN 0 ELSE 1 END ASC,
                #{due_expression_sql(view)} ASC NULLS LAST,
                accounts.id ASC
              LIMIT ?
              OFFSET ?
            SQL
            @workspace.id,
            PAGE_SIZE + 1,
            offset
          ]
        )
      ).map(&:to_i)
    end

    def rows_for(ids, view:)
      return [] if ids.empty?

      accounts = @workspace.accounts.where(id: ids).index_by(&:id)
      assessments = latest_assessments(ids)
      ActiveRecord::Associations::Preloader.new(records: assessments.values, associations: :previous_assessment).call
      investigations = open_investigations(ids)
      interventions_by_account = relevant_interventions_by_account(ids)
      ids.filter_map do |id|
        account = accounts[id]
        next unless account

        assessment = assessments[id]
        interventions = interventions_by_account[id] || []
        Row.new(
          account:, assessment:, open_investigation: investigations[id],
          relevant_intervention: interventions.min_by { |intervention| intervention_sort_key(intervention) },
          inclusion_reasons: reasons_for(assessment:, investigation: investigations[id], interventions:),
          as_of: @as_of, view:
        )
      end
    end

    def latest_assessments(ids)
      @workspace.account_health_assessments
        .where(account_id: ids)
        .select("DISTINCT ON (account_id) account_health_assessments.*")
        .order(account_id: :asc, calculated_at: :desc, id: :desc)
        .index_by(&:account_id)
    end

    def open_investigations(ids)
      @workspace.account_risk_investigations
        .where(account_id: ids, status: %w[detected investigating])
        .select("DISTINCT ON (account_id) account_risk_investigations.*")
        .order(account_id: :asc, opened_at: :desc, id: :desc)
        .index_by(&:account_id)
    end

    def relevant_interventions_by_account(ids)
      @workspace.customer_success_interventions
        .includes(:outcome_review, accountable_membership: :user)
        .where(account_id: ids)
        .where(status: %w[proposed approved completed])
        .order(:account_id, :target_on, :id)
        .to_a
        .select { |intervention| relevant_intervention?(intervention) }
        .group_by(&:account_id)
    end

    def relevant_intervention?(intervention)
      intervention.proposed? || intervention.approved? ||
        (intervention.completed? && intervention.outcome_review.nil?)
    end

    def intervention_sort_key(intervention)
      urgency = if intervention.overdue?(on: @as_of)
        0
      elsif intervention.proposed?
        1
      elsif intervention.completed?
        2
      else
        3
      end
      [ urgency, intervention.target_on, intervention.id ]
    end

    def reasons_for(assessment:, investigation:, interventions:)
      reasons = []
      reasons << "health_unknown" if assessment.nil?
      reasons << "material_change" if assessment&.material_change? && assessment.previous_assessment_id.present?
      reasons << "open_investigation" if investigation
      if assessment&.renewal_on && assessment.renewal_on.between?(@as_of, @renewal_until)
        reasons << "renewal_approaching"
      end
      reasons << "intervention_overdue" if interventions.any? { |intervention| intervention.overdue?(on: @as_of) }
      reasons << "intervention_awaiting_approval" if interventions.any?(&:proposed?)
      if interventions.any? { |intervention| intervention.completed? && intervention.outcome_review.nil? }
        reasons << "completed_awaiting_outcome_review"
      end
      reasons
    end

    def view_filter_sql(view)
      case view
      when "needs_attention" then needs_attention_sql
      when "renewal_approaching" then renewal_sql
      when "interventions_awaiting_approval" then awaiting_approval_sql
      when "interventions_overdue" then overdue_sql
      when "completed_awaiting_outcome_review" then outcome_review_sql
      when "all_accounts" then "TRUE"
      end
    end

    def due_expression_sql(view)
      case view
      when "renewal_approaching"
        "(#{latest_renewal_sql})"
      when "interventions_awaiting_approval"
        "(#{earliest_target_sql("proposed")})"
      when "interventions_overdue"
        "(#{earliest_overdue_target_sql})"
      when "completed_awaiting_outcome_review"
        "(#{earliest_completed_on_sql})"
      else
        "LEAST(#{earliest_overdue_target_sql}, #{earliest_target_sql("proposed")}, #{earliest_completed_on_sql}, #{latest_renewal_sql})"
      end
    end

    def needs_attention_sql
      <<~SQL.squish
        (
          NOT EXISTS (#{latest_assessment_sql})
          OR EXISTS (#{latest_assessment_sql("assessments.material_change AND assessments.previous_assessment_id IS NOT NULL")})
          OR EXISTS (#{open_investigation_sql})
          OR #{awaiting_approval_sql}
          OR #{overdue_sql}
          OR #{outcome_review_sql}
        )
      SQL
    end

    def renewal_sql
      "EXISTS (#{latest_assessment_sql("assessments.renewal_on BETWEEN DATE #{quoted_date} AND DATE #{quoted_date(@renewal_until)}")})"
    end

    def awaiting_approval_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM customer_success_interventions interventions
          WHERE interventions.workspace_id = accounts.workspace_id
            AND interventions.account_id = accounts.id
            AND interventions.status = 'proposed'
        )
      SQL
    end

    def overdue_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM customer_success_interventions interventions
          WHERE interventions.workspace_id = accounts.workspace_id
            AND interventions.account_id = accounts.id
            AND interventions.status IN ('proposed', 'approved')
            AND interventions.target_on < DATE #{quoted_date}
        )
      SQL
    end

    def outcome_review_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM customer_success_interventions interventions
          WHERE interventions.workspace_id = accounts.workspace_id
            AND interventions.account_id = accounts.id
            AND interventions.status = 'completed'
            AND NOT EXISTS (
              SELECT 1 FROM customer_success_intervention_outcome_reviews reviews
              WHERE reviews.customer_success_intervention_id = interventions.id
                AND reviews.workspace_id = interventions.workspace_id
            )
        )
      SQL
    end

    def latest_assessment_sql(extra = nil)
      extras = extra.present? ? "AND #{extra}" : ""
      <<~SQL.squish
        SELECT 1 FROM account_health_assessments assessments
        WHERE assessments.workspace_id = accounts.workspace_id
          AND assessments.account_id = accounts.id
          AND assessments.id = (
            SELECT latest.id FROM account_health_assessments latest
            WHERE latest.workspace_id = accounts.workspace_id
              AND latest.account_id = accounts.id
            ORDER BY latest.calculated_at DESC, latest.id DESC
            LIMIT 1
          )
          #{extras}
      SQL
    end

    def open_investigation_sql
      <<~SQL.squish
        SELECT 1 FROM account_risk_investigations investigations
        WHERE investigations.workspace_id = accounts.workspace_id
          AND investigations.account_id = accounts.id
          AND investigations.status IN ('detected', 'investigating')
      SQL
    end

    def latest_renewal_sql
      <<~SQL.squish
        (
          SELECT assessments.renewal_on FROM account_health_assessments assessments
          WHERE assessments.workspace_id = accounts.workspace_id
            AND assessments.account_id = accounts.id
          ORDER BY assessments.calculated_at DESC, assessments.id DESC
          LIMIT 1
        )
      SQL
    end

    def earliest_target_sql(status)
      <<~SQL.squish
        (
          SELECT MIN(interventions.target_on) FROM customer_success_interventions interventions
          WHERE interventions.workspace_id = accounts.workspace_id
            AND interventions.account_id = accounts.id
            AND interventions.status = #{Account.connection.quote(status)}
        )
      SQL
    end

    def earliest_overdue_target_sql
      <<~SQL.squish
        (
          SELECT MIN(interventions.target_on) FROM customer_success_interventions interventions
          WHERE interventions.workspace_id = accounts.workspace_id
            AND interventions.account_id = accounts.id
            AND interventions.status IN ('proposed', 'approved')
            AND interventions.target_on < DATE #{quoted_date}
        )
      SQL
    end

    def earliest_completed_on_sql
      <<~SQL.squish
        (
          SELECT MIN(interventions.completed_at::date) FROM customer_success_interventions interventions
          WHERE interventions.workspace_id = accounts.workspace_id
            AND interventions.account_id = accounts.id
            AND interventions.status = 'completed'
            AND NOT EXISTS (
              SELECT 1 FROM customer_success_intervention_outcome_reviews reviews
              WHERE reviews.customer_success_intervention_id = interventions.id
                AND reviews.workspace_id = interventions.workspace_id
            )
        )
      SQL
    end

    def quoted_date(value = @as_of)
      Account.connection.quote(value.iso8601)
    end
end
