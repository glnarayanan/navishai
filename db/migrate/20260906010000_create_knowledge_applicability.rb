class CreateKnowledgeApplicability < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false, limit: 100
      t.timestamps
    end
    add_index :products, [ :workspace_id, :id ], unique: true
    add_index :products, "workspace_id, lower(name)", unique: true, name: "index_products_on_workspace_name"
    add_check_constraint :products, "length(trim(name)) > 0", name: "products_name_present"

    create_table :knowledge_applicabilities do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :knowledge_source_id
      t.bigint :intercom_connection_id
      t.boolean :all_products, null: false, default: true
      t.boolean :all_connections, null: false, default: true
      t.timestamps
    end
    add_index :knowledge_applicabilities, [ :workspace_id, :id ], unique: true
    add_index :knowledge_applicabilities, :knowledge_source_id, unique: true
    add_index :knowledge_applicabilities, :intercom_connection_id, unique: true
    add_check_constraint :knowledge_applicabilities,
      "(knowledge_source_id IS NULL) <> (intercom_connection_id IS NULL)", name: "knowledge_applicabilities_owner"
    workspace_reference :knowledge_applicabilities, :knowledge_sources, :knowledge_source_id
    workspace_reference :knowledge_applicabilities, :intercom_connections, :intercom_connection_id

    create_table :knowledge_applicability_products do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :knowledge_applicability_id, null: false
      t.bigint :product_id, null: false
    end
    add_index :knowledge_applicability_products, [ :knowledge_applicability_id, :product_id ],
      unique: true, name: "index_knowledge_applicability_products_unique"
    workspace_reference :knowledge_applicability_products, :knowledge_applicabilities, :knowledge_applicability_id
    workspace_reference :knowledge_applicability_products, :products, :product_id

    create_table :knowledge_applicability_connections do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :knowledge_applicability_id, null: false
      t.bigint :intercom_connection_id, null: false
    end
    add_index :knowledge_applicability_connections, [ :knowledge_applicability_id, :intercom_connection_id ],
      unique: true, name: "index_knowledge_applicability_connections_unique"
    workspace_reference :knowledge_applicability_connections, :knowledge_applicabilities, :knowledge_applicability_id
    workspace_reference :knowledge_applicability_connections, :intercom_connections, :intercom_connection_id

    create_table :support_case_products do |t|
      t.references :workspace, null: false, foreign_key: true
      t.bigint :support_case_id, null: false
      t.bigint :product_id, null: false
    end
    add_index :support_case_products, [ :support_case_id, :product_id ], unique: true
    workspace_reference :support_case_products, :support_cases, :support_case_id
    workspace_reference :support_case_products, :products, :product_id
  end

  private
    def workspace_reference(from, to, column)
      add_foreign_key from, to, column: [ :workspace_id, column ], primary_key: [ :workspace_id, :id ]
    end
end
