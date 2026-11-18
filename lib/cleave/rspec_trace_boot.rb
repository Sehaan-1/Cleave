# frozen_string_literal: true

# Loaded in the RSpec subprocess before RSpec/spec files, not in the runner.
require "json"
require_relative "scoped_trace"

module Cleave
  module RSpecTraceBoot
    ROOT = File.realpath(ENV.fetch("CLEAVE_TRACE_ROOT"))
    DESTINATION = ENV.fetch("CLEAVE_TRACE_OUTPUT")
    OWNER = Process.pid
    TRACE = ScopedTrace.start(root: ROOT)
    TRACE.limitation("RSpec scopes example execution on the same fiber; file loading, suite/context hooks and hooks outside Cleave’s around hook are root scope.")
    TRACE.limitation("Cleave state and project .git paths are omitted from this report.")
    @hook_installed = false

    class << self
      attr_accessor :hook_installed
    end

    at_exit do
      # Forked children inherit at_exit hooks but must not replace the parent report.
      if Process.pid == OWNER
        begin
          report = TRACE.stop.to_h
          report["events"].reject! do |event|
            path = event["path"]
            path == ".cleave" || path.start_with?(".cleave/") || (!Pathname.new(path).absolute? && path.split("/").include?(".git"))
          end
          File.write(DESTINATION, JSON.generate("hook_installed" => @hook_installed, "report" => report))
        rescue StandardError => error
          warn "Cleave trace collection failed: #{error.class}: #{error.message}"
        end
      end
    end
  end
end
