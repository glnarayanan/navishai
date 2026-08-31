class RuntimeRegistry
  class InvalidPolicy < StandardError; end

  def self.refresh!(workspace:, membership:, client: RunnerClient.new)
    new(workspace:, membership:).refresh!(client:)
  end

  def self.update_approval!(workspace:, membership:, installation:, attributes:)
    new(workspace:, membership:).update_approval!(installation:, attributes:)
  end

  def self.test!(workspace:, membership:, installation:, client: RunnerClient.new)
    new(workspace:, membership:).test!(installation:, client:)
  end

  def self.invalidate_adapter!(workspace:, membership:, adapter_key:)
    new(workspace:, membership:).invalidate_adapter!(adapter_key:)
  end

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless @membership.can_configure_agents?
  end

  def refresh!(client:)
    reports = client.detect_runtimes!(workspace_key: @workspace.runner_key)
    RuntimeInstallation.transaction do
      lock_workspace!
      seen = reports.map { |report| report.fetch("detection_key") }
      reports.each { |report| persist_report!(report) }
      @workspace.runtime_installations.where.not(detection_key: seen).find_each do |installation|
        audit_revoke!(installation) if installation.approved?
        reset_runtime_test!(installation)
        installation.update!(health_status: "missing", checked_at: Time.current)
      end
      AuditEvent.record!(
        action: "runtime.installations_checked", source: :web, workspace: @workspace,
        actor: @membership.user, subject: @workspace, metadata: { "detected_count" => reports.size }
      )
    end
    @workspace.runtime_installations.ordered
  rescue ActiveRecord::RecordInvalid, KeyError, ArgumentError => error
    raise InvalidPolicy, error.message
  end

  def update_approval!(installation:, attributes:)
    record = @workspace.runtime_installations.find(installation.id)
    approve = ActiveModel::Type::Boolean.new.cast(attributes[:approved])
    RuntimeInstallation.transaction do
      record.lock!
      if approve
        raise InvalidPolicy, "Only an available, compatible provider can run." unless record.health_status == "available" && record.compatibility_status != "incompatible"
        unless record.runtime_test_status == "passed" &&
            record.runtime_tested_configuration_fingerprint == record.configuration_fingerprint
          raise InvalidPolicy, "Test the current provider configuration successfully before allowing access."
        end
        record.update!(
          approved: true, approved_by_membership: @membership, approved_by_user: @membership.user,
          approved_at: Time.current,
          allowed_role_keys: normalized_values(attributes[:allowed_role_keys]),
          allowed_tools: normalized_values(attributes[:allowed_tools]),
          allowed_data_classes: normalized_values(attributes[:allowed_data_classes]),
          profile_keys: normalized_values(attributes[:profile_keys]),
          max_timeout_seconds: strict_integer(attributes[:max_timeout_seconds]),
          max_steps: strict_integer(attributes[:max_steps]),
          max_tool_calls: strict_integer(attributes[:max_tool_calls]),
          max_input_units: strict_integer(attributes[:max_input_units]),
          max_output_units: strict_integer(attributes[:max_output_units])
        )
      else
        revoke!(record)
      end
      AuditEvent.record!(
        action: approve ? "runtime.installation_approved" : "runtime.installation_revoked",
        source: :web, workspace: @workspace, actor: @membership.user, subject: record
      )
    end
    record
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidPolicy, error.record.errors.full_messages.to_sentence
  end

  def test!(installation:, client:)
    record = @workspace.runtime_installations.find(installation.id)
    unless record.health_status == "available" && record.compatibility_status != "incompatible"
      raise InvalidPolicy, "Only an available, compatible provider can be tested."
    end
    request_id = SecureRandom.uuid
    response = client.test_runtime!(
      workspace_key: @workspace.runner_key, request_id:, detection_key: record.detection_key,
      configuration_fingerprint: record.configuration_fingerprint
    )
    RuntimeInstallation.transaction do
      record.lock!
      unless record.health_status == "available" && record.compatibility_status != "incompatible" &&
          response.fetch("configuration_fingerprint") == record.configuration_fingerprint &&
          response.fetch("effective_model") == record.effective_model
        raise InvalidPolicy, "Provider configuration changed. Find providers again before testing."
      end
      audit_revoke!(record) if response.fetch("status") == "failed" && record.approved?
      record.update!(
        runtime_test_status: response.fetch("status"),
        runtime_test_failure_code: response.fetch("failure_code"),
        runtime_tested_at: Time.iso8601(response.fetch("tested_at")),
        runtime_tested_configuration_fingerprint: response.fetch("configuration_fingerprint"),
        runtime_test_usage_observed: response.fetch("usage_observed"),
        runtime_test_input_units: response.fetch("input_units"),
        runtime_test_output_units: response.fetch("output_units")
      )
      AuditEvent.record!(
        action: "runtime.installation_tested", source: :web, workspace: @workspace,
        actor: @membership.user, subject: record, metadata: { "status" => record.runtime_test_status }
      )
    end
    record
  rescue ActiveRecord::RecordInvalid, KeyError, ArgumentError => error
    raise InvalidPolicy, error.message
  end

  def invalidate_adapter!(adapter_key:)
    RuntimeInstallation.transaction do
      lock_workspace!
      @workspace.runtime_installations.where(adapter_key:).lock.find_each do |installation|
        audit_revoke!(installation) if installation.approved?
        reset_runtime_test!(installation)
        installation.save!
      end
    end
  rescue ActiveRecord::RecordInvalid => error
    raise InvalidPolicy, error.record.errors.full_messages.to_sentence
  end

  private
    def persist_report!(report)
      installation = @workspace.runtime_installations.find_or_initialize_by(detection_key: report.fetch("detection_key"))
      detected = {
        adapter_key: report.fetch("adapter_key"), protocol_version: report.fetch("protocol_version"),
        executable_path: report.fetch("executable_path"), executable_version: report.fetch("executable_version"),
        account_metadata: report.fetch("account_metadata"), capabilities: report.fetch("capabilities").sort,
        effective_model: report.fetch("effective_model"),
        configuration_fingerprint: report.fetch("configuration_fingerprint"),
        minimum_version: report.fetch("minimum_version"), maximum_version: report.fetch("maximum_version"),
        compatibility_status: report.fetch("compatibility_status"),
        incompatibility_reason: report.fetch("incompatibility_reason"), health_status: report.fetch("health_status"),
        checked_at: Time.iso8601(report.fetch("checked_at"))
      }
      material_changed = installation.persisted? && detected.except(:checked_at, :health_status).any? do |attribute, value|
        installation.public_send(attribute) != value
      end
      audit_revoke!(installation) if material_changed && installation.approved?
      reset_runtime_test!(installation) if material_changed
      installation.assign_attributes(detected)
      installation.allowed_role_keys = [] unless installation.persisted?
      installation.allowed_tools = [] unless installation.persisted?
      installation.allowed_data_classes = [] unless installation.persisted?
      installation.profile_keys = [ "workspace_default" ] unless installation.persisted?
      installation.save!
    end

    def revoke!(installation)
      installation.assign_attributes(
        approved: false, approved_by_membership: nil, approved_by_user: nil, approved_at: nil
      )
    end

    def reset_runtime_test!(installation)
      installation.assign_attributes(
        runtime_test_status: "untested", runtime_test_failure_code: nil, runtime_tested_at: nil,
        runtime_tested_configuration_fingerprint: nil, runtime_test_input_units: 0,
        runtime_test_output_units: 0, runtime_test_usage_observed: false
      )
    end

    def audit_revoke!(installation)
      revoke!(installation)
      AuditEvent.record!(
        action: "runtime.installation_revoked", source: :web, workspace: @workspace,
        actor: @membership.user, subject: installation
      )
    end

    def normalized_values(values)
      Array(values).compact_blank.map(&:to_s).uniq.sort
    end

    def strict_integer(value)
      Integer(value.to_s, 10)
    rescue ArgumentError, TypeError
      raise InvalidPolicy, "Budgets must be whole numbers."
    end

    def lock_workspace!
      quoted = RuntimeInstallation.connection.quote("runtime-registry:#{@workspace.id}")
      RuntimeInstallation.connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{quoted}))")
    end
end
