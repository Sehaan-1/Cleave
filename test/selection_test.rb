# frozen_string_literal: true

require "minitest/autorun"
require "cleave"

class SelectionTest < Minitest::Test
  def inventory(paths)
    Cleave::Inventory.new(paths)
  end

  def setup
    @base = inventory({ "app/a.rb" => "a" * 64, "app/deleted.rb" => "b" * 64, "config/root.yml" => "c" * 64,
                        "spec/a_spec.rb" => "d" * 64, "spec/b_spec.rb" => "e" * 64, "spec/gone_spec.rb" => "f" * 64 })
    @current = inventory({ "app/a.rb" => "0" * 64, "config/root.yml" => "1" * 64, "config/new.json" => "2" * 64,
                           "spec/a_spec.rb" => "d" * 64, "spec/b_spec.rb" => "e" * 64, "spec/new_spec.rb" => "3" * 64 })
    @index = Cleave::BitmapIndex.new(inventory_fingerprint: @base.fingerprint,
      specs: %w[spec/a_spec.rb spec/b_spec.rb spec/gone_spec.rb],
      masks: { "app/a.rb" => 1, "app/deleted.rb" => 4, "config/new.json" => 2 },
      root_paths: ["config/root.yml"], limitations: ["partial"])
  end

  def select(baseline: @base, current: @current, index: @index, specs: %w[spec/new_spec.rb spec/b_spec.rb spec/a_spec.rb])
    Cleave::Selection.select(baseline: baseline, current: current, index: index, current_specs: specs)
  end

  def test_changes_union_attribution_and_full_fallback
    result = select
    assert_equal({ added: %w[config/new.json spec/new_spec.rb], deleted: %w[app/deleted.rb spec/gone_spec.rb],
                   modified: %w[app/a.rb config/root.yml] }, result.changes)
    assert_equal 7, result.observed_baseline_mask
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb spec/new_spec.rb], result.current_specs
    assert_equal 7, result.candidate_mask
    assert_equal 7, result.execution_mask
    assert_equal result.current_specs, result.selected_specs
    assert result.requires_full_suite?
    assert_equal %w[config/root.yml], result.root_changes
    assert_includes result.fallback_reasons, "incomplete_index"
    assert_includes result.fallback_reasons, "root_scope_changed"
    assert_includes result.fallback_reasons, "spec_universe_changed"
    assert_includes result.fallback_reasons, "unmapped_changes"
    assert_equal ["app/a.rb"], result.decisions[0].bitmap_sources
    assert_equal ["config/new.json"], result.decisions[1].bitmap_sources
    assert result.decisions[2].unindexed_spec
    assert_equal ["partial"], result.limitations
    assert_operator result.union_nanoseconds, :>=, 0
    assert result.frozen?
    assert result.decisions.all?(&:frozen?)
  end

  def test_incomplete_index_never_skips_even_with_zero_candidates
    result = select(current: @base, specs: @index.specs)
    assert_equal 0, result.candidate_mask
    assert_empty result.candidate_specs
    assert_equal 7, result.execution_mask
    assert_equal @index.specs, result.selected_specs
    assert_equal ["incomplete_index"], result.fallback_reasons
    assert result.decisions.all? { |decision| decision.execution_reasons.include?("incomplete_index") }
  end

  def test_changed_spec_and_added_spec_are_candidates_without_bitmap
    current = inventory(@base.files.merge("spec/a_spec.rb" => "9" * 64, "spec/new_spec.rb" => "8" * 64))
    result = select(current: current, specs: @index.specs + ["spec/new_spec.rb"])
    assert_equal %w[spec/a_spec.rb spec/new_spec.rb], result.candidate_specs
    assert result.decisions.find { |decision| decision.spec == "spec/a_spec.rb" }.changed_spec
    assert result.decisions.find { |decision| decision.spec == "spec/new_spec.rb" }.unindexed_spec
    assert_equal 15, result.execution_mask
  end

  def test_rejects_mismatched_artifacts_or_incomplete_supplied_universe
    assert_raises(Cleave::ArtifactError) { select(baseline: @current) }
    assert_raises(Cleave::ArtifactError) { select(specs: ["spec/a_spec.rb", "spec/a_spec.rb"]) }
    assert_raises(Cleave::ArtifactError) { select(specs: ["spec/a_spec.rb", "spec/absent_spec.rb"]) }
    assert_raises(Cleave::ArtifactError) { select(specs: ["spec/a_spec.rb"]) }
    assert_raises(Cleave::ArtifactError) { select(specs: ["../bad"]) }
    bad_index = Cleave::BitmapIndex.new(inventory_fingerprint: @base.fingerprint, specs: ["spec/ghost_spec.rb"], masks: {}, root_paths: [], limitations: ["partial"])
    assert_raises(Cleave::ArtifactError) { select(index: bad_index) }
  end

  def test_real_1200_bit_union_and_changed_spec_id_remapping
    specs = 1200.times.map { |n| format("spec/%04d_spec.rb", n) }
    base_files = specs.to_h { |path| [path, "a" * 64] }.merge("app/a.rb" => "1" * 64, "app/b.rb" => "2" * 64)
    baseline = inventory(base_files)
    current_files = base_files.merge("app/a.rb" => "3" * 64, "app/b.rb" => "4" * 64, "spec/0000_new_spec.rb" => "b" * 64)
    current = inventory(current_files)
    index = Cleave::BitmapIndex.new(inventory_fingerprint: baseline.fingerprint, specs: specs,
      masks: { "app/a.rb" => (1 | (1 << 1199)), "app/b.rb" => (1 << 64) }, root_paths: [], limitations: ["partial"])
    result = select(baseline: baseline, current: current, index: index, specs: specs + ["spec/0000_new_spec.rb"])
    assert_equal 1 | (1 << 64) | (1 << 1199), result.observed_baseline_mask
    assert_equal 1201, result.selected_specs.length
    assert_equal %w[spec/0000_new_spec.rb spec/0000_spec.rb spec/0064_spec.rb spec/1199_spec.rb], result.candidate_specs
    assert_equal (1 << 1201) - 1, result.execution_mask
    assert_operator result.union_nanoseconds, :>=, 0
  end


  def test_inventory_trace_and_selector_integration
    require "tmpdir"
    require "fileutils"
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "spec"))
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "spec/a_spec.rb"), "# a\n")
      File.write(File.join(root, "spec/b_spec.rb"), "# b\n")
      File.write(File.join(root, "config/rails.yml"), "old\n")
      paths = %w[spec/a_spec.rb spec/b_spec.rb config/rails.yml]
      baseline = Cleave::Inventory.capture(root: root, paths: paths)
      trace = Cleave::ScopedTrace.start(root: root)
      begin
        trace.with_spec("spec/a_spec.rb") { File.read(File.join(root, "config/rails.yml")) }
      ensure
        report = trace.stop
      end
      index = Cleave::BitmapIndex.build(inventory: baseline, root: root, specs: paths.grep(/_spec\.rb$/), reports: [report])
      File.write(File.join(root, "config/rails.yml"), "new\n")
      current = Cleave::Inventory.capture(root: root, paths: paths)
      result = Cleave::Selection.select(baseline: baseline, current: current, index: index, current_specs: index.specs)
      assert_equal ["spec/a_spec.rb"], result.candidate_specs
      assert_equal 1, result.observed_baseline_mask
      assert_equal %w[spec/a_spec.rb spec/b_spec.rb], result.selected_specs
      assert result.requires_full_suite?
      refute result.execution_ready?
    end
  end

  def test_empty_suite_is_only_the_callers_explicit_current_suite
    baseline = inventory({})
    index = Cleave::BitmapIndex.new(inventory_fingerprint: baseline.fingerprint, specs: [], masks: {}, root_paths: [], limitations: ["partial"])
    result = select(baseline: baseline, current: baseline, index: index, specs: [])
    assert_empty result.selected_specs
    assert result.requires_full_suite?
    refute result.execution_ready?
    assert_equal 0, result.execution_mask
  end
end
