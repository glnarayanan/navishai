class ResolutionContractConfiguration
  class InvalidConfiguration < StandardError; end
  class StalePublication < InvalidConfiguration; end

  DEFAULT_FRESHNESS_DAYS = {
    "knowledge" => 30,
    "conversation" => 365,
    "case" => 30,
    "account" => 30,
    "health_signal" => 14,
    "public_web" => 7,
    "memory" => 30
  }.freeze
  DEFAULTS = {
    "support_resolution" => {
      required_claim_categories: %w[customer_account_fact product_technical_fact],
      mandatory_review_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort,
      execution_budget_units: 100_000,
      missing_items_block: true
    },
    "customer_success_intervention" => {
      required_claim_categories: %w[customer_account_fact promised_action_date],
      mandatory_review_checks: ResolutionContractVersion::REVIEW_CHECKS.keys.sort,
      execution_budget_units: 100_000,
      missing_items_block: true
    }
  }.freeze

  def self.install_defaults!(workspace:)
    new(workspace:).install_defaults!
  end

  def self.publish!(workspace:, membership:, family:, attributes:)
    new(workspace:, membership:).publish!(family:, attributes:)
  end

  def initialize(workspace:, membership: nil)
    @workspace = workspace
    @membership = membership && workspace.memberships.find(membership.id)
  end

  def install_defaults!
    ResolutionContractFamily.transaction do
      lock_workspace!
      ResolutionContractFamily::FAMILIES.each_key do |family_key|
        family = @workspace.resolution_contract_families.find_or_create_by!(family_key:)
        next if family.current_version

        version = family.versions.create!(
          workspace: @workspace, version_number: 1,
          evidence_freshness_days: DEFAULT_FRESHNESS_DAYS,
          **DEFAULTS.fetch(family_key)
        )
        family.update!(current_version: version)
      end
    end
    @workspace.resolution_contract_families.includes(:current_version).order(:family_key)
  end

  def publish!(family:, attributes:)
    authorize!
    @workspace.resolution_contract_families.find(family.id)
    raise InvalidConfiguration,
      "Resolution policy requires an immutable proposal, retained-fact preview, and explicit canary."
  end

  private
    def normalized_values(family, attributes)
      categories = bounded_values(attributes[:required_claim_categories], ResolutionContractVersion::CLAIM_CATEGORIES)
      checks = bounded_values(attributes[:mandatory_review_checks], ResolutionContractVersion::REVIEW_CHECKS)
      submitted_freshness = attributes.fetch(:evidence_freshness_days, {}).with_indifferent_access
      freshness = ResolutionContractVersion::SOURCE_KINDS.keys.to_h do |kind|
        [ kind, strict_integer(submitted_freshness[kind], "Freshness must use whole days.") ]
      end
      values = {
        required_claim_categories: categories,
        evidence_freshness_days: freshness,
        mandatory_review_checks: checks,
        execution_budget_units: strict_integer(attributes[:execution_budget_units], "Budget must be a whole number."),
        missing_items_block: ActiveModel::Type::Boolean.new.cast(attributes[:missing_items_block])
      }
      candidate = ResolutionContractVersion.new(
        workspace: @workspace,
        resolution_contract_family: family,
        version_number: family.versions.maximum(:version_number).to_i + 1,
        **values
      )
      raise InvalidConfiguration, candidate.errors.full_messages.to_sentence unless candidate.valid?

      values
    end

    def bounded_values(values, allowed)
      selected = Array(values).compact_blank.map(&:to_s).uniq.sort
      raise InvalidConfiguration, "Choose at least one supported option." if selected.empty? || (selected - allowed.keys).any?

      selected
    end

    def strict_integer(value, message)
      Integer(value.to_s, 10)
    rescue ArgumentError, TypeError
      raise InvalidConfiguration, message
    end

    def same_version?(version, values)
      values.all? { |attribute, value| version.public_send(attribute) == value }
    end

    def authorize!
      raise Current::RoleAccessDenied unless @membership&.can_configure_agents?
    end

    def lock_workspace!
      value = ResolutionContractFamily.connection.quote("resolution-contracts:#{@workspace.id}")
      ResolutionContractFamily.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{value}))")
    end
end
