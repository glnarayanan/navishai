require "digest"

class AccountDataImport
  class InvalidImport < StandardError; end
  MAX_BYTES = 2.megabytes
  FIELDS = %w[
    source_id source_namespace observed_at valid_from valid_until corrects_source_id
    account_name account_domain contact_name contact_email
    renewal_on contract_value active_users licensed_seats
  ].freeze

  def self.import_csv!(workspace:, membership:, content:)
    raise InvalidImport, "CSV is too large." if content.to_s.bytesize > MAX_BYTES

    rows = parse_csv(content.to_s)
    headers = rows.shift || []
    unknown = headers - FIELDS
    raise InvalidImport, "CSV contains unsupported columns: #{unknown.join(', ')}." if unknown.any?
    raise InvalidImport, "CSV headers must be present and unique." if headers.empty? || headers.any?(&:blank?) || headers.uniq.size != headers.size

    records = rows.reject { |row| row.all?(&:blank?) }.map do |row|
      raise InvalidImport, "CSV row has the wrong number of fields." unless row.size == headers.size
      headers.zip(row).to_h
    end
    new(workspace:, membership:).import!(records, source_kind: "csv")
  end

  def self.import_api!(workspace:, membership:, rows:)
    raise InvalidImport, "API payload must contain 1 to 500 records." unless rows.is_a?(Array) && rows.size.in?(1..500)
    raise InvalidImport, "API payload is too large." if JSON.generate(rows).bytesize > MAX_BYTES

    new(workspace:, membership:).import!(rows, source_kind: "api")
  rescue JSON::GeneratorError
    raise InvalidImport, "API payload is invalid."
  end

  def self.parse_csv(content)
    rows = []
    row = []
    field = +""
    quoted = false
    index = 0
    while index < content.length
      character = content[index]
      if quoted
        if character == '"' && content[index + 1] == '"'
          field << '"'
          index += 1
        elsif character == '"'
          quoted = false
        else
          field << character
        end
      elsif character == '"' && field.empty?
        quoted = true
      elsif character == ","
        row << field
        field = +""
      elsif character == "\n"
        row << field.delete_suffix("\r")
        rows << row
        row = []
        field = +""
      else
        field << character
      end
      index += 1
    end
    raise InvalidImport, "CSV contains an unclosed quoted field." if quoted
    rows << row.push(field) if field.present? || row.any?
    rows
  end
  private_class_method :parse_csv

  def initialize(workspace:, membership:)
    @workspace = workspace
    @membership = workspace.memberships.find(membership.id)
    raise Current::RoleAccessDenied unless @membership.can_manage_work?
  end

  def import!(rows, source_kind:)
    raise InvalidImport, "Import must contain 1 to 500 records." unless rows.size.in?(1..500)

    accounts = Set.new
    AccountHealthInput.transaction do
      rows.each_with_index do |raw, index|
        row = raw.to_h.stringify_keys.slice(*FIELDS)
        source_id = row["source_id"].to_s.strip
        raise InvalidImport, "Row #{index + 1} needs source_id and account_name." if source_id.blank? || row["account_name"].to_s.strip.blank?
        unless source_id.bytesize <= 255 && !source_id.match?(/[[:cntrl:]]/)
          raise InvalidImport, "Row #{index + 1} has an invalid source_id."
        end

        source_namespace = source_namespace(row, source_kind)
        account = resolve_account!(row, source_namespace, source_id)
        resolve_contact!(row, account, source_namespace, source_id) if row["contact_email"].present?
        import_inputs!(row, account, source_kind, source_namespace, source_id)
        accounts << account
      end
      accounts.each do |account|
        AccountHealth.recalculate!(workspace: @workspace, account:, trigger_kind: "input_change", membership: @membership)
      end
      AuditEvent.record!(action: "account.data_imported", source: :web, workspace: @workspace,
        actor: @membership.user, subject: @workspace,
        metadata: { "source_kind" => source_kind, "record_count" => rows.size })
    end
    accounts.size
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    raise InvalidImport, error.message
  end

  private
    def resolve_account!(row, source_namespace, source_id)
      domain = row["account_domain"].to_s.strip
      if domain.present?
        result = SourceIdentityResolver.resolve!(
          workspace: @workspace, entity_kind: :account, source_namespace:,
          source_record_type: :account, source_record_id: source_id, keys: { domain: domain },
          attributes: { name: row.fetch("account_name") }
        )
        raise InvalidImport, "Account identity is ambiguous for source #{source_id}." unless result.matched?
        result.record
      else
        name = row.fetch("account_name").strip
        @workspace.accounts.where("lower(name) = ?", name.downcase).first || create_account!(name)
      end
    end

    def create_account!(name)
      account = @workspace.accounts.create!(name:)
      AuditEvent.record!(action: "account.created", source: :web, workspace: @workspace,
        actor: @membership.user, subject: account)
      account
    end

    def resolve_contact!(row, account, source_namespace, source_id)
      result = SourceIdentityResolver.resolve!(
        workspace: @workspace, entity_kind: :contact, source_namespace:,
        source_record_type: :contact, source_record_id: source_id, keys: { email: row.fetch("contact_email") },
        attributes: { name: row["contact_name"].to_s.strip.presence, account: account }
      )
      raise InvalidImport, "Contact identity is ambiguous for source #{source_id}." unless result.matched?
      contact = result.record
      raise InvalidImport, "Contact belongs to a different account." if contact.account && contact.account.canonical != account.canonical
      contact.update!(account:) unless contact.account
    end

    def import_inputs!(row, account, source_kind, source_namespace, source_id)
      observed_at = optional_time(row["observed_at"], "Observed at")
      valid_from = optional_time(row["valid_from"], "Valid from")
      valid_until = optional_time(row["valid_until"], "Valid until")
      if valid_from && valid_until && valid_until < valid_from
        raise InvalidImport, "Valid until must not precede valid from."
      end

      AccountHealthInput::INPUTS.each do |key, kind|
        next if row[key].blank?

        attributes = typed_value(key, kind, row.fetch(key))
        correction = correction_for(row, account, source_namespace, key)
        metadata = { observed_at:, valid_from:, valid_until:, correction_digest: correction&.source_digest }.compact
        digest = source_digest(key, kind, attributes, metadata)
        locator = "evidence://#{source_namespace}/#{source_id}/#{key}"
        existing = @workspace.account_health_inputs.find_by(source_namespace:, source_key: source_id, input_key: key)
        if existing
          expected = attributes.merge(account_id: account.id, source_kind:, source_locator: locator, source_digest: digest,
            corrects_account_health_input_id: correction&.id)
          unless expected.all? { |name, value| existing.public_send(name) == value }
            raise InvalidImport, "Source #{source_id} changed #{key}; use a new source_id to retain history."
          end
          next
        end
        account.health_inputs.create!(workspace: @workspace, input_key: key, value_kind: kind,
          source_kind:, source_namespace:, source_key: source_id, source_digest: digest,
          source_locator: locator, observed_at: observed_at || Time.current, valid_from:, valid_until:,
          corrects_input: correction,
          supplied_by_membership: @membership, supplied_by_user: @membership.user, **attributes)
      end
    end

    def source_namespace(row, source_kind)
      value = row["source_namespace"].to_s.strip.presence || "#{source_kind}_import"
      raise InvalidImport, "Source namespace is invalid." unless value.match?(/\A[a-z][a-z0-9_.:-]{0,99}\z/)

      value
    end

    def correction_for(row, account, source_namespace, key)
      source_id = row["corrects_source_id"].to_s.strip
      return if source_id.blank?
      raise InvalidImport, "Correction source ID is invalid." if source_id.bytesize > 255 || source_id.match?(/[[:cntrl:]]/)

      @workspace.account_health_inputs.find_by!(
        account:, source_namespace:, source_key: source_id, input_key: key
      )
    rescue ActiveRecord::RecordNotFound
      raise InvalidImport, "Correction source #{source_id} has no #{key} observation for this account."
    end

    def source_digest(key, kind, attributes, metadata)
      value = kind == "date" ? attributes.fetch(:date_value).iso8601 : attributes.fetch(:numeric_value).to_s("F")
      return Digest::SHA256.hexdigest([ key, kind, value ].join("\n")) if metadata.empty?

      canonical = [ key, kind, value, metadata[:observed_at]&.iso8601(6), metadata[:valid_from]&.iso8601(6),
        metadata[:valid_until]&.iso8601(6), metadata[:correction_digest] ]
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end

    def optional_time(raw, label)
      return if raw.blank?

      Time.iso8601(raw.to_s).in_time_zone
    rescue ArgumentError
      raise InvalidImport, "#{label} must be an ISO 8601 timestamp."
    end

    def typed_value(key, kind, raw)
      if kind == "date"
        { date_value: Date.iso8601(raw.to_s), numeric_value: nil }
      else
        value = BigDecimal(raw.to_s)
        raise InvalidImport, "#{key.humanize} cannot be negative." if value.negative?
        { numeric_value: value, date_value: nil }
      end
    rescue Date::Error, ArgumentError
      raise InvalidImport, "#{key.humanize} has an invalid #{kind}."
    end
end
