class CrewTaskDependency < ApplicationRecord
  belongs_to :workspace
  belongs_to :crew_task
  belongs_to :depends_on_task, class_name: "CrewTask"

  validates :depends_on_task_id, uniqueness: { scope: :crew_task_id }

  def readonly?
    persisted?
  end
end
