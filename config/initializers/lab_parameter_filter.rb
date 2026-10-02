# Company content must not appear in request parameter logs.
Rails.application.config.filter_parameters += [ :file, :content, :context, :situation,
  :expected_behaviour, :rubric, :output, :evidence, :hidden_facts, :knowledge, :confirmation,
  :scenario, :note, :after, :variable, :reason, :expected_difference, :excerpt,
  :grader, :definition, :contract, :value, :known_facts, :rationale, :configuration ]
