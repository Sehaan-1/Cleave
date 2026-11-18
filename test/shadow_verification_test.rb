# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require "open3"

class ShadowVerificationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-shadow")
    FileUtils.mkdir_p(File.join(@root, "spec"))
    project = File.expand_path("..", __dir__)
    File.write(File.join(@root, "Gemfile"), "source 'https://rubygems.org'\ngem 'cleave-ste', path: #{project.inspect}\ngem 'rspec', '~> 3.13'\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "lock", "--local", chdir: @root)
    raise "bundle lock failed: #{output}" unless status.success?
    assert system("git", "-C", @root, "init", "-q")
    File.write(File.join(@root, "spec/a_spec.rb"), "RSpec.describe('a') { it('passes') { expect(1).to eq(1) } }\n")
    File.write(File.join(@root, "spec/b_spec.rb"), "RSpec.describe('b') { it('fails') { expect(1).to eq(2) } }\n")
    File.write(File.join(@root, "service.rb"), "old\n")
    @paths = %w[spec/a_spec.rb spec/b_spec.rb]
    inventory = Cleave::Inventory.capture_git(root: @root)
    index = Cleave::BitmapIndex.new(inventory_fingerprint: inventory.fingerprint, specs: @paths,
                                   masks: { "service.rb" => 1 }, root_paths: [], limitations: ["partial"])
    Cleave::Artifacts.write(File.join(@root, ".cleave"), inventory: inventory, index: index)
    File.write(File.join(@root, "service.rb"), "new\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def run_verify
    output = StringIO.new
    result = Cleave::RSpecRunner.run(root: @root, verify: true, output: output)
    [result, output.string, JSON.parse(File.read(File.join(@root, ".cleave/last_run.json")))]
  end

  def test_reports_observed_miss_without_skipping_the_full_suite
    result, output, persisted = run_verify
    assert_equal "failed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_equal 1, result["exit_code"]
    audit = result.fetch("verification")
    assert_equal "observed_misses", audit["status"]
    assert_equal ["spec/a_spec.rb"], audit["candidate_specs"]
    assert_equal @paths, audit["discovered_specs"]
    assert_equal ["spec/b_spec.rb"], audit["observed_missed_failure_specs"]
    assert_includes audit["fallback_reasons"], "previous_failures_unavailable"
    refute audit["suite_coverage_verified"]
    assert_equal result, persisted
  end

  def test_passing_suite_means_only_no_observed_misses
    File.write(File.join(@root, "spec/b_spec.rb"), "RSpec.describe('b') { it('passes') { expect(1).to eq(1) } }\n")
    result, output, = run_verify
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal "no_observed_misses", result.dig("verification", "status")
    assert_empty result.dig("verification", "observed_missed_failure_specs")
    refute result.dig("verification", "suite_coverage_verified")
  end

  def test_invalid_artifact_still_runs_suite_but_is_inconclusive
    File.delete(File.join(@root, ".cleave/bitmap_index.json"))
    result, output, = run_verify
    assert_equal "incomplete", result["outcome"], output
    assert_equal 2, result["example_count"]
    assert_equal ["spec/b_spec.rb"], result["observed_failed_specs"]
    assert_equal "incomplete", result.dig("verification", "status")
    assert_match(/artifact pair is incomplete/, result.dig("verification", "errors").join)
    assert_equal 1, result["exit_code"]
  end

  def test_file_changes_during_execution_are_inconclusive
    File.write(File.join(@root, "spec/a_spec.rb"), "RSpec.describe('a') { it('changes') { File.write('service.rb', 'different') } }\n")
    result, output, = run_verify
    assert_equal "incomplete", result["outcome"], output
    assert_includes result.dig("verification", "errors"), "Project files changed during verification."
  end

  def test_suite_errors_and_worker_validation_fail_closed
    File.write(File.join(@root, "spec/a_spec.rb"), "RSpec.configure { |c| c.after(:suite) { raise 'bad' } }; RSpec.describe('a') { it('passes') {} }\n")
    result, = run_verify
    assert_equal "incomplete", result["outcome"]
    assert_equal "incomplete", result.dig("verification", "status")
    assert_includes result.dig("verification", "errors"), "RSpec reports were incomplete."
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, verify: true, workers: 2) }
  end

  def test_cli_exposes_verification
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "run", "--verify", chdir: @root)
    assert_equal 1, status.exitstatus, output
    assert_match(/Shadow verification: observed_misses/, output)
    assert_match(/spec\/b_spec.rb/, output)
  end
end
