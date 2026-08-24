class CreateOidcIdentities < ActiveRecord::Migration[8.1]
  def up
    create_table :oidc_identities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :issuer, null: false
      t.string :subject, null: false
      t.timestamps
    end
    add_index :oidc_identities, %i[ issuer subject ], unique: true
    add_check_constraint :oidc_identities,
      "length(issuer) BETWEEN 1 AND 2048 AND length(subject) BETWEEN 1 AND 255",
      name: "oidc_identities_lengths"

    remove_check_constraint :sessions, name: "sessions_authentication_method"
    add_check_constraint :sessions,
      "authentication_method IN ('local', 'oidc', 'break_glass')",
      name: "sessions_authentication_method"
  end

  def down
    remove_check_constraint :sessions, name: "sessions_authentication_method"
    add_check_constraint :sessions,
      "authentication_method IN ('local', 'break_glass')",
      name: "sessions_authentication_method"
    drop_table :oidc_identities
  end
end
