class UsageRateConfiguration
  class InvalidConfiguration < StandardError; end

  RATE_FIELDS = %i[input output search].freeze
  MAX_PRICE_PER_MILLION = 1_000_000

  def self.publish!(workspace:, membership:, attributes:, published_at: Time.current)
    new(workspace:, membership:).publish!(attributes:, published_at:)
  end

  def self.rollback!(workspace:, membership:, version:, expected_current_version_id:)
    new(workspace:, membership:).rollback!(version:, expected_current_version_id:)
  end

  def self.display_rate(micros)
    return nil if micros.nil?

    format("%.6f", BigDecimal(micros.to_s) / 1_000_000).sub(/0+\z/, "").sub(/\.\z/, "")
  end

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
  end

  def publish!(attributes:, published_at:)
    authorize!
    values = normalized(attributes)
    UsageRateSetting.transaction do
      setting = locked_setting
      assert_current!(setting, attributes[:expected_current_version_id])
      version = setting.versions.create!(
        workspace: @workspace,
        version_number: setting.versions.maximum(:version_number).to_i + 1,
        currency: values.fetch(:currency), source_name: values.fetch(:source_name),
        input_rate_micros_per_million: values[:input_rate_micros_per_million],
        output_rate_micros_per_million: values[:output_rate_micros_per_million],
        search_rate_micros_per_million: values[:search_rate_micros_per_million],
        created_by_membership: @membership, created_by_user: @membership.user,
        published_at:
      )
      previous = setting.current_version_id
      setting.update!(current_version: version)
      AuditEvent.record!(
        action: "usage_rate.published", source: :web, workspace: @workspace,
        actor: @membership.user, subject: version,
        metadata: { "from_version" => previous ? version_number(previous) : 0, "to_version" => version.version_number },
        occurred_at: published_at
      )
      version
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    message = error.respond_to?(:record) ? error.record.errors.full_messages.to_sentence : "Rates changed while you were editing."
    raise InvalidConfiguration, message
  end

  def rollback!(version:, expected_current_version_id:)
    authorize!
    UsageRateSetting.transaction do
      setting = @workspace.usage_rate_setting&.lock! || raise(InvalidConfiguration, "No rate version is published.")
      assert_current!(setting, expected_current_version_id)
      target = setting.versions.find(version.id)
      raise InvalidConfiguration, "That rate version is already current." if target == setting.current_version

      previous = setting.current_version
      setting.update!(current_version: target)
      AuditEvent.record!(
        action: "usage_rate.rolled_back", source: :web, workspace: @workspace,
        actor: @membership.user, subject: target,
        metadata: { "from_version" => previous.version_number, "to_version" => target.version_number }
      )
      target
    end
  end

  private
    def authorize!
      raise Current::RoleAccessDenied unless @membership.can_configure_agents?
    end

    def locked_setting
      @workspace.lock!
      @workspace.usage_rate_setting&.lock! || @workspace.create_usage_rate_setting!
    end

    def assert_current!(setting, expected)
      expected_id = expected.to_s.match?(/\A[1-9][0-9]*\z/) ? expected.to_i : nil
      unless setting.current_version_id == expected_id
        raise InvalidConfiguration, "Rates changed while you were editing. Review the current version and try again."
      end
    end

    def normalized(attributes)
      currency = attributes[:currency].to_s.strip.upcase
      source_name = attributes[:source_name].to_s.strip.squish
      raise InvalidConfiguration, "Currency must be a three-letter code." unless currency.match?(/\A[A-Z]{3}\z/)
      raise InvalidConfiguration, "Rate source must be between 1 and 100 characters." unless source_name.bytesize.in?(1..100)

      rates = RATE_FIELDS.to_h do |field|
        [ "#{field}_rate_micros_per_million".to_sym, rate_micros(attributes["#{field}_rate".to_sym], field) ]
      end
      raise InvalidConfiguration, "Set at least one rate." if rates.values.all?(&:nil?)

      rates.merge(currency:, source_name:)
    end

    def rate_micros(value, field)
      return nil if value.to_s.strip.blank?

      decimal = BigDecimal(value.to_s)
      unless decimal >= 0 && decimal <= MAX_PRICE_PER_MILLION && decimal.frac.to_s("F").delete_prefix("0.").length <= 6
        raise InvalidConfiguration, "#{field.to_s.humanize} rate must be between 0 and #{MAX_PRICE_PER_MILLION} with at most six decimal places."
      end
      (decimal * 1_000_000).to_i
    rescue ArgumentError
      raise InvalidConfiguration, "#{field.to_s.humanize} rate must be a number."
    end

    def version_number(id)
      @workspace.usage_rate_versions.find(id).version_number
    end
end
