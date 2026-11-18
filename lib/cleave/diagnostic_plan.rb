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
      "Previous failures were not supplied; the candidate is diagnostic and cannot authorize test skipping.",
      "Baseline artifacts can be stale or from another run; matching fingerprints do not establish provenance."
    ].freeze

    def build(root:, includes: [], output: $stderr, expected_artifacts: nil)
      root = File.realpath(root)
      raise ArgumentError, "not a directory: #{root}" unless File.directory?(root)
      raise RunnerError, "project Gemfile not found in #{root}" unless File.file?(File.join(root, "Gemfile"))
      raise ArtifactError, "includes must be an array" unless includes.is_a?(Array)
      includes = includes.map { |path| ArtifactValidation.path(path) }.uniq.sort
      raise ArtifactError, "cannot include Cleave state" if includes.any? { |path| internal?(path) }
      stdout, stderr, status = Open3.capture3("git", "-C", root, "rev-parse", "--show-toplevel")
      raise ArtifactError, "git root unavailable: #{stderr.strip}" unless status.success?
      raise ArtifactError, "planning requires the Git project root" unless File.realpath(stdout.strip) == root
      state = File.join(root, ".cleave")
      raise ArtifactError, ".cleave must be a real directory, not a symlink" if File.symlink?(state) || !File.directory?(state)
      lock_path = File.join(state, "runner.lock")
      raise ArtifactError, "runner lock must not be a symlink" if File.symlink?(lock_path)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise RunnerError, "another Cleave run or plan is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
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
                                 current_specs: files, previous_failures: nil)
          after = ShadowVerification.capture(root, extras + files)
          raise ArtifactError, "project changed during planning" unless current.fingerprint == after.fingerprint
          serialize(inventory, current, plan, provenance: provenance)
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
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
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

    def serialize(baseline, current, plan, provenance:)
      selection = plan.selection
      candidates = plan.guardrailed_candidate_specs
      candidate_set = candidates.to_set
      provenance_note = if provenance["status"] == "recorded"
        "Artifact bytes match a local publication marker; this is not authentication or proof of coverage."
      else
        "Artifact publication provenance is unavailable; this may be a legacy or manually created pair."
      end
      { "schema" => SCHEMA, "version" => VERSION,
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
        "limitations" => (selection.limitations + LIMITATIONS + [provenance_note]).uniq.sort,
        "decisions" => plan.decisions.map do |decision|
          { "spec" => decision.spec, "candidate" => candidate_set.include?(decision.spec),
            "bitmap_sources" => decision.selection.bitmap_sources,
            "changed_spec" => decision.selection.changed_spec, "unindexed_spec" => decision.selection.unindexed_spec,
            "reasons" => decision.reasons,
            "hazards" => decision.hazards.map { |hazard| { "name" => hazard.name, "node_type" => hazard.node_type,
              "line" => hazard.line, "column" => hazard.column, "length" => hazard.length } } }
        end }
    end
    private_class_method :serialize
  end
end
