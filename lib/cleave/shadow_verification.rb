# frozen_string_literal: true

require "open3"
require_relative "guardrails"

module Cleave
  # Diagnostic comparison only: never authorizes selective execution.
  module ShadowVerification
    module_function

    def prepare(root:, files:)
      baseline, index = Artifacts.read(File.join(root, ".cleave"))
      if baseline.files.keys.any? { |path| path == ".cleave" || path.start_with?(".cleave/") }
        raise ArtifactError, "baseline inventory must not include .cleave state"
      end
      current = capture(root, baseline.files.keys + files)
      plan = Guardrails.plan(root: root, baseline: baseline, current: current, index: index,
                             current_specs: files, previous_failures: nil)
      [current, plan]
    end

    # Capture tracked and non-ignored files, plus baseline and discovered paths.
    # Internal state must not invalidate the snapshot as the runner writes it.
    def capture(root, extra)
      stdout, stderr, status = Open3.capture3("git", "-C", root, "ls-files", "--cached", "--others",
                                               "--exclude-standard", "-z", "--", ".",
                                               ":(exclude).cleave", ":(exclude).cleave/**")
      raise ArtifactError, "git ls-files failed: #{stderr.strip}" unless status.success?
      paths = stdout.split("\0").map { |entry| ArtifactValidation.path(entry.dup.force_encoding(Encoding::UTF_8)) }
      Inventory.capture(root: root, paths: paths + extra)
    rescue Errno::ENOENT => error
      raise ArtifactError, "cannot invoke git: #{error.message}"
    end

    def finish(root:, files:, current:, plan:, state:, observed_specs:)
      errors = []
      errors << "RSpec reports were incomplete." unless state["reports_complete"]
      errors << "RSpec reported examples outside the discovered files." unless (observed_specs - files).empty?
      begin
        after = capture(root, current.files.keys + files)
        errors << "Project files changed during verification." unless current.fingerprint == after.fingerprint
      rescue StandardError => error
        errors << "Unable to recheck project files: #{error.class}: #{error.message}"
      end
      candidates = plan.guardrailed_candidate_specs
      misses = state["observed_failed_specs"] - candidates
      { "status" => errors.empty? ? (misses.empty? ? "no_observed_misses" : "observed_misses") : "incomplete",
        "candidate_specs" => candidates, "discovered_specs" => files,
        "observed_missed_failure_specs" => misses.sort, "errors" => errors,
        "inventory_fingerprint" => current.fingerprint, "fallback_reasons" => plan.fallback_reasons,
        "previous_failures_available" => false, "suite_coverage_verified" => false }
    end
  end
end
