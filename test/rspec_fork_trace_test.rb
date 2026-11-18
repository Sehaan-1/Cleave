# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "json"

class RSpecForkTraceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-fork-trace")
    FileUtils.mkdir_p(File.join(@root, "spec"))
    project = File.expand_path("..", __dir__)
    write("Gemfile", "source 'https://rubygems.org'\ngem 'cleave-ste', path: #{project.inspect}\ngem 'rspec', '~> 3.13'\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "lock", "--local", chdir: @root)
    raise output unless status.success?
    assert system("git", "-C", @root, "init", "-q")
    write(".gitignore", ".cleave/\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write(path, data)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, data)
  end

  def test_forks_are_collected_best_effort_and_indexed_by_inherited_scope
    skip "fork is unavailable" unless Process.respond_to?(:fork)
    %w[root child nested thread no_block parent hidden].each { |name| write("#{name}.json", "{}") }
    write(".git/config", "private")
    write("spec/fork_spec.rb", <<~RUBY)
      RSpec.describe('fork observations') do
        before(:context) do
          pid = fork { File.read('root.json') }
          Process.wait(pid)
        end
        it('collects child and nested fork') do
          File.read('parent.json')
          pid = Process.fork do
            File.read('child.json')
            File.read('.git/config')
            Thread.new { File.read('thread.json') }.join
            nested = Process.fork { File.read('nested.json') }
            Process.wait(nested)
          end
          Process.wait(pid)
        end
        it('collects a fork without a block') do
          pid = Process.fork
          if pid
            Process.wait(pid)
          else
            File.read('no_block.json')
            exit 0
          end
        end
        it('cannot collect exit bang') do
          pid = fork { File.read('hidden.json'); exit! 0 }
          Process.wait(pid)
        end
      end
    RUBY
    output = StringIO.new
    result = Cleave::RSpecRunner.run(root: @root, trace: true, trace_forks: true, index: true, output: output)
    assert_equal "passed", result["outcome"], "#{result.inspect}\\n#{output.string}"
    assert_equal 3, result["example_count"]
    assert_equal 4, result.dig("trace", "fork_reports")
    refute result.dig("trace", "complete")
    capture = JSON.parse(File.read(File.join(@root, ".cleave/last_trace.json")))
    events = capture.fetch("report").fetch("events")
    expected = { "root.json" => "r", "child.json" => "spec/fork_spec.rb", "nested.json" => "spec/fork_spec.rb",
                 "no_block.json" => "spec/fork_spec.rb", "thread.json" => "r", "parent.json" => "spec/fork_spec.rb" }
    expected.each do |path, scope|
      assert_includes events, { "scope" => scope, "path" => path, "kind" => "io_read", "status" => "success" }
    end
    refute events.any? { |event| event["path"] == "hidden.json" || event["path"].start_with?(".git/") || event["path"].start_with?(".cleave/") }
    assert capture.dig("report", "limitations").any? { |s| s.include?("Fork observations are best effort") }
    inventory, index = Cleave::Artifacts.read(File.join(@root, ".cleave"))
    assert_equal 1, index.masks.fetch("child.json")
    assert_equal 1, index.masks.fetch("nested.json")
    assert_equal 1, index.masks.fetch("no_block.json")
    assert_includes index.root_paths, "root.json"
    assert_includes index.root_paths, "thread.json"
    refute index.masks.key?("hidden.json")
    assert inventory.files.key?("hidden.json")
    refute index.to_h.fetch("complete")
  end

  def test_default_trace_does_not_enable_forks_even_if_environment_is_set
    write("child.json", "{}")
    write("spec/fork_spec.rb", "RSpec.describe('fork') { it('forks') { pid = fork { File.read('child.json') }; Process.wait(pid) } }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false", "CLEAVE_TRACE_FORK_DIRECTORY" => @root }
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "run", "--trace", chdir: @root)
    assert status.success?, output
    report = JSON.parse(File.read(File.join(@root, ".cleave/last_trace.json")))
    refute report.dig("report", "events").any? { |event| event["path"] == "child.json" }
    refute Dir.children(@root).any? { |name| name.match?(/\\A[0-9]+-[0-9a-f]+\\.json\\z/) }
  end

  def test_cli_and_combinations
    write("spec/example_spec.rb", "RSpec.describe('ok') { it('passes') {} }\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "run", "--trace", "--trace-forks", chdir: @root)
    assert status.success?, output
    assert_match(/Fork reports: 0 \(best effort; child coverage unverified\)/, output)
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, trace_forks: true) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, trace: true, trace_forks: true, workers: 2) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, trace: true, trace_forks: true, verify: true) }
  end

  def test_fork_report_reader_validates_identity_content_and_symlinks
    root = File.realpath(@root)
    parent = Cleave::TraceReport.new(root: root, pid: 111, events: [["r", "root.json", "io_read", "attempt"]], limitations: ["parent incomplete"])
    directory = File.join(@root, "child_reports")
    Dir.mkdir(directory)
    child = Cleave::TraceReport.new(root: root, pid: 222, events: [["spec/a_spec.rb", "child.json", "io_read", "success"]], limitations: ["child incomplete"])
    path = File.join(directory, "222-0123456789abcdef.json")
    File.write(path, JSON.generate("report" => child.to_h))
    merged, count = Cleave::TraceCapture.merge_forks(parent, directory, root: root)
    assert_equal 1, count
    assert_equal 111, merged.pid
    assert_includes merged.events, ["spec/a_spec.rb", "child.json", "io_read", "success"]
    assert_equal ["child incomplete", "parent incomplete"], merged.limitations
    File.write(path, JSON.generate("report" => child.to_h.merge("pid" => 333)))
    assert_match(/process mismatch/, assert_raises(Cleave::ArtifactError) { Cleave::TraceCapture.merge_forks(parent, directory, root: root) }.message)
    File.delete(path)
    File.symlink(File.join(@root, "Gemfile"), path)
    assert_match(/symlink/, assert_raises(Cleave::ArtifactError) { Cleave::TraceCapture.merge_forks(parent, directory, root: root) }.message)
    File.delete(path)
    File.write(File.join(directory, "invalid.json"), "{}")
    assert_match(/filename/, assert_raises(Cleave::ArtifactError) { Cleave::TraceCapture.merge_forks(parent, directory, root: root) }.message)
  end
end
