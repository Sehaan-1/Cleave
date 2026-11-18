# frozen_string_literal: true

# Loaded in the RSpec subprocess before RSpec/spec files, not in the runner.
require "json"
require "securerandom"
require_relative "scoped_trace"

module Cleave
  module RSpecTraceBoot
    ROOT = File.realpath(ENV.fetch("CLEAVE_TRACE_ROOT"))
    DESTINATION = ENV.fetch("CLEAVE_TRACE_OUTPUT")
    OWNER = Process.pid
    FORK_DIRECTORY = ENV["CLEAVE_TRACE_FORK_DIRECTORY"]
    FORK_NOTE = "Fork observations are best effort: exit!, exec, daemon, abnormal or late child exits and unsupported subprocesses can be missed."
    SCOPE_NOTE = "Fork children inherit the spawning fiber scope; child work may outlive that example and unscoped threads or fibers remain root scope."
    TRACE = ScopedTrace.start(root: ROOT)
    TRACE.limitation("RSpec scopes example execution on the same fiber; file loading, suite/context hooks and hooks outside Cleave’s around hook are root scope.")
    TRACE.limitation("Cleave state and project .git paths are omitted from this report.")
    @hook_installed = false

    class << self
      attr_accessor :hook_installed

      def after_fork
        @child_pid = nil
        return unless ScopedTrace.reset_after_fork(TRACE)
        TRACE.limitation(FORK_NOTE)
        TRACE.limitation(SCOPE_NOTE)
        @child_pid = Process.pid
      rescue StandardError => error
        @child_pid = nil
        warn "Cleave fork trace initialization failed: #{error.class}: #{error.message}"
      end

      def child_initialized?
        @child_pid == Process.pid
      end

      def clean(report)
        report["events"].reject! do |event|
          path = event["path"]
          path == ".cleave" || path.start_with?(".cleave/") || (!Pathname.new(path).absolute? && path.split("/").include?(".git"))
        end
        report
      end
    end

    module ForkHook
      def _fork
        pid = super
        Cleave::RSpecTraceBoot.after_fork if pid == 0
        pid
      end
    end

    if FORK_DIRECTORY
      raise "fork tracing requires Process._fork" unless Process.respond_to?(:_fork, true)
      Process.singleton_class.prepend(ForkHook)
      TRACE.limitation(FORK_NOTE)
      TRACE.limitation(SCOPE_NOTE)
    end

    at_exit do
      begin
        if Process.pid == OWNER
          report = clean(TRACE.stop.to_h)
          File.write(DESTINATION, JSON.generate("hook_installed" => @hook_installed, "report" => report))
        elsif FORK_DIRECTORY && child_initialized?
          report = clean(TRACE.report.to_h)
          # Children publish distinct files only after a complete JSON write;
          # late or abnormal children can be missed and are never assumed complete.
          name = "#{Process.pid}-#{SecureRandom.hex(8)}"
          temporary = File.join(FORK_DIRECTORY, ".#{name}.tmp")
          final = File.join(FORK_DIRECTORY, "#{name}.json")
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate("report" => report)) }
          File.rename(temporary, final)
        end
      rescue StandardError => error
        warn "Cleave trace collection failed: #{error.class}: #{error.message}"
      end
    end
  end
end
