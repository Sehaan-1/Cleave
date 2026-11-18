# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "json"

class ScopedTraceTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-trace")
    File.write(File.join(@root, "data.yml"), "enabled: true\n")
    File.write(File.join(@root, "data.json"), '{"amount":1}')
    File.write(File.join(@root, "helper.rb"), "$cleave_trace_loads = ($cleave_trace_loads || 0) + 1\n")
    @trace = Cleave::ScopedTrace.start(root: @root)
  end

  def teardown
    @trace.stop if Cleave::ScopedTrace.active.equal?(@trace)
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def events
    @trace.report.to_h.fetch("events")
  end

  def observed?(scope, path, kind, status = "success")
    events.include?({ "scope" => scope, "path" => path, "kind" => kind, "status" => status })
  end

  def test_root_and_nested_scopes_record_operations_and_restore_after_exception
    File.open(File.join(@root, "data.json")) { |file| assert_equal '{"amount":1}', file.read }
    @trace.with_spec("spec/a_spec.rb") do
      assert_equal '{"amount":1}', IO.read(File.join(@root, "data.json"))
      assert_raises(RuntimeError) do
        @trace.with_spec("spec/nested_spec.rb") do
          assert_equal true, YAML.load_file(File.join(@root, "data.yml"))["enabled"]
          raise "spec failed"
        end
      end
      File.binread(File.join(@root, "data.json"))
    end
    File.read(File.join(@root, "data.yml"))
    assert observed?("r", "data.json", "file_open")
    assert observed?("spec/a_spec.rb", "data.json", "io_read")
    assert observed?("spec/a_spec.rb", "data.json", "io_binread")
    assert observed?("spec/nested_spec.rb", "data.yml", "yaml_load_file")
    assert observed?("r", "data.yml", "io_read")
    assert_equal false, @trace.report.to_h.fetch("complete")
  end

  def test_attempts_are_recorded_when_open_or_read_fails
    missing = File.join(@root, "missing.json")
    @trace.with_spec("spec/a_spec.rb") do
      assert_raises(Errno::ENOENT) { File.open(missing) }
      assert_raises(Errno::ENOENT) { IO.read(missing) }
    end
    assert observed?("spec/a_spec.rb", "missing.json", "file_open", "attempt")
    assert observed?("spec/a_spec.rb", "missing.json", "io_read", "attempt")
    refute observed?("spec/a_spec.rb", "missing.json", "file_open")
    refute observed?("spec/a_spec.rb", "missing.json", "io_read")
  end

  def test_require_and_cached_require_are_attributed_to_each_scope
    feature = File.join(@root, "helper")
    @trace.with_spec("spec/first_spec.rb") { assert require(feature) }
    @trace.with_spec("spec/second_spec.rb") { refute require(feature) }
    @trace.with_spec("spec/third_spec.rb") { refute Kernel.require(feature) }
    assert_equal 1, $cleave_trace_loads
    %w[first second third].each { |name| assert observed?("spec/#{name}_spec.rb", "helper.rb", "require") }
  ensure
    $LOADED_FEATURES.delete(File.join(@root, "helper.rb"))
    $cleave_trace_loads = nil
  end


  def test_load_path_requires_and_unresolved_require_failures
    feature = "cleave_trace_fixture_#{Process.pid}"
    path = File.join(@root, "#{feature}.rb")
    File.write(path, "$cleave_trace_fixture = true\n")
    $LOAD_PATH.unshift(@root)
    @trace.with_spec("spec/load_path_spec.rb") do
      assert require(feature)
      refute require(feature)
      assert_raises(LoadError) { require("#{feature}_missing") }
    end
    assert observed?("spec/load_path_spec.rb", "#{feature}.rb", "require")
  ensure
    $LOAD_PATH.delete(@root)
    $LOADED_FEATURES.delete(path)
    $cleave_trace_fixture = nil
  end

  def test_scopes_are_isolated_for_concurrent_threads_and_fibers
    threads = %w[a b].map do |name|
      Thread.new do
        @trace.with_spec("spec/#{name}_spec.rb") { 10.times { File.read(File.join(@root, "data.json")) } }
      end
    end
    threads.each(&:value)
    @trace.with_spec("spec/parent_spec.rb") do
      Fiber.new { File.read(File.join(@root, "data.yml")) }.resume
      Fiber.new { @trace.with_spec("spec/fiber_spec.rb") { File.read(File.join(@root, "data.yml")) } }.resume
    end
    %w[a b].each { |name| assert observed?("spec/#{name}_spec.rb", "data.json", "io_read") }
    assert observed?("r", "data.yml", "io_read")
    assert observed?("spec/fiber_spec.rb", "data.yml", "io_read")
    refute observed?("spec/parent_spec.rb", "data.yml", "io_read")
  end

  def test_transparent_file_open_and_session_lifecycle
    assert_raises(RuntimeError) { Cleave::ScopedTrace.start(root: @root) }
    assert_raises(ArgumentError) { @trace.with_spec("r") {} }
    path = File.join(@root, "data.json")
    assert_equal :block_result, File.open(path) { :block_result }
    assert_equal :stopped, File.open(path) { break :stopped }
    file = File.open(Pathname.new(path))
    assert_equal '{"amount":1}', file.read
    file.close
    assert_raises(ArgumentError) { File.open(path, "not-a-valid-mode") }
    snapshot = @trace.report
    assert snapshot.frozen?
    assert snapshot.events.frozen?
    before = snapshot.events.length
    @trace.stop
    File.read(path)
    assert_equal before, @trace.report.events.length
    assert_raises(RuntimeError) { @trace.with_spec("spec/no_spec.rb") {} }
    replacement = Cleave::ScopedTrace.start(root: @root)
    replacement.stop
  end


  def test_a_scope_from_a_stopped_session_does_not_leak_into_the_next
    @trace.with_spec("spec/old_spec.rb") do
      @trace.stop
      replacement = Cleave::ScopedTrace.start(root: @root)
      begin
        File.read(File.join(@root, "data.json"))
        data = replacement.report.to_h.fetch("events")
        assert_includes data, { "scope" => "r", "path" => "data.json", "kind" => "io_read", "status" => "success" }
      ensure
        replacement.stop
      end
    end
  end

  def test_filesystem_root_uses_relative_paths
    @trace.stop
    trace = Cleave::ScopedTrace.start(root: File::SEPARATOR)
    begin
      File.read(File.join(@root, "data.json"))
      event = trace.report.to_h.fetch("events").find { |e| e["kind"] == "io_read" && e["status"] == "success" }
      assert_equal File.join(@root, "data.json").delete_prefix(File::SEPARATOR), event.fetch("path")
    ensure
      trace.stop
    end
  end

  def test_child_report_must_be_collected_independently
    skip "fork is unavailable" unless Process.respond_to?(:fork)
    reader, writer = IO.pipe
    pid = nil
    @trace.with_spec("spec/fork_spec.rb") do
      pid = Process.fork do
        reader.close
        File.read(File.join(@root, "data.json"))
        writer.write(JSON.generate(@trace.report.to_h))
        writer.close
        exit! 0
      end
    end
    writer.close
    child = JSON.parse(reader.read)
    reader.close
    _, status = Process.wait2(pid)
    assert status.success?
    assert_equal pid, child.fetch("pid")
    assert_includes child.fetch("events"), { "scope" => "spec/fork_spec.rb", "path" => "data.json", "kind" => "io_read", "status" => "success" }
    assert_includes child.fetch("limitations"), "A forked child report must be collected separately."
    refute observed?("spec/fork_spec.rb", "data.json", "io_read")
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end
