# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"

class StaticDependenciesTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-static")
    write("spec/a_spec.rb", "require_relative '../app/entry'\n")
    write("spec/b_spec.rb", "Widget\n")
    write("spec/c_spec.rb", "# no dependencies\n")
    write("app/entry.rb", "require_relative 'child'\n")
    write("app/child.rb", "require_relative 'entry.rb'\nclass Widget; end\n")
    write("other/widget.rb", "module Alternate; class Widget; end; end\n")
    @paths = %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb app/entry.rb app/child.rb other/widget.rb]
    @specs = %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb]
    @baseline = capture
    @index = Cleave::BitmapIndex.new(inventory_fingerprint: @baseline.fingerprint, specs: @specs, masks: {}, root_paths: [], limitations: ["partial"])
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write(path, source)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, source)
  end

  def capture
    Cleave::Inventory.capture(root: @root, paths: @paths)
  end

  def plan(current = capture)
    Cleave::Guardrails.plan(root: @root, baseline: @baseline, current: current, index: @index,
                            current_specs: @specs, previous_failures: [], static_dependencies: true)
  end

  def test_transitive_relative_cycle_and_ambiguous_constant_definitions
    write("app/child.rb", "require_relative 'entry.rb'\nclass Widget; end\n# changed\n")
    result = plan
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb], result.guardrailed_candidate_specs
    assert_equal ["app/child.rb"], result.decisions[0].static_sources
    assert_equal ["app/child.rb"], result.decisions[1].static_sources
    assert_empty result.decisions[2].static_sources
    assert_includes result.decisions[0].reasons, "static_dependency"
    assert_equal 3, result.static_mask
    assert_equal 7, result.execution_mask
    assert result.requires_full_suite?
    refute result.execution_ready?
    # Conservative basename matching includes all same-named definitions.
    write("other/widget.rb", "module Alternate; class Widget; end; end\n# changed\n")
    assert_includes plan.decisions[1].static_sources, "other/widget.rb"
  end

  def test_unresolved_and_dynamic_reachable_files_add_candidate_even_without_changes
    write("app/child.rb", "require_relative 'missing'\nrequire 'json'\nUnknownConstant\neval('1')\n")
    result = plan
    decision = result.decisions[0]
    assert_equal %w[dynamic_or_directory_operation unresolved_constant unresolved_require_relative unresolved_runtime_load], decision.static_uncertainties
    assert_includes decision.reasons, "static_uncertainty"
    assert_includes result.fallback_reasons, "static_uncertainty"
    refute_includes result.decisions[2].reasons, "static_uncertainty"
  end

  def test_deleted_ruby_selects_every_spec_in_candidate
    File.delete(File.join(@root, "app/entry.rb"))
    result = plan
    assert result.static_deleted_fallback
    assert_equal @specs, result.guardrailed_candidate_specs
    assert_includes result.fallback_reasons, "static_deleted_ruby"
    assert result.decisions.all? { |d| d.reasons.include?("static_deleted_fallback") }
    assert_includes result.decisions[0].static_uncertainties, "unresolved_require_relative"
  end

  def test_rejects_stale_symlink_invalid_and_oversized_sources
    snapshot = capture
    write("app/child.rb", "# changed\n")
    assert_match(/inventory/, assert_raises(Cleave::ArtifactError) { plan(snapshot) }.message)
    write("app/child.rb", "class Broken\n")
    assert_raises(Cleave::ParseError) { plan }
    write("app/child.rb", "#" * (Cleave::StaticDependencies::MAX_FILE_BYTES + 1))
    assert_match(/size limit/, assert_raises(Cleave::ArtifactError) { plan }.message)
    File.delete(File.join(@root, "app/child.rb"))
    begin
      File.symlink(File.join(@root, "app/entry.rb"), File.join(@root, "app/child.rb"))
    rescue NotImplementedError, Errno::EACCES
      skip "symlink creation requires privileges unavailable on this platform"
    end
    assert_raises(Cleave::ArtifactError) { plan(snapshot) }
  end

  def test_unavailable_and_outside_relative_targets_are_uncertain
    write("app/entry.rb", "require_relative '../../outside'\nrequire_relative 'missing.so'\n")
    result = plan
    assert_includes result.decisions[0].static_uncertainties, "unresolved_require_relative"
  end
end
