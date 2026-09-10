class CreatePersonalProviderAccounts < ActiveRecord::Migration[8.1]
  def up
    create_table :personal_provider_accounts do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :membership_id, null: false
      t.uuid :account_key, null: false
      t.string :state, null: false, default: "starting"
      t.datetime :expires_at
      t.timestamps
    end
    add_index :personal_provider_accounts, :account_key, unique: true
    add_index :personal_provider_accounts, [ :workspace_id, :id ], unique: true
    add_index :personal_provider_accounts, [ :workspace_id, :account_key, :membership_id ], unique: true, name: "personal_accounts_identity"
    add_foreign_key :personal_provider_accounts, :memberships, column: [ :workspace_id, :membership_id ], primary_key: [ :workspace_id, :id ]
    add_check_constraint :personal_provider_accounts, "state IN ('starting','pending','connected','failed','disconnected')", name: "personal_accounts_state"
    add_reference :runtime_installations, :personal_provider_account, index: { unique: true }
    add_foreign_key :runtime_installations, :personal_provider_accounts, column: [ :workspace_id, :personal_provider_account_id ], primary_key: [ :workspace_id, :id ]
    add_column :execution_runs, :requested_by_membership_id, :bigint
    add_column :execution_runs, :selected_personal_account_key, :uuid
    add_foreign_key :execution_runs, :memberships, column: [ :workspace_id, :requested_by_membership_id ], primary_key: [ :workspace_id, :id ]
    add_foreign_key :execution_runs, :personal_provider_accounts,
      column: [ :workspace_id, :selected_personal_account_key, :requested_by_membership_id ],
      primary_key: [ :workspace_id, :account_key, :membership_id ], name: "execution_runs_personal_identity"
    add_check_constraint :execution_runs, "selected_personal_account_key IS NULL OR requested_by_membership_id IS NOT NULL", name: "execution_runs_personal_requester"
    execute <<~SQL
      CREATE FUNCTION protect_personal_provider_identity() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF (OLD.workspace_id, OLD.membership_id, OLD.account_key) IS DISTINCT FROM (NEW.workspace_id, NEW.membership_id, NEW.account_key) THEN
          RAISE EXCEPTION 'personal provider account identity is immutable';
        END IF;
        RETURN NEW;
      END; $$;
      CREATE TRIGGER personal_provider_identity BEFORE UPDATE ON personal_provider_accounts FOR EACH ROW EXECUTE FUNCTION protect_personal_provider_identity();
      CREATE FUNCTION protect_execution_personal_account() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE account personal_provider_accounts;
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF (OLD.requested_by_membership_id, OLD.selected_personal_account_key) IS DISTINCT FROM (NEW.requested_by_membership_id, NEW.selected_personal_account_key) THEN
            RAISE EXCEPTION 'execution requester and personal account are immutable';
          END IF;
        ELSE
          SELECT a.* INTO account FROM runtime_installations r JOIN personal_provider_accounts a ON a.id = r.personal_provider_account_id WHERE r.id = NEW.runtime_installation_id;
          IF account.id IS NOT NULL THEN
            IF NEW.selected_personal_account_key IS DISTINCT FROM account.account_key OR NEW.requested_by_membership_id IS DISTINCT FROM account.membership_id OR NEW.workspace_id <> account.workspace_id THEN
              RAISE EXCEPTION 'execution personal account does not match requester and runtime';
            END IF;
          ELSIF NEW.selected_personal_account_key IS NOT NULL THEN
            RAISE EXCEPTION 'shared execution cannot claim a personal account';
          END IF;
        END IF;
        RETURN NEW;
      END; $$;
      CREATE TRIGGER execution_personal_account BEFORE INSERT OR UPDATE ON execution_runs FOR EACH ROW EXECUTE FUNCTION protect_execution_personal_account();
    SQL
  end

  def down
    execute "DROP TRIGGER execution_personal_account ON execution_runs; DROP FUNCTION protect_execution_personal_account(); DROP TRIGGER personal_provider_identity ON personal_provider_accounts; DROP FUNCTION protect_personal_provider_identity();"
    remove_foreign_key :execution_runs, name: "execution_runs_personal_identity"
    remove_check_constraint :execution_runs, name: "execution_runs_personal_requester"
    remove_foreign_key :execution_runs, column: [ :workspace_id, :requested_by_membership_id ]
    remove_column :execution_runs, :selected_personal_account_key
    remove_column :execution_runs, :requested_by_membership_id
    remove_foreign_key :runtime_installations, column: [ :workspace_id, :personal_provider_account_id ]
    remove_reference :runtime_installations, :personal_provider_account
    drop_table :personal_provider_accounts
  end
end
