class AddHealthScorecardProposalRevisions < ActiveRecord::Migration[8.1]
  def up
    add_column :health_scorecard_proposals, :parent_proposal_id, :bigint
    add_index :health_scorecard_proposals, :parent_proposal_id
    add_foreign_key :health_scorecard_proposals, :health_scorecard_proposals,
      column: [ :workspace_id, :parent_proposal_id ], primary_key: [ :workspace_id, :id ],
      name: "fk_health_scorecard_proposals_parent"
    add_check_constraint :health_scorecard_proposals,
      "parent_proposal_id IS NULL OR parent_proposal_id <> id",
      name: "health_scorecard_proposals_parent"
  end

  def down
    remove_check_constraint :health_scorecard_proposals, name: "health_scorecard_proposals_parent"
    remove_foreign_key :health_scorecard_proposals, name: "fk_health_scorecard_proposals_parent"
    remove_index :health_scorecard_proposals, :parent_proposal_id
    remove_column :health_scorecard_proposals, :parent_proposal_id
  end
end
