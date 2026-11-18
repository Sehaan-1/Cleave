# typed: false
# frozen_string_literal: true

require "digest"
require_relative "selection"
require_relative "static_analysis"
require_relative "static_dependencies"

module Cleave
  class GuardrailHazard
    attr_reader :name, :node_type, :line, :column, :length

    def initialize(fact)
      @name = fact.value.dup.freeze
      @node_type = fact.node_type.dup.freeze
      @line = fact.location.line
      @column = fact.location.column
      @length = fact.location.length
      freeze
    end
  end

  class GuardrailDecision
    attr_reader :spec, :selection, :hazards, :previous_failure, :reasons, :static_sources, :static_uncertainties

    def initialize(selection:, hazards:, previous_failure:, root_scope_fallback:, static_sources: [], static_uncertainties: [], static_deleted_fallback: false)
      @spec = selection.spec
      @selection = selection
      @hazards = hazards.freeze
      @previous_failure = previous_failure
      @static_sources = static_sources.map { |path| path.dup.freeze }.freeze
      @static_uncertainties = static_uncertainties.map { |note| note.dup.freeze }.freeze
      reasons = []
      reasons << "bitmap_hit" unless selection.bitmap_sources.empty?
      reasons << "changed_spec" if selection.changed_spec
      reasons << "unindexed_spec" if selection.unindexed_spec
      reasons << "prism_hazard" unless hazards.empty?
      reasons << "previous_failure" if previous_failure
      reasons << "static_dependency" unless @static_sources.empty?
      reasons << "static_uncertainty" unless @static_uncertainties.empty?
      reasons << "static_deleted_fallback" if static_deleted_fallback
      reasons << "root_scope_fallback" if root_scope_fallback
      reasons << "incomplete_index_fallback"
      @reasons = reasons.map(&:freeze).freeze
      freeze
    end
  end

  class GuardrailPlan
    attr_reader :selection, :mandatory_mask, :previous_failure_mask, :root_mask,
                :guardrailed_candidate_mask, :execution_mask, :decisions, :fallback_reasons,
                :unmatched_previous_failures, :static_mask, :static_enabled, :static_deleted_fallback

    def initialize(selection:, mandatory_mask:, previous_failure_mask:, root_mask:,
                   decisions:, fallback_reasons:, unmatched_previous_failures:, previous_failures_available:, static_mask: 0, static_enabled: false, static_deleted_fallback: false)
      @selection = selection
      @mandatory_mask = mandatory_mask
      @previous_failure_mask = previous_failure_mask
      @root_mask = root_mask
      @static_mask = static_mask
      @static_enabled = static_enabled
      @static_deleted_fallback = static_deleted_fallback
      @guardrailed_candidate_mask = selection.candidate_mask | mandatory_mask | previous_failure_mask | root_mask | static_mask
      @execution_mask = selection.execution_mask
      @decisions = decisions.freeze
      @fallback_reasons = fallback_reasons.map { |reason| reason.dup.freeze }.freeze
      @unmatched_previous_failures = unmatched_previous_failures.map { |path| path.dup.freeze }.freeze
      @previous_failures_available = previous_failures_available
      freeze
    end

    def previous_failures_available?
      @previous_failures_available
    end

    def requires_full_suite?
      true
    end

    def execution_ready?
      false
    end

    def selected_specs
      selection.current_specs
    end

    def guardrailed_candidate_specs
      selection.current_specs.each_with_index.filter_map { |spec, id| spec if (guardrailed_candidate_mask & (1 << id)) != 0 }
    end
  end

  module Guardrails
    module_function

    # Independently discover the entire current suite before calling this method.
    # Previous failures are explicit input, not a trusted or persisted CI result.
    # No result from v1 indexes authorizes skipping tests.
    def plan(root:, baseline:, current:, index:, current_specs:, previous_failures:, static_dependencies: false)
      raise ArgumentError, "static_dependencies must be true or false" unless [true, false].include?(static_dependencies)
      selection = Selection.select(baseline: baseline, current: current, index: index, current_specs: current_specs)
      unless previous_failures.nil? || previous_failures.is_a?(Array)
        raise ArtifactError, "previous_failures must be an array or nil"
      end
      failures = (previous_failures || []).map { |path| ArtifactValidation.path(path) }
      raise ArtifactError, "duplicate previous failure" unless failures.uniq.length == failures.length
      failures.sort!
      current_set = selection.current_specs.to_set
      unmatched = failures.reject { |path| current_set.include?(path) }
      failure_set = failures.to_set

      # Validate physical paths and content against the current inventory before
      # parsing, then hash the exact bytes parsed as a second stale-read check.
      root = File.realpath(root)
      unless selection.current_specs.all? { |path| path.end_with?(".rb") }
        raise ArtifactError, "all current specs must be Ruby files"
      end
      captured = Inventory.capture(root: root, paths: selection.current_specs)
      expected = selection.current_specs.to_h { |path| [path, current.files.fetch(path)] }
      raise ArtifactError, "current spec files do not match the inventory" unless captured.files == expected

      static_results, deleted_fallback = if static_dependencies
        StaticDependencies.analyze(root: root, current: current, specs: selection.current_specs, changes: selection.changes)
      else
        [{}, false]
      end
      static_mask = 0
      mandatory_mask = 0
      previous_mask = 0
      root_mask = selection.root_changes.empty? ? 0 : selection.execution_mask
      decisions = selection.decisions.each_with_index.map do |decision, id|
        source = File.binread(File.join(root, decision.spec))
        unless Digest::SHA256.hexdigest(source) == current.files.fetch(decision.spec)
          raise ArtifactError, "spec changed during analysis: #{decision.spec}"
        end
        analysis = StaticAnalysis.analyze(source, path: decision.spec, spec: true)
        hazards = analysis.facts.select { |fact| fact.kind == :hazard }.map { |fact| GuardrailHazard.new(fact) }
        previous_failure = failure_set.include?(decision.spec)
        mandatory_mask |= 1 << id unless hazards.empty?
        previous_mask |= 1 << id if previous_failure
        static = static_results.fetch(decision.spec, { sources: [], uncertainties: [] })
        static_mask |= 1 << id if deleted_fallback || !static[:sources].empty? || !static[:uncertainties].empty?
        GuardrailDecision.new(static_sources: static[:sources], static_uncertainties: static[:uncertainties],
                              static_deleted_fallback: deleted_fallback, selection: decision, hazards: hazards, previous_failure: previous_failure,
                              root_scope_fallback: root_mask != 0)
      end
      fallback_reasons = selection.fallback_reasons.dup
      fallback_reasons << "previous_failures_unavailable" if previous_failures.nil?
      fallback_reasons << "previous_failures_unmatched" unless unmatched.empty?
      fallback_reasons << "static_deleted_ruby" if deleted_fallback
      fallback_reasons << "static_uncertainty" if static_results.values.any? { |result| !result[:uncertainties].empty? }
      GuardrailPlan.new(selection: selection, mandatory_mask: mandatory_mask, previous_failure_mask: previous_mask,
                        root_mask: root_mask, decisions: decisions, fallback_reasons: fallback_reasons,
                        unmatched_previous_failures: unmatched, previous_failures_available: !previous_failures.nil?,
                        static_mask: static_mask, static_enabled: static_dependencies, static_deleted_fallback: deleted_fallback)
    end
  end
end
