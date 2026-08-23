class SourceIdentityResolver
  Result = Data.define(:status, :source_identity, :record) do
    def matched? = status == :matched
    def ambiguous? = status == :ambiguous
  end

  def self.resolve!(workspace:, entity_kind:, source_namespace:, source_record_type:, source_record_id:, keys:, attributes: {})
    new(workspace:, entity_kind:, source_namespace:, source_record_type:, source_record_id:, keys:, attributes:).resolve!
  end

  def initialize(workspace:, entity_kind:, source_namespace:, source_record_type:, source_record_id:, keys:, attributes:)
    @workspace = workspace
    @entity_kind = entity_kind.to_s
    @source_namespace = source_namespace.to_s.strip.downcase
    @source_record_type = source_record_type.to_s.strip.downcase
    @source_record_id = source_record_id.to_s.strip
    @keys = normalize_keys(keys)
    @attributes = attributes
    raise ArgumentError, "unsupported entity kind" unless SourceIdentity::ENTITY_KINDS.include?(@entity_kind)
    raise ArgumentError, "identity requires a deterministic key" if @keys.empty?
  end

  def resolve!
    SourceIdentity.transaction do
      CustomerIdentityGraph.lock!(@workspace)
      if identity = existing_identity
        raise ArgumentError, "source identity entity kind does not match" unless identity.entity_kind == @entity_kind

        return result_for(identity)
      end

      identity = create_pending_identity!
      candidates = candidate_records
      case candidates.length
      when 0
        record = create_record!
        match!(identity, record, :created)
        audit_record_created!(record)
        audit_identity!(identity, "source_identity.matched", resolution_method: "created")
      when 1
        record = candidates.keys.sole
        match!(identity, record, :deterministic)
        audit_identity!(identity, "source_identity.matched", resolution_method: "deterministic")
      else
        record = nil
        persist_candidates!(identity, candidates)
        identity.update!(status: :ambiguous)
        audit_identity!(identity, "source_identity.ambiguous", candidate_count: candidates.length)
      end
      result_for(identity.reload, record)
    end
  end

  private
    def existing_identity
      @workspace.source_identities.find_by(
        source_namespace: @source_namespace,
        source_record_type: @source_record_type,
        source_record_id: @source_record_id
      )
    end

    def create_pending_identity!
      identity = @workspace.source_identities.create!(
        entity_kind: @entity_kind,
        source_namespace: @source_namespace,
        source_record_type: @source_record_type,
        source_record_id: @source_record_id
      )
      @keys.each do |kind, value|
        identity.source_identity_keys.create!(workspace: @workspace, kind: kind, normalized_value: value)
      end
      identity
    end

    def candidate_records
      candidates = Hash.new { |hash, record| hash[record] = Set.new }
      @keys.each do |kind, value|
        SourceIdentityKey.current
          .where(workspace: @workspace, kind: kind, normalized_value: value)
          .includes(source_identity: [ :account, :contact ])
          .find_each do |key|
            identity = key.source_identity
            next unless identity.matched? && identity.entity_kind == @entity_kind && !identity.retired_at?

            candidates[identity.canonical_record] << kind
          end
      end
      candidates
    end

    def create_record!
      relation = @entity_kind == "account" ? @workspace.accounts : @workspace.contacts
      relation.create!(@attributes)
    end

    def match!(identity, record, method)
      target = @entity_kind == "account" ? { account: record } : { contact: record }
      identity.update!(target.merge(status: :matched, resolution_method: method, resolved_at: Time.current))
    end

    def persist_candidates!(identity, candidates)
      candidates.each do |record, key_kinds|
        key_kinds.each do |key_kind|
          target = record.is_a?(Account) ? { account: record } : { contact: record }
          identity.identity_match_candidates.create!(target.merge(workspace: @workspace, key_kind: key_kind))
        end
      end
    end

    def audit_record_created!(record)
      AuditEvent.record!(
        action: "#{@entity_kind}.created",
        source: :integration,
        workspace: @workspace,
        actor_kind: :system,
        subject: record
      )
    end

    def audit_identity!(identity, action, metadata)
      AuditEvent.record!(
        action: action,
        source: :integration,
        workspace: @workspace,
        actor_kind: :system,
        subject: identity,
        metadata: metadata.merge(entity_kind: @entity_kind)
      )
    end

    def result_for(identity, record = identity.canonical_record)
      Result.new(status: identity.status.to_sym, source_identity: identity, record: record)
    end

    def normalize_keys(keys)
      keys.to_h.flat_map do |kind, values|
        Array(values).map { |value| [ kind.to_s, IdentityKeyNormalizer.normalize(kind, value) ] }
      end.uniq
    end
end
