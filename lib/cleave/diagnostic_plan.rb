# frozen_string_literal: true

require "tmpdir"
require_relative "rspec_runner"

module Cleave
  # A current, read-only planning snapshot. Never an execution authorization.
  module DiagnosticPlan
    module_function
    SCHEMA = "cleave.diagnostic_plan"
    VERSION = 1
    MAX_ARTIFACT_BYTES = 10 * 1024 * 1024
    LIMITATIONS = [
      "RSpec dry-run discovery loads spec files and may have side effects; it does not verify suite coverage.",
      "Git-based snapshots are not transactional and cannot detect reverted changes or unlisted ignored files.",
      "Baseline artifacts can be stale or from another run; matching fingerprints do not establish provenance."
    ].freeze

    def build(root:, includes: [], output: $stderr, expected_artifacts: nil, previous_failures: false, static_dependencies: false)
      raise ArgumentError, "previous_failures must be true or false" unless [true, false].include?(previous_failures)
      raise ArgumentError, "static_dependencies must be true or false" unless [true, false].include?(static_dependencies)
      root = File.realpath(root)
      raise ArgumentError, "not a directory: #{root}" unless File.directory?(root)
      raise RunnerError, "project Gemfile not found in #{root}" unless File.file?(File.join(root, "Gemfile"))
      raise ArtifactError, "includes must be an array" unless includes.is_a?(Array)
      includes = includes.map { |path| ArtifactValidation.path(path) }.uniq.sort
      raise ArtifactError, "cannot include Cleave state" if includes.any? { |path| internal?(path) }
      stdout, stderr, status = Open3.capture3("git", "-C", root, "rev-parse", "--show-toplevel")
      raise ArtifactError, "git root unavailable: #{stderr.strip}" unless status.success?
      raise ArtifactError, "planning requires the Git project root" unless File.identical?(stdout.strip, root)
      state = File.join(root, ".cleave")
      raise ArtifactError, ".cleave must be a real directory, not a symlink" if File.symlink?(state) || !File.directory?(state)
      lock_path = File.join(state, "runner.lock")
      raise ArtifactError, "runner lock must not be a symlink" if File.symlink?(lock_path)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise RunnerError, "another Cleave run or plan is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        failures, failures_digest = previous_failures ? read_previous_failures(state) : [nil, nil]
        inventory_text = read_artifact(File.join(state, "inventory.json"))
        index_text = read_artifact(File.join(state, "bitmap_index.json"))
        if expected_artifacts && expected_artifacts != [Digest::SHA256.hexdigest(inventory_text), Digest::SHA256.hexdigest(index_text)]
          raise ArtifactError, "artifact pair changed before planning; restart the workbench"
        end
        inventory = Inventory.load(inventory_text)
        index = BitmapIndex.load(index_text, inventory: inventory)
        provenance = IndexProvenance.check(state, inventory_text: inventory_text, index_text: index_text, inventory: inventory)
        raise ArtifactError, "baseline inventory must not include .cleave state" if inventory.files.keys.any? { |path| internal?(path) }
        extras = inventory.files.keys + includes
        before = ShadowVerification.capture(root, extras)
        missing = includes - before.files.keys
        raise ArtifactError, "included files are missing: #{missing.join(', ')}" unless missing.empty?
        Dir.mktmpdir("plan-", state) do |temp|
          files = RSpecRunner.discover_files(root: root, temp: temp, output: output)
          raise ArtifactError, "RSpec discovery reported no spec files" if files.empty?
          current = ShadowVerification.capture(root, extras + files)
          raise ArtifactError, "project changed during discovery, or a discovered ignored spec was not included" unless before.fingerprint == current.fingerprint
          plan = Guardrails.plan(root: root, baseline: inventory, current: current, index: index,
                                 current_specs: files, previous_failures: failures, static_dependencies: static_dependencies)
          after = ShadowVerification.capture(root, extras + files)
          raise ArtifactError, "project changed during planning" unless current.fingerprint == after.fingerprint
          serialize(inventory, current, plan, provenance: provenance, failures_digest: failures_digest)
        end
      ensure
        lock.flock(File::LOCK_UN) if lock
      end
    end

    def internal?(path)
      path == ".cleave" || path.start_with?(".cleave/")
    end
    private_class_method :internal?

    def read_artifact(path)
      raise ArtifactError, "artifact must not be a symlink: #{File.basename(path)}" if File.symlink?(path)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      # Windows File::NONBLOCK is 1, the write-only flag, so only OR it on POSIX.
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK) && !Gem.win_platform?
      File.open(path, flags) do |file|
        raise ArtifactError, "artifact must be a regular file: #{File.basename(path)}" unless file.stat.file?
        bytes = file.read(MAX_ARTIFACT_BYTES + 1) || +""
        raise ArtifactError, "artifact exceeds 10 MiB: #{File.basename(path)}" if bytes.bytesize > MAX_ARTIFACT_BYTES
        bytes.force_encoding(Encoding::UTF_8)
        raise ArtifactError, "artifact is not UTF-8: #{File.basename(path)}" unless bytes.valid_encoding?
        bytes
      end
    rescue Errno::ENOENT
      raise ArtifactError, "artifact pair is incomplete: missing #{File.basename(path)}"
    end
    private_class_method :read_artifact

    # This is a local, unsigned observation, not evidence of suite coverage or
    # a complete failure history. Refuse partial and inconsistent run records.
    def read_previous_failures(state)
      text = read_artifact(File.join(state, "last_run.json"))
      data = ArtifactValidation.parse(text)
      base = %w[schema version outcome requested_workers actual_workers exit_code observed_failed_specs reports_complete suite_coverage_verified example_count errors telemetry]
      optional = %w[verification trace index]
      unless data.is_a?(Hash) && (base - data.keys).empty? && (data.keys - base - optional).empty? &&
             data["schema"] == RSpecRunner::STATUS_SCHEMA && data["version"] == RSpecRunner::STATUS_VERSION &&
             %w[passed failed].include?(data["outcome"]) && data["reports_complete"] == true &&
             data["suite_coverage_verified"] == false && data["errors"] == [] &&
             data["requested_workers"].is_a?(Integer) && data["requested_workers"].between?(1, RSpecRunner::MAX_WORKERS) &&
             data["actual_workers"].is_a?(Integer) && data["actual_workers"].between?(1, data["requested_workers"]) &&
             data["example_count"].is_a?(Integer) && data["example_count"] > 0
        raise ArtifactError, "previous run is invalid or incomplete"
      end
      failures = data["observed_failed_specs"]
      ArtifactValidation.paths!(failures, "previous failures")
      unless failures.all? { |path| path.end_with?(".rb") && !internal?(path) } &&
             failures.length <= data["example_count"] &&
             ((data["outcome"] == "passed" && data["exit_code"] == 0 && failures.empty?) ||
              (data["outcome"] == "failed" && data["exit_code"] == 1 && !failures.empty?))
        raise ArtifactError, "previous run failure observations are inconsistent"
      end
      telemetry = data["telemetry"]
      unless telemetry.is_a?(Hash) && telemetry["version"] == 1 &&
             %w[passed_examples failed_examples pending_examples].all? { |key| telemetry[key].is_a?(Integer) && telemetry[key] >= 0 } &&
             %w[passed_examples failed_examples pending_examples].sum { |key| telemetry[key] } == data["example_count"] &&
             ((telemetry["failed_examples"] == 0) == failures.empty?) && telemetry["failed_examples"] >= failures.length
        raise ArtifactError, "previous run counts are inconsistent"
      end
      [failures, Digest::SHA256.hexdigest(text)]
    end
    private_class_method :read_previous_failures

    def serialize(baseline, current, plan, provenance:, failures_digest:)
      selection = plan.selection
      candidates = plan.guardrailed_candidate_specs
      candidate_set = candidates.to_set
      provenance_note = if provenance["status"] == "recorded"
        "Artifact bytes match a local publication marker; this is not authentication or proof of coverage."
      else
        "Artifact publication provenance is unavailable; this may be a legacy or manually created pair."
      end
      failure_note = if plan.previous_failures_available?
        "Previous failures are unsigned observations from one local run; freshness and suite coverage are unverified."
      else
        "Previous failures were not supplied; the candidate is diagnostic and cannot authorize test skipping."
      end
      result = { "schema" => SCHEMA, "version" => plan.static_enabled ? 3 : (failures_digest ? 2 : VERSION),
        "diagnostic_only" => true, "suite_coverage_verified" => false,
        "requires_full_suite" => true, "execution_ready" => false,
        "baseline_fingerprint" => baseline.fingerprint, "current_fingerprint" => current.fingerprint,
        "changes" => selection.changes.transform_keys(&:to_s),
        "discovered_specs" => selection.current_specs,
        "candidate_specs" => candidates,
        "root_changes" => selection.root_changes, "unmapped_changes" => selection.unmapped_changes,
        "fallback_reasons" => plan.fallback_reasons,
        "previous_failures_available" => plan.previous_failures_available?,
        "union_nanoseconds" => selection.union_nanoseconds,
        "limitations" => (selection.limitations + LIMITATIONS + [provenance_note, failure_note] + (plan.static_enabled ? [StaticDependencies::LIMITATION] : [])).uniq.sort,
        "decisions" => plan.decisions.map do |decision|
          entry = { "spec" => decision.spec, "candidate" => candidate_set.include?(decision.spec),
            "bitmap_sources" => decision.selection.bitmap_sources,
            "changed_spec" => decision.selection.changed_spec, "unindexed_spec" => decision.selection.unindexed_spec,
            "reasons" => decision.reasons,
            "hazards" => decision.hazards.map { |hazard| { "name" => hazard.name, "node_type" => hazard.node_type,
              "line" => hazard.line, "column" => hazard.column, "length" => hazard.length } } }
          if plan.static_enabled
            entry["static_sources"] = decision.static_sources
            entry["static_uncertainties"] = decision.static_uncertainties
          end
          entry
        end }
      if failures_digest || plan.static_enabled
        result["previous_failures_source_sha256"] = failures_digest
        result["unmatched_previous_failures"] = plan.unmatched_previous_failures
      end
      result["static_deleted_fallback"] = plan.static_deleted_fallback if plan.static_enabled
      result
    end
    private_class_method :serialize
  end
end
