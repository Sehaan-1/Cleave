# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "json"
require "timeout"

class RSpecTraceCaptureTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-traced-rspec")
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

  def write(path, text)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def run_trace
    output = StringIO.new
    result = Cleave::RSpecRunner.run(root: @root, trace: true, output: output)
    [result, output.string, JSON.parse(File.read(File.join(@root, ".cleave/last_trace.json")))]
  end

  def test_full_suite_captures_root_and_example_scopes_without_skipping
    %w[boot a b hook thread].each { |name| write("#{name}.json", "{}") }
    write("spec/spec_helper.rb", "File.read('boot.json')\n")
    write(".rspec", "--require ./spec/spec_helper.rb\n")
    write("spec/a_spec.rb", <<~RUBY)
      RSpec.describe('a') do
        before(:example) { File.read('hook.json') }
        it('reads') do
          File.read('a.json')
          Thread.new { File.read('thread.json') }.join
          begin; File.read('missing.json'); rescue Errno::ENOENT; end
          expect(true).to be(true)
        end
      end
    RUBY
    write("spec/b_spec.rb", "RSpec.describe('b') { it('reads') { File.read('b.json'); expect(true).to be(true) } }\n")
    result, output, capture = run_trace
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_equal "recorded", capture["status"]
    assert_equal false, capture["complete"]
    events = capture.fetch("report").fetch("events")
    expected = [
      { "scope" => "r", "path" => "boot.json", "kind" => "io_read", "status" => "success" },
      { "scope" => "r", "path" => "thread.json", "kind" => "io_read", "status" => "success" },
      { "scope" => "spec/a_spec.rb", "path" => "a.json", "kind" => "io_read", "status" => "success" },
      { "scope" => "spec/a_spec.rb", "path" => "hook.json", "kind" => "io_read", "status" => "success" },
      { "scope" => "spec/a_spec.rb", "path" => "missing.json", "kind" => "io_read", "status" => "attempt" },
      { "scope" => "spec/b_spec.rb", "path" => "b.json", "kind" => "io_read", "status" => "success" }
    ]
    expected.each { |item| assert_includes events, item }
    refute events.any? { |event| event["path"].start_with?(".cleave/") }
    assert_equal events.length, result.dig("trace", "event_count")
    refute result.dig("trace", "complete")
    report = Cleave::TraceCapture.read(File.join(@root, ".cleave/last_trace.json"), root: @root)
    assert_equal capture.fetch("report"), report.to_h
    assert report.limitations.any? { |message| message.include?("child") || message.include?("Child") }
  end

  def test_failed_example_is_still_reported_but_nonzero
    write("spec/failure_spec.rb", "RSpec.describe('failure') { it('fails') { expect(1).to eq(2) } }\n")
    result, output, capture = run_trace
    assert_equal "failed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 1, result["exit_code"]
    assert_equal "recorded", capture["status"]
    assert_equal ["spec/failure_spec.rb"], result["observed_failed_specs"]
  end

  def test_crash_replaces_prior_report_with_incomplete_record
    write("spec/crash_spec.rb", "RSpec.describe('crash') { it('exits') { exit! 7 } }\n")
    write(".cleave/last_trace.json", '{"status":"recorded","report":"old"}')
    result, _, capture = run_trace
    assert_equal "incomplete", result["outcome"]
    assert_equal "incomplete", capture["status"]
    assert_nil capture["report"]
    assert_raises(Cleave::ArtifactError) { Cleave::TraceCapture.read(File.join(@root, ".cleave/last_trace.json"), root: @root) }
  end

  def test_cli_trace_and_invalid_combinations
    write("spec/example_spec.rb", "RSpec.describe('ok') { it('passes') { expect(true).to be(true) } }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "run", "--trace", chdir: @root)
    assert status.success?, output
    assert_match(/Trace: recorded · incomplete observations only/, output)
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, trace: true, workers: 2) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, trace: true, verify: true) }
  end

  def test_interrupt_invalidates_last_trace
    write("spec/slow_spec.rb", "RSpec.describe('slow') { it('waits') { File.write('started', 'yes'); sleep 60 } }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    pid = Process.spawn(env, "bundle", "exec", "cleave", "run", "--trace", chdir: @root, out: File::NULL, err: File::NULL)
    begin
      Timeout.timeout(30) { sleep 0.05 until File.exist?(File.join(@root, "started")) }
      assert_equal "running", JSON.parse(File.read(File.join(@root, ".cleave/last_trace.json")))["status"]
      Process.kill("INT", pid)
      _, status = Timeout.timeout(10) { Process.wait2(pid) }
      pid = nil
      assert_equal 130, status.exitstatus
      capture = JSON.parse(File.read(File.join(@root, ".cleave/last_trace.json")))
      assert_equal "incomplete", capture["status"]
      assert_nil capture["report"]
    ensure
      if pid
        Process.kill("KILL", pid) rescue nil
        Process.wait(pid) rescue nil
      end
    end
  end
end
