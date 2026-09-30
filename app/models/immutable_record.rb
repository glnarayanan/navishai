class ImmutableRecord < ApplicationRecord
  self.abstract_class = true

  def readonly?
    persisted?
  end
end
