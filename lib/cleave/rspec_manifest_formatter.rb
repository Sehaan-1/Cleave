# frozen_string_literal: true

require "json"
require "rspec/core/formatters"

module Cleave
  # Used only by the subprocess running RSpec's own dry-run discovery.
  class RSpecManifestFormatter
    RSpec::Core::Formatters.register self, :start

    def initialize(output)
      @output = output
    end

    def start(_notification)
      @output.write(JSON.generate("files" => RSpec.configuration.files_to_run))
      @output.flush
    end
  end
end
