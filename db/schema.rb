# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_23_200302) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vector"

  create_table "installation_states", force: :cascade do |t|
    t.datetime "bootstrapped_at", null: false
    t.datetime "created_at", null: false
    t.boolean "singleton", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton"], name: "index_installation_states_on_singleton", unique: true
    t.check_constraint "singleton", name: "installation_states_singleton"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["user_id"], name: "index_memberships_on_user_id"
    t.index ["workspace_id", "role"], name: "index_memberships_on_workspace_id_and_role"
    t.index ["workspace_id", "user_id"], name: "index_memberships_on_workspace_id_and_user_id", unique: true
    t.index ["workspace_id"], name: "index_memberships_on_workspace_id"
    t.check_constraint "role::text = ANY (ARRAY['owner'::character varying, 'admin'::character varying, 'manager'::character varying, 'member'::character varying, 'viewer'::character varying]::text[])", name: "memberships_role"
  end

  create_table "organizations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.string "authentication_method", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "ip_address"
    t.datetime "revoked_at"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["user_id"], name: "index_sessions_on_user_id"
    t.check_constraint "authentication_method::text = ANY (ARRAY['local'::character varying, 'break_glass'::character varying]::text[])", name: "sessions_authentication_method"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "break_glass", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at"
    t.index "lower((email_address)::text)", name: "index_users_on_lower_email_address", unique: true
    t.index ["break_glass"], name: "index_users_on_unique_break_glass", unique: true, where: "break_glass"
  end

  create_table "workspace_invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.bigint "accepted_by_id"
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.datetime "expires_at", null: false
    t.bigint "invited_by_id", null: false
    t.string "role", null: false
    t.string "status", null: false
    t.string "token_nonce", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index "workspace_id, lower((email_address)::text)", name: "index_pending_workspace_invitations_on_email", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["accepted_by_id"], name: "index_workspace_invitations_on_accepted_by_id"
    t.index ["invited_by_id"], name: "index_workspace_invitations_on_invited_by_id"
    t.index ["workspace_id"], name: "index_workspace_invitations_on_workspace_id"
    t.check_constraint "role::text = ANY (ARRAY['owner'::character varying, 'admin'::character varying, 'manager'::character varying, 'member'::character varying, 'viewer'::character varying]::text[])", name: "workspace_invitations_role"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'accepted'::character varying, 'revoked'::character varying, 'expired'::character varying]::text[])", name: "workspace_invitations_status"
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id", "slug"], name: "index_workspaces_on_organization_id_and_slug", unique: true
    t.index ["organization_id"], name: "index_workspaces_on_organization_id"
  end

  add_foreign_key "memberships", "users"
  add_foreign_key "memberships", "workspaces"
  add_foreign_key "sessions", "users"
  add_foreign_key "workspace_invitations", "users", column: "accepted_by_id"
  add_foreign_key "workspace_invitations", "users", column: "invited_by_id"
  add_foreign_key "workspace_invitations", "workspaces"
  add_foreign_key "workspaces", "organizations"
end
