require "test_helper"

class SourceIdentityResolverTest < ActiveSupport::TestCase
  test "zero candidates creates a canonical contact and audits both records" do
    assert_difference [ "Contact.count", "SourceIdentity.count" ], 1 do
      assert_difference "AuditEvent.count", 2 do
        result = resolve_contact("new-contact", "new@example.com", name: "New Contact")

        assert result.matched?
        assert_equal "New Contact", result.record.name
        assert result.source_identity.created?
      end
    end

    assert_equal %w[contact.created source_identity.matched], AuditEvent.order(:id).last(2).map(&:action)
  end

  test "one normalized email candidate matches without creating a contact" do
    assert_no_difference "Contact.count" do
      result = resolve_contact("intercom-alice", " Alice@Example.com ")

      assert result.matched?
      assert_equal contacts(:alice), result.record
      assert result.source_identity.deterministic?
    end
  end

  test "source record replay is idempotent and never rematches changed keys" do
    first = resolve_contact("replayed", "alice@example.com")

    assert_no_difference [ "SourceIdentity.count", "AuditEvent.count" ] do
      replay = resolve_contact("replayed", "other@example.com")
      assert_equal first.source_identity, replay.source_identity
      assert_equal contacts(:alice), replay.record
    end
  end

  test "retired identity keys do not match" do
    source_identities(:alice_email).replace_keys!(email: "alice.new@example.com")

    result = resolve_contact("old-email", "alice@example.com", name: "Reused Email")

    assert result.source_identity.created?
    assert_not_equal contacts(:alice), result.record
  end

  test "matching is isolated by workspace" do
    result = SourceIdentityResolver.resolve!(
      workspace: workspaces(:beta_support),
      entity_kind: :contact,
      source_namespace: "intercom:beta",
      source_record_type: :contact,
      source_record_id: "beta-alice",
      keys: { email: "alice@example.com" },
      attributes: { name: "Beta Alice" }
    )

    assert result.source_identity.created?
    assert_equal workspaces(:beta_support), result.record.workspace
    assert_not_equal contacts(:alice), result.record
  end

  test "multiple canonical roots persist a blocked ambiguity snapshot" do
    create_matched_identity(contacts(:alice_duplicate), "duplicate", "alice@example.com")

    result = resolve_contact("ambiguous", "alice@example.com")

    assert result.ambiguous?
    assert_nil result.record
    assert_equal [ contacts(:alice), contacts(:alice_duplicate) ].to_set,
      result.source_identity.identity_match_candidates.map(&:record).to_set
    assert_equal 1, AuditEvent.where(action: "source_identity.ambiguous").count
  end

  test "conflicting supplied keys are ambiguous rather than ranked" do
    create_matched_identity(contacts(:alice_duplicate), "duplicate", "duplicate@example.com")

    result = SourceIdentityResolver.resolve!(
      workspace: workspaces(:acme_support),
      entity_kind: :contact,
      source_namespace: "intercom:primary",
      source_record_type: :contact,
      source_record_id: "conflicting",
      keys: { email: [ "alice@example.com", "duplicate@example.com" ] }
    )

    assert result.ambiguous?
    assert_equal [ contacts(:alice), contacts(:alice_duplicate) ].to_set,
      result.source_identity.identity_match_candidates.map(&:record).to_set
  end

  test "invalid and unsupported keys fail before persistence" do
    assert_no_difference [ "SourceIdentity.count", "AuditEvent.count" ] do
      assert_raises(ArgumentError) { resolve_contact("invalid", "not an email") }
      assert_raises(ArgumentError) do
        SourceIdentityResolver.resolve!(
          workspace: workspaces(:acme_support),
          entity_kind: :contact,
          source_namespace: "intercom",
          source_record_type: :contact,
          source_record_id: "phone-only",
          keys: { phone: "+15551234567" }
        )
      end
    end
  end

  test "audit failure rolls back source and canonical records" do
    singleton = AuditEvent.singleton_class
    original_record = AuditEvent.method(:record!)
    singleton.define_method(:record!) { |**| raise ActiveRecord::RecordInvalid, AuditEvent.new }

    assert_no_difference [ "SourceIdentity.count", "Contact.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        resolve_contact("audit-failure", "audit-failure@example.com", name: "Rolled back")
      end
    end
  ensure
    singleton&.define_method(:record!, original_record) if original_record
  end

  private
    def resolve_contact(source_record_id, email, attributes = {})
      SourceIdentityResolver.resolve!(
        workspace: workspaces(:acme_support),
        entity_kind: :contact,
        source_namespace: "intercom:primary",
        source_record_type: :contact,
        source_record_id: source_record_id,
        keys: { email: email },
        attributes: attributes
      )
    end

    def create_matched_identity(contact, source_record_id, email)
      identity = SourceIdentity.create!(
        workspace: contact.workspace,
        entity_kind: :contact,
        source_namespace: "manual_import",
        source_record_type: :contact,
        source_record_id: source_record_id,
        status: :matched,
        contact: contact,
        resolution_method: :created,
        resolved_at: Time.current
      )
      identity.source_identity_keys.create!(workspace: contact.workspace, kind: :email, normalized_value: email)
      identity
    end
end
