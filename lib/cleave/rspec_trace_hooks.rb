# frozen_string_literal: true

require "rspec/core"
require_relative "artifacts"

# Invoked by RSpec's --require before loading spec files.
RSpec.configure do |config|
  config.around(:example) do |example|
    trace = Cleave::RSpecTraceBoot::TRACE
    path = begin
      root = Cleave::RSpecTraceBoot::ROOT
      absolute = File.expand_path(example.metadata.fetch(:file_path), root)
      prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
      raise Cleave::ArtifactError, "example outside root" unless absolute.start_with?(prefix)
      Cleave::ArtifactValidation.path(absolute.delete_prefix(prefix))
    rescue StandardError
      trace.limitation("An example could not be attributed to a valid project-relative spec path and was recorded in root scope.")
      nil
    end
    if path && path != Cleave::ScopedTrace::ROOT_SCOPE
      trace.with_spec(path) { example.run }
    else
      example.run
    end
  end
end
Cleave::RSpecTraceBoot.hook_installed = true
