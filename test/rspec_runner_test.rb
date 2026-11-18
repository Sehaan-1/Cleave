# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"
require "open3"
require "timeout"

class RSpecRunnerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-rspec")
    FileUtils.mkdir_p(File.join(@root, "spec"))
    project = File.expand_path("..", __dir__)
    File.write(File.join(@root, "Gemfile"), "source 'https://rubygems.org'\ngem 'cleave-ste', path: #{project.inspect}\ngem 'rspec', '~> 3.13'\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "lock", "--local", chdir: @root)
    raise "bundle lock failed: #{output}" unless status.success?
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def spec(name, source)
    File.write(File.join(@root, "spec", name), source)
  end

  def run_suite(workers: 1)
    output = StringIO.new
    result = Cleave::RSpecRunner.run(root: @root, workers: workers, output: output)
    [result, output.string, JSON.parse(File.read(File.join(@root, ".cleave/last_run.json")))]
  end

  def test_serial_full_suite_runs_and_persists_success
    spec("a_spec.rb", "RSpec.describe('a') { it('works') { expect(2 + 2).to eq(4) } }\n")
    spec("b_spec.rb", "RSpec.describe('b') { it('works') { expect(true).to be(true) } }\n")
    result, output, persisted = run_suite
    assert_equal "passed", result["outcome"]
    assert_equal 0, result["exit_code"]
    assert_equal 2, result["example_count"]
    assert_equal 1, result["actual_workers"]
    assert_equal true, result["reports_complete"]
    assert_equal false, result["suite_coverage_verified"]
    assert_empty result["observed_failed_specs"]
    assert_match(/2 examples/, output)
    assert_equal result, persisted
  end

  def test_parallel_runs_all_discovered_files_and_records_failures
    File.write(File.join(@root, ".rspec"), "--pattern spec/**/*_check.rb\n")
    spec("a_check.rb", "RSpec.describe('a') { it('passes') { expect(1).to eq(1) } }\n")
    spec("space name_check.rb", "RSpec.describe('b') { it('fails') { expect(1).to eq(2) } }\n")
    spec("ignored_spec.rb", "raise 'must not be loaded by this configured pattern'\n")
    result, output, persisted = run_suite(workers: 2)
    assert_equal "failed", result["outcome"]
    assert_equal 1, result["exit_code"]
    assert_equal 2, result["actual_workers"]
    assert_equal 2, result["example_count"]
    assert_equal ["spec/space name_check.rb"], result["observed_failed_specs"]
    assert result["reports_complete"]
    refute result["suite_coverage_verified"]
    assert_match(/worker 1/, output)
    assert_equal result, persisted
  end

  def test_failing_discovery_and_zero_examples_fail_closed
    spec("broken_spec.rb", "class InvalidRuby\n")
    result, _, persisted = run_suite(workers: 2)
    assert_equal "incomplete", result["outcome"]
    assert_equal 1, result["exit_code"]
    refute result["reports_complete"]
    assert_match(/discovery failed/, result["errors"].join)
    assert_equal result, persisted
    File.delete(File.join(@root, "spec/broken_spec.rb"))
    result, = run_suite
    assert_equal "incomplete", result["outcome"]
    assert_includes result["errors"], "No RSpec examples were reported."
  end

  def test_worker_crash_does_not_leave_a_false_success_or_old_failure_record
    spec("a_spec.rb", "RSpec.describe('crash') { it('exits') { exit! 7 } }\n")
    result, _, persisted = run_suite
    assert_equal "incomplete", result["outcome"]
    assert_equal 1, result["exit_code"]
    refute result["reports_complete"]
    assert_equal result, persisted
  end

  def test_cli_exit_code_and_packaged_executable
    spec("a_spec.rb", "RSpec.describe('failure') { it('fails') { expect(1).to eq(2) } }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "--workers", "2", chdir: @root)
    assert_equal 1, status.exitstatus, output
    assert_match(/Cleave: failed/, output)
    record = JSON.parse(File.read(File.join(@root, ".cleave/last_run.json")))
    assert_equal ["spec/a_spec.rb"], record["observed_failed_specs"]
  end

  def test_reject_invalid_worker_counts_and_status_directory_symlink
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, workers: 0) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, workers: 33) }
    Dir.mktmpdir do |outside|
      File.symlink(outside, File.join(@root, ".cleave"))
      assert_raises(Cleave::RunnerError) { Cleave::RSpecRunner.run(root: @root) }
    end
  end

  def test_interrupt_terminates_workers_and_persists_incomplete_status
    spec("a_spec.rb", "RSpec.describe('slow') { it('waits') { File.write('started', 'yes'); sleep 60 } }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    pid = Process.spawn(env, "bundle", "exec", "cleave", chdir: @root, out: File::NULL, err: File::NULL)
    begin
      Timeout.timeout(30) { sleep 0.05 until File.exist?(File.join(@root, "started")) }
      Process.kill("INT", pid)
      _, status = Timeout.timeout(10) { Process.wait2(pid) }
      pid = nil
      assert_equal 130, status.exitstatus
      record = JSON.parse(File.read(File.join(@root, ".cleave/last_run.json")))
      assert_equal "incomplete", record["outcome"]
      assert_includes record["errors"], "Run interrupted."
      refute record["suite_coverage_verified"]
    ensure
      if pid
        Process.kill("KILL", pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end
end
