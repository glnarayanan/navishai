# Filter configured private fields in request parameters and SQL debug bind logs.
Rails.application.config.filter_parameters += [ :file, :content, :context, :situation,
  :expected_behaviour, :rubric, :output, :evidence, :hidden_facts, :knowledge, :confirmation,
  :scenario, :note, :after, :variable, :reason, :expected_difference, :excerpt, :taxonomy_label,
  :grader, :definition, :contract, :value, :known_facts, :rationale, :configuration, :corpus_query ]

ActiveSupport.on_load(:active_record) do
  self.filter_attributes = Rails.application.config.filter_parameters
end
