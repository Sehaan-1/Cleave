# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"

class GuardrailsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-guardrails")
    FileUtils.mkdir_p(File.join(@root, "spec"))
    FileUtils.mkdir_p(File.join(@root, "app"))
    FileUtils.mkdir_p(File.join(@root, "config"))
    @specs = %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb spec/d_spec.rb]
    write("spec/a_spec.rb", "# typed: strict\nRSpec.describe('a') {}\n")
    write("spec/b_spec.rb", "# typed: strict\nDir.glob('db/migrations/*.rb')\n")
    write("spec/c_spec.rb", "# typed: strict\nRSpec.describe('c') {}\n")
    write("spec/d_spec.rb", "# typed: strict\nRSpec.describe('d') {}\n")
    write("app/service.rb", "old\n")
    write("config/boot.yml", "before\n")
    @paths = @specs + %w[app/service.rb config/boot.yml]
    @baseline = capture
    @index = Cleave::BitmapIndex.new(inventory_fingerprint: @baseline.fingerprint, specs: @specs,
      masks: { "app/service.rb" => 1 }, root_paths: ["config/boot.yml"], limitations: ["partial trace"])
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write(path, text)
    File.write(File.join(@root, path), text)
  end

  def capture
    Cleave::Inventory.capture(root: @root, paths: @paths)
  end

  def plan(current: capture, failures: [], specs: @specs, root: @root)
    Cleave::Guardrails.plan(root: root, baseline: @baseline, current: current, index: @index,
                            current_specs: specs, previous_failures: failures)
  end

  def test_union_of_bitmap_prism_and_previous_failure_without_double_counting
    write("app/service.rb", "changed\n")
    result = plan(failures: %w[spec/a_spec.rb spec/c_spec.rb])
    assert_equal 1, result.selection.candidate_mask
    assert_equal 2, result.mandatory_mask
    assert_equal 5, result.previous_failure_mask
    assert_equal 7, result.guardrailed_candidate_mask
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb], result.guardrailed_candidate_specs
    assert_equal 15, result.execution_mask
    assert_equal @specs, result.selected_specs
    assert result.requires_full_suite?
    refute result.execution_ready?
    assert result.previous_failures_available?
    assert_equal %w[bitmap_hit previous_failure incomplete_index_fallback], result.decisions[0].reasons
    assert_equal %w[prism_hazard incomplete_index_fallback], result.decisions[1].reasons
    hazard = result.decisions[1].hazards.first
    assert_equal ["glob", "CallNode", 2, 0], [hazard.name, hazard.node_type, hazard.line, hazard.column]
    assert result.decisions.all?(&:frozen?)
    assert hazard.frozen?
  end

  def test_new_migration_is_covered_by_unconditional_prism_hazard
    FileUtils.mkdir_p(File.join(@root, "db/migrations"))
    path = "db/migrations/20261118_add_settlement_index.rb"
    write(path, "class SettlementIndex; end\n")
    @paths << path
    result = plan
    assert_equal [path], result.selection.changes[:added]
    assert_includes result.selection.unmapped_changes, path
    assert_equal 0, result.selection.candidate_mask
    assert_equal 2, result.mandatory_mask
    assert_equal ["spec/b_spec.rb"], result.guardrailed_candidate_specs
    assert_equal 15, result.execution_mask
  end

  def test_root_scope_change_forces_full_mask_even_for_preview
    write("config/boot.yml", "after\n")
    result = plan
    assert_equal ["config/boot.yml"], result.selection.root_changes
    assert_equal 15, result.root_mask
    assert_equal 15, result.guardrailed_candidate_mask
    assert_equal @specs, result.guardrailed_candidate_specs
    assert_includes result.fallback_reasons, "root_scope_changed"
    assert result.decisions.all? { |decision| decision.reasons.include?("root_scope_fallback") }
  end

  def test_missing_or_unmatched_previous_failures_are_not_reported_as_clean
    unavailable = plan(failures: nil)
    refute unavailable.previous_failures_available?
    assert_includes unavailable.fallback_reasons, "previous_failures_unavailable"
    assert_equal 0, unavailable.previous_failure_mask
    unmatched = plan(failures: ["spec/deleted_spec.rb"])
    assert unmatched.previous_failures_available?
    assert_equal ["spec/deleted_spec.rb"], unmatched.unmatched_previous_failures
    assert_includes unmatched.fallback_reasons, "previous_failures_unmatched"
    assert_equal 15, unmatched.execution_mask
    assert_raises(Cleave::ArtifactError) { plan(failures: ["../outside"]) }
    assert_raises(Cleave::ArtifactError) { plan(failures: %w[spec/a_spec.rb spec/a_spec.rb]) }
    assert_raises(Cleave::ArtifactError) { plan(failures: "spec/a_spec.rb") }
  end

  def test_digest_mismatch_and_parse_failure_abort_the_plan
    snapshot = capture
    write("spec/b_spec.rb", "RSpec.describe('changed') {}\n")
    assert_raises(Cleave::ArtifactError) { plan(current: snapshot) }
    write("spec/b_spec.rb", "class Broken\n")
    assert_raises(Cleave::ParseError) { plan }
  end

  def test_symlink_or_absent_spec_aborts_and_never_produces_a_partial_plan
    snapshot = capture
    File.delete(File.join(@root, "spec/b_spec.rb"))
    assert_raises(Cleave::ArtifactError) { plan(current: snapshot) }
    File.symlink(File.join(@root, "spec/a_spec.rb"), File.join(@root, "spec/b_spec.rb"))
    assert_raises(Cleave::ArtifactError) { plan(current: snapshot) }
  end

  def test_hazards_for_nonstandard_spec_names_and_multiple_types
    write("spec/c_spec.rb", "Object.const_get(:X)\neval('1')\nsend(:foo)\n")
    write("spec/worker.rb", "Object.const_get(:Y)\n")
    @paths << "spec/worker.rb"
    result = plan(specs: @specs + ["spec/worker.rb"])
    assert_equal 22, result.mandatory_mask
    assert_equal %w[const_get eval send], result.decisions[2].hazards.map(&:name)
    assert_equal [1, 2, 3], result.decisions[2].hazards.map(&:line)
    assert_equal ["const_get"], result.decisions[4].hazards.map(&:name)
  end

  def test_1200_spec_guardrail_bits
    specs = 1200.times.map { |n| format("spec/%04d_spec.rb", n) }
    specs.each_with_index do |path, id|
      write(path, id == 1199 ? "Dir.glob('db/*.rb')\n" : "# spec #{id}\n")
    end
    baseline = Cleave::Inventory.capture(root: @root, paths: specs)
    index = Cleave::BitmapIndex.new(inventory_fingerprint: baseline.fingerprint, specs: specs, masks: {}, root_paths: [], limitations: ["partial"])
    result = Cleave::Guardrails.plan(root: @root, baseline: baseline, current: baseline, index: index,
                                    current_specs: specs, previous_failures: [specs[64]])
    assert_equal 1 << 1199, result.mandatory_mask
    assert_equal 1 << 64, result.previous_failure_mask
    assert_equal (1 << 1199) | (1 << 64), result.guardrailed_candidate_mask
    assert_equal (1 << 1200) - 1, result.execution_mask
    assert_equal [specs[64], specs[1199]], result.guardrailed_candidate_specs
  end
end
