class AddHumanDraftProvenance < ActiveRecord::Migration[8.1]
  TABLES = %i[
    email_drafts outbound_email_deliveries intercom_drafts intercom_outbound_deliveries
  ].freeze

  def up
    TABLES.each { |table| add_provenance_columns(table) }
    replace_email_delivery_guard(include_provenance: true)
    replace_intercom_delivery_guard(include_provenance: true)
  end

  def down
    replace_email_delivery_guard(include_provenance: false)
    replace_intercom_delivery_guard(include_provenance: false)
    TABLES.reverse_each { |table| remove_provenance_columns(table) }
  end

  private
    def add_provenance_columns(table)
      add_column table, :source_crew_artifact_id, :bigint
      add_column table, :generated_body_digest, :string
      add_column table, :generated_contract_result_state, :string
      add_column table, :human_edited_by_membership_id, :bigint
      add_column table, :human_edited_by_user_id, :bigint
      add_column table, :human_edited_at, :datetime

      add_index table, [ :workspace_id, :source_crew_artifact_id ],
        name: "index_#{table}_on_source_artifact"
      add_foreign_key table, :crew_artifacts,
        column: [ :workspace_id, :source_crew_artifact_id ],
        primary_key: [ :workspace_id, :id ], name: "fk_#{table}_source_artifact"
      add_foreign_key table, :memberships,
        column: [ :workspace_id, :human_edited_by_membership_id, :human_edited_by_user_id ],
        primary_key: [ :workspace_id, :id, :user_id ], name: "fk_#{table}_human_editor"
      add_foreign_key table, :users, column: :human_edited_by_user_id,
        name: "fk_#{table}_human_editor_user"

      add_check_constraint table,
        "generated_body_digest IS NULL OR generated_body_digest ~ '^[0-9a-f]{64}$'",
        name: "#{table}_generated_digest"
      add_check_constraint table,
        "generated_contract_result_state IS NULL OR " \
        "generated_contract_result_state IN ('complete', 'blocked', 'needs_human')",
        name: "#{table}_contract_result"
      add_check_constraint table,
        "(source_crew_artifact_id IS NULL AND generated_body_digest IS NULL AND " \
        "generated_contract_result_state IS NULL AND human_edited_by_membership_id IS NULL AND " \
        "human_edited_by_user_id IS NULL AND human_edited_at IS NULL) OR " \
        "(source_crew_artifact_id IS NOT NULL AND generated_body_digest IS NOT NULL AND " \
        "((human_edited_by_membership_id IS NULL AND human_edited_by_user_id IS NULL AND human_edited_at IS NULL) OR " \
        "(human_edited_by_membership_id IS NOT NULL AND human_edited_by_user_id IS NOT NULL AND human_edited_at IS NOT NULL)))",
        name: "#{table}_provenance_shape"
    end

    def remove_provenance_columns(table)
      remove_check_constraint table, name: "#{table}_provenance_shape"
      remove_check_constraint table, name: "#{table}_contract_result"
      remove_check_constraint table, name: "#{table}_generated_digest"
      remove_foreign_key table, name: "fk_#{table}_human_editor_user"
      remove_foreign_key table, name: "fk_#{table}_human_editor"
      remove_foreign_key table, name: "fk_#{table}_source_artifact"
      remove_index table, name: "index_#{table}_on_source_artifact"
      remove_columns table,
        :source_crew_artifact_id, :generated_body_digest, :generated_contract_result_state,
        :human_edited_by_membership_id, :human_edited_by_user_id, :human_edited_at
    end

    def replace_email_delivery_guard(include_provenance:)
      provenance = if include_provenance
        <<~SQL.squish
          OLD.source_crew_artifact_id, OLD.generated_body_digest, OLD.generated_contract_result_state,
          OLD.human_edited_by_membership_id, OLD.human_edited_by_user_id, OLD.human_edited_at,
        SQL
      else
        ""
      end
      new_provenance = if include_provenance
        <<~SQL.squish
          NEW.source_crew_artifact_id, NEW.generated_body_digest, NEW.generated_contract_result_state,
          NEW.human_edited_by_membership_id, NEW.human_edited_by_user_id, NEW.human_edited_at,
        SQL
      else
        ""
      end
      execute <<~SQL
        CREATE OR REPLACE FUNCTION protect_outbound_email_delivery()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF TG_OP = 'UPDATE' AND
             ROW(OLD.id, OLD.workspace_id, OLD.email_draft_id, OLD.shared_email_inbox_id,
                 OLD.email_thread_id, OLD.conversation_id, OLD.actor_membership_id,
                 OLD.actor_user_id, OLD.idempotency_key, OLD.message_id,
                 OLD.in_reply_to_message_id, OLD.from_address, OLD.to_address,
                 OLD.subject, OLD.body, #{provenance} OLD.started_at, OLD.created_at)
             IS NOT DISTINCT FROM
             ROW(NEW.id, NEW.workspace_id, NEW.email_draft_id, NEW.shared_email_inbox_id,
                 NEW.email_thread_id, NEW.conversation_id, NEW.actor_membership_id,
                 NEW.actor_user_id, NEW.idempotency_key, NEW.message_id,
                 NEW.in_reply_to_message_id, NEW.from_address, NEW.to_address,
                 NEW.subject, NEW.body, #{new_provenance} NEW.started_at, NEW.created_at) AND
             ((OLD.status = 'sending' AND NEW.status IN ('sent', 'failed', 'unknown')) OR
              (OLD.status = 'unknown' AND NEW.status IN ('sent', 'failed'))) THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'outbound email delivery records are durable';
        END;
        $$;
      SQL
    end

    def replace_intercom_delivery_guard(include_provenance:)
      provenance = if include_provenance
        <<~SQL.squish
          OLD.source_crew_artifact_id, OLD.generated_body_digest, OLD.generated_contract_result_state,
          OLD.human_edited_by_membership_id, OLD.human_edited_by_user_id, OLD.human_edited_at,
        SQL
      else
        ""
      end
      new_provenance = if include_provenance
        <<~SQL.squish
          NEW.source_crew_artifact_id, NEW.generated_body_digest, NEW.generated_contract_result_state,
          NEW.human_edited_by_membership_id, NEW.human_edited_by_user_id, NEW.human_edited_at,
        SQL
      else
        ""
      end
      execute <<~SQL
        CREATE OR REPLACE FUNCTION protect_intercom_outbound_delivery()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$
        BEGIN
          IF TG_OP = 'UPDATE' AND
             ROW(OLD.id, OLD.workspace_id, OLD.intercom_draft_id, OLD.intercom_connection_id,
                 OLD.intercom_conversation_link_id, OLD.conversation_id, OLD.actor_membership_id,
                 OLD.actor_user_id, OLD.idempotency_key, OLD.remote_conversation_id,
                 OLD.source_part_id, OLD.admin_id, OLD.body, #{provenance} OLD.started_at, OLD.created_at)
             IS NOT DISTINCT FROM
             ROW(NEW.id, NEW.workspace_id, NEW.intercom_draft_id, NEW.intercom_connection_id,
                 NEW.intercom_conversation_link_id, NEW.conversation_id, NEW.actor_membership_id,
                 NEW.actor_user_id, NEW.idempotency_key, NEW.remote_conversation_id,
                 NEW.source_part_id, NEW.admin_id, NEW.body, #{new_provenance} NEW.started_at, NEW.created_at) AND
             ((OLD.status = 'sending' AND NEW.status IN ('sent', 'failed', 'unknown')) OR
              (OLD.status = 'unknown' AND NEW.status IN ('sent', 'failed'))) THEN
            RETURN NEW;
          END IF;
          RAISE EXCEPTION 'Intercom outbound delivery records are durable';
        END;
        $$;
      SQL
    end
end
