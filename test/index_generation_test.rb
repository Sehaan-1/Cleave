# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "cleave"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "json"
require "timeout"

class IndexGenerationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-index")
    project = File.expand_path("..", __dir__)
    write("Gemfile", "source 'https://rubygems.org'\ngem 'cleave-ste', path: #{project.inspect}\ngem 'rspec', '~> 3.13'\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "lock", "--local", chdir: @root)
    raise output unless status.success?
    assert system("git", "-C", @root, "init", "-q")
    write(".gitignore", ".cleave/\nignored/\n")
    write("root.json", "{}")
    write("a.json", "{}")
    write("ignored/extra.json", "{}")
    write("spec/spec_helper.rb", "File.read('root.json')\n")
    write(".rspec", "--require ./spec/spec_helper.rb\n")
    write("spec/a_spec.rb", "RSpec.describe('a') { it('passes') { File.read('a.json'); File.read('ignored/extra.json') } }\n")
    write("spec/b_spec.rb", "RSpec.describe('b') { it('passes') { expect(true).to be(true) } }\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write(path, data)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, data)
  end

  def run_index(**options)
    output = StringIO.new
    result = Cleave::RSpecRunner.run(root: @root, trace: true, index: true, output: output, **options)
    [result, output.string]
  end

  def test_generates_pair_from_real_full_suite_with_explicit_ignored_path
    result, output = run_index(includes: ["ignored/extra.json"])
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_equal "recorded", result.dig("index", "status")
    provenance = Cleave::IndexProvenance.inspect_pair(root: @root)
    assert_equal "recorded", provenance["status"]
    assert_equal result.dig("index", "generation_id"), provenance["generation_id"]
    assert_equal false, provenance["complete"]
    assert_equal false, provenance["suite_coverage_verified"]
    assert_equal false, provenance["failed_examples"]
    inventory, index = Cleave::Artifacts.read(File.join(@root, ".cleave"))
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb], index.specs
    assert_equal 1, index.masks.fetch("a.json")
    assert_equal 1, index.masks.fetch("ignored/extra.json")
    assert_includes index.root_paths, "root.json"
    assert inventory.files.key?("ignored/extra.json")
    refute inventory.files.keys.any? { |path| path.start_with?(".cleave/") }
    refute index.to_h["complete"]
    assert index.limitations.any? { |s| s.include?("not transactional") }
    html = Cleave::GraphExport.render(inventory: inventory, index: index)
    assert_includes html, "a.json"
    persisted = JSON.parse(File.read(File.join(@root, ".cleave/last_run.json")))
    assert_equal result.fetch("index"), persisted.fetch("index")
  end

  def test_ignored_observed_paths_can_be_absent_and_are_not_fabricated
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    inventory, index = Cleave::Artifacts.read(File.join(@root, ".cleave"))
    refute inventory.files.key?("ignored/extra.json")
    assert_equal 1, index.masks.fetch("ignored/extra.json")
  end

  def test_failing_examples_still_produce_diagnostic_pair
    write("spec/b_spec.rb", "RSpec.describe('b') { it('fails') { expect(1).to eq(2) } }\n")
    result, output = run_index
    assert_equal "failed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal "recorded", result.dig("index", "status")
    assert_equal true, Cleave::IndexProvenance.inspect_pair(root: @root)["failed_examples"]
    assert_equal 1, result["exit_code"]
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb], Cleave::Artifacts.read(File.join(@root, ".cleave"))[1].specs
  end

  def test_changed_inventory_rejects_publication_but_runs_all_examples
    write("spec/b_spec.rb", "RSpec.describe('b') { it('changes') { File.write('a.json', 'changed') } }\n")
    write(".cleave/inventory.json", "old inventory")
    write(".cleave/bitmap_index.json", "old index")
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_match(/changed during/, result.dig("index", "error"))
    assert_equal "old inventory", File.read(File.join(@root, ".cleave/inventory.json"))
    assert_equal "old index", File.read(File.join(@root, ".cleave/bitmap_index.json"))
    assert_equal "incomplete", JSON.parse(File.read(File.join(@root, ".cleave/index_provenance.json")))["status"]
  end

  def test_ignored_specs_require_explicit_include
    write(".gitignore", ".cleave/\nspec/b_spec.rb\n")
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_match(/absent from inventory/, result.dig("index", "error"))
    result, output = run_index(includes: ["spec/b_spec.rb"])
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
  end

  def test_setup_error_still_runs_full_suite_and_output_symlink_is_rejected
    result, output = run_index(includes: [".cleave/last_run.json"])
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_match(/cannot include Cleave state/, result.dig("index", "error"))
    begin
      File.symlink(File.join(@root, "a.json"), File.join(@root, ".cleave/inventory.json"))
    rescue NotImplementedError, Errno::EACCES
      skip "symlink creation requires privileges unavailable on this platform"
    end
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_match(/symlink/, result.dig("index", "error"))
    assert_equal "{}", File.read(File.join(@root, "a.json"))
  end

  def test_missing_include_and_symlinked_include_are_rejected
    result, output = run_index(includes: ["ignored/missing.json"])
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_match(/included files are missing/, result.dig("index", "error"))
    begin
      File.symlink(File.join(@root, "a.json"), File.join(@root, "ignored/link.json"))
    rescue NotImplementedError, Errno::EACCES
      skip "symlink creation requires privileges unavailable on this platform"
    end
    result, output = run_index(includes: ["ignored/link.json"])
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_match(/symlink/, result.dig("index", "error"))
  end

  def test_interrupt_records_incomplete_index_without_publishing
    skip "Windows delivers Ctrl+C to the whole console, not a single child" if Gem.win_platform?
    write("spec/slow_spec.rb", "RSpec.describe('slow') { it('waits') { File.write('.cleave/started', 'yes'); sleep 60 } }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    pid = Process.spawn(env, "bundle", "exec", "cleave", "run", "--trace", "--index", chdir: @root, out: File::NULL, err: File::NULL)
    begin
      Timeout.timeout(30) { sleep 0.05 until File.exist?(File.join(@root, ".cleave/started")) }
      assert_equal "running", JSON.parse(File.read(File.join(@root, ".cleave/index_provenance.json")))["status"]
      Process.kill("INT", pid)
      _, status = Timeout.timeout(10) { Process.wait2(pid) }
      pid = nil
      assert_equal 130, status.exitstatus
      state = JSON.parse(File.read(File.join(@root, ".cleave/last_run.json")))
      assert_equal "incomplete", state.dig("index", "status")
      assert_equal "incomplete", JSON.parse(File.read(File.join(@root, ".cleave/index_provenance.json")))["status"]
      refute File.exist?(File.join(@root, ".cleave/inventory.json"))
    ensure
      if pid
        Process.kill("KILL", pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end

  def test_abrupt_runner_death_leaves_running_marker_and_rejects_old_pair
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    write("spec/slow_spec.rb", "RSpec.describe('slow') { it('waits') { File.write('.cleave/worker_pid', Process.pid.to_s); sleep 60 } }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    pid = Process.spawn(env, "bundle", "exec", "cleave", "run", "--trace", "--index", chdir: @root, out: File::NULL, err: File::NULL)
    worker = nil
    begin
      path = File.join(@root, ".cleave/worker_pid")
      Timeout.timeout(30) { sleep 0.05 until File.exist?(path) && !File.zero?(path) }
      worker = Integer(File.read(path))
      # Process.spawn returns the batch launcher pid on Windows, so kill the tree.
      if Gem.win_platform?
        system("taskkill", "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
      else
        Process.kill("KILL", pid)
      end
      Timeout.timeout(10) { Process.wait(pid) }
      pid = nil
      assert_match(/running/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
      assert_match(/running/, assert_raises(Cleave::ArtifactError) { Cleave::DiagnosticPlan.build(root: @root, output: StringIO.new) }.message)
    ensure
      Process.kill("KILL", -worker) rescue nil if worker
      if pid
        Process.kill("KILL", pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end

  def test_crash_does_not_publish_pair
    write("spec/a_spec.rb", "RSpec.describe('crash') { it('exits') { exit! 7 } }\n")
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal "incomplete", result.dig("index", "status")
    refute File.exist?(File.join(@root, ".cleave/inventory.json"))
    assert_equal "incomplete", JSON.parse(File.read(File.join(@root, ".cleave/index_provenance.json")))["status"]
  end

  def test_provenance_rejects_mixed_pair_even_if_inventory_fingerprint_matches
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    path = File.join(@root, ".cleave/bitmap_index.json")
    index = JSON.parse(File.read(path))
    index["limitations"] << "Tampered, but inventory fingerprint is unchanged."
    index["limitations"].sort!
    File.write(path, JSON.pretty_generate(index) + "\n")
    assert Cleave::Artifacts.read(File.join(@root, ".cleave")) # v1 fingerprint alone accepts this pair.
    assert_match(/does not match/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
    assert_match(/does not match/, assert_raises(Cleave::ArtifactError) { Cleave::DiagnosticPlan.build(root: @root, output: StringIO.new) }.message)
    audit = Cleave::RSpecRunner.run(root: @root, verify: true, output: StringIO.new)
    assert_equal "incomplete", audit.dig("verification", "status")
    assert_equal 2, audit["example_count"]
    assert_match(/does not match/, audit.dig("verification", "errors").join)
  end

  def test_incomplete_marker_prevents_reuse_after_failure_and_partial_publication
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    old = Cleave::IndexProvenance.inspect_pair(root: @root)
    partial = lambda do |directory, inventory:, index:|
      File.write(File.join(directory, "inventory.json"), JSON.pretty_generate(inventory.to_h) + "\n")
      raise IOError, "simulated interrupted pair write"
    end
    Cleave::Artifacts.stub(:write, partial) do
      result, = run_index
      assert_equal "incomplete", result["outcome"]
      assert_match(/simulated interrupted/, result.dig("index", "error"))
    end
    marker = JSON.parse(File.read(File.join(@root, ".cleave/index_provenance.json")))
    assert_equal "incomplete", marker["status"]
    refute_equal old["generation_id"], marker["generation_id"]
    assert_match(/incomplete/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
    assert_match(/incomplete/, assert_raises(Cleave::ArtifactError) { Cleave::DiagnosticPlan.build(root: @root, output: StringIO.new) }.message)
  end

  def test_missing_marker_is_legacy_unknown_but_invalid_markers_are_rejected
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    path = File.join(@root, ".cleave/index_provenance.json")
    saved = File.read(path)
    File.delete(path)
    assert_equal "unavailable", Cleave::IndexProvenance.inspect_pair(root: @root)["status"]
    plan = Cleave::DiagnosticPlan.build(root: @root, output: StringIO.new)
    assert plan["limitations"].any? { |text| text.include?("provenance is unavailable") }
    File.write(path, saved.sub('"version": 1', '"version": 1, "version": 1'))
    assert_match(/duplicate/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
    File.delete(path)
    begin
      File.symlink(File.join(@root, ".cleave/inventory.json"), path)
      assert_match(/symlink/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
      assert_raises(Cleave::ArtifactError) { run_index }
    rescue NotImplementedError, Errno::EACCES
      skip "symlink creation requires privileges unavailable on this platform"
    end
  end

  def test_invalid_marker_cannot_claim_coverage_or_escape_size_limit
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    path = File.join(@root, ".cleave/index_provenance.json")
    marker = JSON.parse(File.read(path))
    marker["complete"] = true
    File.write(path, JSON.generate(marker))
    assert_match(/invalid index provenance/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
    File.write(path, " " * (Cleave::IndexProvenance::MAX_BYTES + 1))
    assert_match(/exceeds limit/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
  end

  def test_nonindexed_run_leaves_publication_marker_unchanged
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    marker = File.binread(File.join(@root, ".cleave/index_provenance.json"))
    run = Cleave::RSpecRunner.run(root: @root, output: StringIO.new)
    assert_equal "passed", run["outcome"]
    assert_equal marker, File.binread(File.join(@root, ".cleave/index_provenance.json"))
  end

  def test_running_marker_and_cli_status
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    stdout, stderr, status = Open3.capture3(env, "bundle", "exec", "cleave", "provenance", chdir: @root)
    assert status.success?, stderr
    assert_equal "recorded", JSON.parse(stdout)["status"]
    Cleave::IndexProvenance.begin_run(File.join(@root, ".cleave"))
    assert_match(/running/, assert_raises(Cleave::ArtifactError) { Cleave::IndexProvenance.inspect_pair(root: @root) }.message)
    _, stderr, status = Open3.capture3(env, "bundle", "exec", "cleave", "provenance", chdir: @root)
    refute status.success?
    assert_match(/running/, stderr)
    File.delete(File.join(@root, ".cleave/index_provenance.json"))
    stdout, _, status = Open3.capture3(env, "bundle", "exec", "cleave", "provenance", chdir: @root)
    refute status.success?
    assert_equal "unavailable", JSON.parse(stdout)["status"]
  end

  def test_cli_and_invalid_combinations
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "run", "--trace", "--index", "--include", "ignored/extra.json", chdir: @root)
    assert status.success?, output
    assert_match(/Artifacts: recorded/, output)
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, index: true) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, trace: true, index: true, workers: 2) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, includes: ["a.json"]) }
  end
end
