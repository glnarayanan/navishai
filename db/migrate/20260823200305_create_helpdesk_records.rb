class CreateHelpdeskRecords < ActiveRecord::Migration[8.1]
  def change
    add_index :memberships, [ :workspace_id, :id ], unique: true
    create_conversations
    create_messages
    create_cases
    create_case_status_changes
    create_tags
    create_case_notes
  end

  private
    def create_conversations
      create_table :conversations do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :contact_id, null: false
        t.string :subject
        t.datetime :started_at, null: false
        t.datetime :last_message_at
        t.timestamps
      end
      add_index :conversations, [ :workspace_id, :id ], unique: true
      add_index :conversations, [ :workspace_id, :last_message_at ]
      add_foreign_key :conversations, :contacts,
        column: [ :workspace_id, :contact_id ],
        primary_key: [ :workspace_id, :id ]
    end

    def create_messages
      create_table :conversation_messages do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :conversation_id, null: false
        t.string :direction, null: false
        t.string :author_kind, null: false
        t.bigint :author_contact_id
        t.bigint :author_user_id
        t.string :external_author_name
        t.bigint :in_reply_to_id
        t.text :body, null: false
        t.datetime :occurred_at, null: false
        t.timestamps
      end
      add_index :conversation_messages, [ :workspace_id, :conversation_id, :id ], unique: true, name: "index_conversation_messages_for_replies"
      add_index :conversation_messages, [ :conversation_id, :occurred_at, :id ], name: "index_conversation_messages_on_timeline"
      add_foreign_key :conversation_messages, :conversations,
        column: [ :workspace_id, :conversation_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :conversation_messages, :conversation_messages,
        column: [ :workspace_id, :conversation_id, :in_reply_to_id ],
        primary_key: [ :workspace_id, :conversation_id, :id ],
        name: "fk_conversation_messages_reply"
      add_foreign_key :conversation_messages, :contacts,
        column: [ :workspace_id, :author_contact_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :conversation_messages, :users, column: :author_user_id
      add_check_constraint :conversation_messages,
        "direction IN ('inbound', 'outbound')",
        name: "conversation_messages_direction"
      add_check_constraint :conversation_messages,
        "(author_kind = 'contact' AND author_contact_id IS NOT NULL AND author_user_id IS NULL AND external_author_name IS NULL) OR " \
        "(author_kind = 'user' AND author_contact_id IS NULL AND author_user_id IS NOT NULL AND external_author_name IS NULL) OR " \
        "(author_kind = 'external' AND author_contact_id IS NULL AND author_user_id IS NULL AND external_author_name IS NOT NULL)",
        name: "conversation_messages_author"
    end

    def create_cases
      create_table :support_cases do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :conversation_id, null: false
        t.bigint :assigned_membership_id
        t.string :status, null: false, default: "new"
        t.string :priority, null: false, default: "normal"
        t.datetime :status_changed_at, null: false
        t.datetime :resolved_at
        t.datetime :closed_at
        t.timestamps
      end
      add_index :support_cases, [ :workspace_id, :id ], unique: true
      add_index :support_cases, [ :workspace_id, :conversation_id ], unique: true
      add_index :support_cases, [ :workspace_id, :status, :priority ]
      add_index :support_cases, [ :workspace_id, :assigned_membership_id, :status ], name: "index_support_cases_on_assignment_queue"
      add_foreign_key :support_cases, :conversations,
        column: [ :workspace_id, :conversation_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :support_cases, :memberships,
        column: [ :workspace_id, :assigned_membership_id ],
        primary_key: [ :workspace_id, :id ]
      add_check_constraint :support_cases,
        "status IN ('new', 'triaged', 'investigating', 'waiting_customer', 'waiting_internal', 'draft_ready', 'awaiting_human_review', 'resolved', 'closed')",
        name: "support_cases_status"
      add_check_constraint :support_cases,
        "priority IN ('low', 'normal', 'high', 'urgent')",
        name: "support_cases_priority"
      add_check_constraint :support_cases,
        "(status = 'resolved' AND resolved_at IS NOT NULL AND closed_at IS NULL) OR " \
        "(status = 'closed' AND resolved_at IS NOT NULL AND closed_at IS NOT NULL) OR " \
        "(status NOT IN ('resolved', 'closed') AND resolved_at IS NULL AND closed_at IS NULL)",
        name: "support_cases_terminal_timestamps"
    end

    def create_case_status_changes
      create_table :support_case_status_changes do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :support_case_id, null: false
        t.string :from_status
        t.string :to_status, null: false
        t.string :actor_kind, null: false
        t.bigint :actor_id
        t.string :source, null: false
        t.string :reason, null: false
        t.datetime :occurred_at, null: false
        t.datetime :created_at, null: false
      end
      add_index :support_case_status_changes, [ :support_case_id, :occurred_at, :id ], name: "index_support_case_status_changes_on_timeline"
      add_foreign_key :support_case_status_changes, :support_cases,
        column: [ :workspace_id, :support_case_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :support_case_status_changes, :users, column: :actor_id
      add_check_constraint :support_case_status_changes,
        "actor_kind IN ('user', 'system') AND ((actor_kind = 'user' AND actor_id IS NOT NULL) OR (actor_kind = 'system' AND actor_id IS NULL))",
        name: "support_case_status_changes_actor"
      add_check_constraint :support_case_status_changes,
        "source IN ('web', 'job', 'task', 'runner', 'integration', 'system')",
        name: "support_case_status_changes_source"
      add_check_constraint :support_case_status_changes,
        "from_status IS NULL OR from_status IN ('new', 'triaged', 'investigating', 'waiting_customer', 'waiting_internal', 'draft_ready', 'awaiting_human_review', 'resolved', 'closed')",
        name: "support_case_status_changes_from_status"
      add_check_constraint :support_case_status_changes,
        "to_status IN ('new', 'triaged', 'investigating', 'waiting_customer', 'waiting_internal', 'draft_ready', 'awaiting_human_review', 'resolved', 'closed')",
        name: "support_case_status_changes_to_status"
    end

    def create_tags
      create_table :tags do |t|
        t.references :workspace, null: false, foreign_key: true
        t.string :name, null: false
        t.timestamps
      end
      add_index :tags, [ :workspace_id, :id ], unique: true
      add_index :tags, "workspace_id, lower(name)", unique: true, name: "index_tags_on_workspace_and_lower_name"

      create_table :support_case_taggings do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :support_case_id, null: false
        t.bigint :tag_id, null: false
        t.timestamps
      end
      add_index :support_case_taggings, [ :support_case_id, :tag_id ], unique: true
      add_foreign_key :support_case_taggings, :support_cases,
        column: [ :workspace_id, :support_case_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :support_case_taggings, :tags,
        column: [ :workspace_id, :tag_id ],
        primary_key: [ :workspace_id, :id ]
    end

    def create_case_notes
      create_table :case_notes do |t|
        t.references :workspace, null: false, foreign_key: true
        t.bigint :support_case_id, null: false
        t.bigint :author_id, null: false
        t.text :body, null: false
        t.timestamps
      end
      add_index :case_notes, [ :support_case_id, :created_at, :id ]
      add_foreign_key :case_notes, :support_cases,
        column: [ :workspace_id, :support_case_id ],
        primary_key: [ :workspace_id, :id ]
      add_foreign_key :case_notes, :users, column: :author_id
    end
end
