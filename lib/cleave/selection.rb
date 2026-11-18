# typed: false
# frozen_string_literal: true

require "set"
require_relative "artifacts"

module Cleave
  class SelectionDecision
    attr_reader :spec, :bitmap_sources, :changed_spec, :unindexed_spec, :execution_reasons

    def initialize(spec:, bitmap_sources:, changed_spec:, unindexed_spec:, execution_reasons:)
      @spec = spec.dup.freeze
      @bitmap_sources = bitmap_sources.map { |path| path.dup.freeze }.freeze
      @changed_spec = changed_spec
      @unindexed_spec = unindexed_spec
      @execution_reasons = execution_reasons.map { |reason| reason.dup.freeze }.freeze
      freeze
    end

    def candidate?
      !bitmap_sources.empty? || changed_spec || unindexed_spec
    end
  end

  class SelectionResult
    attr_reader :changes, :current_specs, :observed_baseline_mask, :candidate_mask,
                :execution_mask, :decisions, :fallback_reasons, :unmapped_changes,
                :root_changes, :limitations, :union_nanoseconds

    def initialize(changes:, current_specs:, observed_baseline_mask:, candidate_mask:, execution_mask:,
                   decisions:, fallback_reasons:, unmapped_changes:, root_changes:, limitations:, union_nanoseconds:)
      @changes = changes.transform_values { |paths| paths.map { |path| path.dup.freeze }.freeze }.freeze
      @current_specs = current_specs.map { |path| path.dup.freeze }.freeze
      @observed_baseline_mask = observed_baseline_mask
      @candidate_mask = candidate_mask
      @execution_mask = execution_mask
      @decisions = decisions.freeze
      @fallback_reasons = fallback_reasons.map { |reason| reason.dup.freeze }.freeze
      @unmapped_changes = unmapped_changes.map { |path| path.dup.freeze }.freeze
      @root_changes = root_changes.map { |path| path.dup.freeze }.freeze
      @limitations = limitations.map { |item| item.dup.freeze }.freeze
      @union_nanoseconds = union_nanoseconds
      freeze
    end

    def requires_full_suite?
      true
    end

    # This slice does not validate suite discovery or provide an execution adapter.
    def execution_ready?
      false
    end

    def selected_specs
      current_specs
    end

    def candidate_specs
      decisions.select(&:candidate?).map(&:spec)
    end
  end

  module Selection
    module_function

    # The caller must independently discover the complete current test suite.
    # v1 indexes are incomplete; the candidate is diagnostic only and the
    # execution result always contains every supplied current spec.
    def select(baseline:, current:, index:, current_specs:)
      raise ArgumentError, "expected baseline and current inventories" unless baseline.is_a?(Inventory) && current.is_a?(Inventory)
      raise ArgumentError, "expected BitmapIndex" unless index.is_a?(BitmapIndex)
      raise ArtifactError, "index is not bound to baseline inventory" unless index.inventory_fingerprint == baseline.fingerprint
      raise ArtifactError, "indexed specs absent from baseline inventory" unless (index.specs - baseline.files.keys).empty?
      raise ArtifactError, "current_specs must be an array" unless current_specs.is_a?(Array)

      specs = current_specs.map { |path| ArtifactValidation.path(path) }
      raise ArtifactError, "duplicate current spec path" unless specs.uniq.length == specs.length
      specs.sort!
      absent = specs - current.files.keys
      raise ArtifactError, "current specs absent from current inventory: #{absent.join(', ')}" unless absent.empty?
      omitted = index.specs.select { |path| current.files.key?(path) } - specs
      raise ArtifactError, "current suite omits indexed specs still present: #{omitted.join(', ')}" unless omitted.empty?

      changes = baseline.diff(current)
      changed = changes.values.flatten.sort
      changed_set = changed.to_set
      current_ids = specs.each_with_index.to_h
      baseline_ids = index.specs.each_with_index.to_h
      file_masks = changed.map { |path| [path, index.masks.fetch(path, 0)] }

      # Time the actual integer OR only; diffing, attribution and rendering are excluded.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      observed = 0
      file_masks.each { |(_, mask)| observed |= mask }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started

      sources = Hash.new { |hash, key| hash[key] = [] }
      file_masks.each do |path, mask|
        while mask != 0
          lowest = mask & -mask
          baseline_id = lowest.bit_length - 1
          spec = index.specs.fetch(baseline_id)
          sources[spec] << path if current_ids.key?(spec)
          mask ^= lowest
        end
      end
      root_paths = index.root_paths.to_set
      roots = changed.select { |path| root_paths.include?(path) }
      unmapped = changed.reject { |path| index.masks.key?(path) || root_paths.include?(path) }
      fallbacks = ["incomplete_index"]
      fallbacks << "root_scope_changed" unless roots.empty?
      fallbacks << "spec_universe_changed" unless specs == index.specs
      fallbacks << "unmapped_changes" unless unmapped.empty?

      candidates = 0
      decisions = specs.each_with_index.map do |spec, id|
        decision = SelectionDecision.new(spec: spec, bitmap_sources: sources.fetch(spec, []),
                                         changed_spec: changed_set.include?(spec), unindexed_spec: !baseline_ids.key?(spec),
                                         execution_reasons: fallbacks)
        candidates |= 1 << id if decision.candidate?
        decision
      end
      SelectionResult.new(changes: changes, current_specs: specs, observed_baseline_mask: observed,
                          candidate_mask: candidates, execution_mask: (1 << specs.length) - 1,
                          decisions: decisions, fallback_reasons: fallbacks, unmapped_changes: unmapped,
                          root_changes: roots, limitations: index.limitations, union_nanoseconds: elapsed)
    end
  end
end
