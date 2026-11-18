# frozen_string_literal: true

module Cleave
  # Measurements describe only reports collected by this runner, not suite coverage.
  module Telemetry
    module_function

    def initial
      { "version" => 1, "runner_elapsed_ns" => nil, "worker_collection_elapsed_ns" => nil,
        "discovered_spec_files" => nil, "reported_spec_files" => 0,
        "passed_examples" => 0, "failed_examples" => 0, "pending_examples" => 0 }
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end

    def duration(ns)
      return "unavailable" if ns.nil?
      return "below clock resolution" if ns.zero?
      return "<0.001 ms" if ns < 500
      format("%.3f ms", ns / 1_000_000.0)
    end

    def render(state)
      metrics = state.fetch("telemetry")
      completeness = state.fetch("reports_complete") ? "complete reports" : "partial reports"
      lines = ["Telemetry (#{completeness}; suite coverage unverified)",
               "  Runner elapsed: #{duration(metrics.fetch('runner_elapsed_ns'))}",
               "  Worker collection elapsed: #{duration(metrics.fetch('worker_collection_elapsed_ns'))}",
               "  Reported examples: #{state.fetch('example_count')} " \
               "(#{metrics.fetch('passed_examples')} passed, #{metrics.fetch('failed_examples')} failed, #{metrics.fetch('pending_examples')} pending)",
               "  Spec files with reported examples: #{metrics.fetch('reported_spec_files')}",
               "  Discovered spec files: #{metrics.fetch('discovered_spec_files') || 'unavailable'}",
               "  Execution policy: configured suite only; no selective skipping"]
      if (verification = state["verification"])
        if verification.key?("candidate_specs")
          lines << "  Diagnostic candidate: #{verification.fetch('candidate_specs').length} of #{verification.fetch('discovered_specs').length} discovered files (not executed selectively)"
          lines << "  Bitmap OR only: #{duration(verification.fetch('union_nanoseconds'))}"
          lines << "  Observed missed failing files: #{verification.fetch('observed_missed_failure_specs').length} (#{verification.fetch('status')})"
        else
          lines << "  Diagnostic candidate: unavailable (#{verification.fetch('status')})"
        end
      end
      lines.join("\n")
    end
  end
end
