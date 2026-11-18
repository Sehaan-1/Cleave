# typed: false
# frozen_string_literal: true

require "thread"
require "set"
require "pathname"
require "rbconfig"
require "yaml"

module Cleave
  # A snapshot is a set of observed Ruby-level operations, not a complete dependency index.
  class TraceReport
    attr_reader :root, :pid, :events, :limitations

    def initialize(root:, pid:, events:, limitations:)
      @root = root.dup.freeze
      @pid = pid
      @events = events.map { |event| event.map { |v| v.is_a?(String) ? v.dup.freeze : v }.freeze }.freeze
      @limitations = limitations.map { |item| item.dup.freeze }.freeze
      freeze
    end

    def to_h
      { "root" => root, "pid" => pid, "events" => events.map { |scope, path, kind, status|
        { "scope" => scope, "path" => path, "kind" => kind, "status" => status }
      }, "limitations" => limitations, "complete" => false }
    end
  end

  # Hooks are process-wide, scopes are fiber-local. A missing scope is conservatively root.
  class ScopedTrace
    ROOT_SCOPE = "r"
    SCOPE_KEY = :__cleave_trace_scope_stack
    GUARD_KEY = :__cleave_trace_recording
    LIMITATIONS = [
      "Ruby hooks do not capture all native, subprocess, directory, or direct syscall access.",
      "Child processes require separate report collection; threads and fibers must be explicitly scoped.",
      "Loading before tracing and unobserved test execution make the trace incomplete."
    ].freeze
    @lifecycle_lock = Mutex.new
    @active = nil
    @installed = false

    class << self
      attr_reader :active

      def start(root:)
        absolute = File.realpath(root)
        raise ArgumentError, "not a directory: #{root}" unless File.directory?(absolute)
        @lifecycle_lock.synchronize do
          raise "a Cleave trace is already active" if @active
          install_hooks unless @installed
          @active = new(absolute)
        end
      end

      def stop(trace)
        @lifecycle_lock.synchronize do
          raise "trace is not active" unless @active.equal?(trace)
          @active = nil
        end
      end

      private

      def install_hooks
        File.singleton_class.prepend(FileOpenHook)
        IO.singleton_class.prepend(IOReadHook)
        Kernel.prepend(RequireHook)
        Kernel.singleton_class.prepend(PublicRequireHook)
        Psych.singleton_class.prepend(YamlHook)
        @installed = true
      end
    end

    attr_reader :root

    def initialize(root)
      @root = root.freeze
      @owner_pid = Process.pid
      @mutex = Mutex.new
      @events = Set.new
      @limitations = Set.new(LIMITATIONS)
    end

    def stop
      self.class.stop(self)
      report
    end

    # Scopes nest and are restored even if a test raises. They are not implicitly
    # propagated to new threads or fibers: instrument their entry points explicitly.
    def with_spec(path)
      raise ArgumentError, "spec path must be a non-empty string other than r" unless path.is_a?(String) && !path.empty? && path != ROOT_SCOPE
      raise "trace is not active" unless self.class.active.equal?(self)
      stack = (Thread.current[SCOPE_KEY] ||= [])
      stack.push([self, path.dup.freeze])
      begin
        yield
      ensure
        stack.pop
        Thread.current[SCOPE_KEY] = nil if stack.empty?
      end
    end

    def report
      @mutex.synchronize do
        TraceReport.new(root: root, pid: Process.pid, events: @events.to_a.sort, limitations: @limitations.to_a.sort)
      end
    end

    # Called by hooks; logging must not alter application exceptions or return values.
    def observe(path, kind, status)
      return if Thread.current[GUARD_KEY]
      Thread.current[GUARD_KEY] = true
      begin
        path = path.to_path if path.is_a?(Pathname)
        unless path.is_a?(String) && !path.start_with?("|") && !path.empty?
          limitation("Unresolved non-path or pipe argument to #{kind}.")
          return
        end
        absolute = File.expand_path(path)
        prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
        relative = absolute.start_with?(prefix) ? absolute.delete_prefix(prefix) : absolute
        frame = Thread.current[SCOPE_KEY]&.reverse_each&.find { |session, _| session.equal?(self) }
        scope = frame ? frame.last : ROOT_SCOPE
        @mutex.synchronize do
          @events.add([scope, relative.freeze, kind, status].freeze)
          @limitations.add("A forked child report must be collected separately.") if Process.pid != @owner_pid
        end
      rescue StandardError => error
        limitation("Unable to record #{kind}: #{error.class}.")
      ensure
        Thread.current[GUARD_KEY] = nil
      end
    end

    def limitation(message)
      @mutex.synchronize { @limitations.add(message) }
    end

    # Match the requested feature to already-loaded paths, so cached requires
    # are attributed without mistakenly assigning unrelated nested requires.
    def observe_require(feature)
      return if Thread.current[GUARD_KEY]
      Thread.current[GUARD_KEY] = true
      begin
        unless feature.is_a?(String) && !feature.empty?
          limitation("Unresolved non-string require argument.")
          return
        end
        bases = if Pathname.new(feature).absolute? || feature.start_with?("./", "../")
          [File.expand_path(feature)]
        else
          $LOAD_PATH.map { |entry| File.expand_path(feature, entry) }
        end
        extensions = ["", ".rb", ".#{RbConfig::CONFIG.fetch('DLEXT', 'so')}", ".so"].uniq
        candidates = bases.flat_map { |base| extensions.map { |suffix| base + suffix } }.to_set
        loaded = $LOADED_FEATURES.filter_map do |entry|
          next unless entry.is_a?(String)
          expanded = File.expand_path(entry)
          expanded if candidates.include?(expanded)
        end
        if loaded.empty?
          limitation("A require could not be resolved to a loaded file: #{feature}.")
        else
          # Record outside the guard so observe can normalize and attribute it.
          Thread.current[GUARD_KEY] = nil
          loaded.each { |path| observe(path, "require", "success") }
        end
      rescue StandardError => error
        limitation("Unable to resolve require: #{error.class}.")
      ensure
        Thread.current[GUARD_KEY] = nil
      end
    end
  end

  module FileOpenHook
    def open(path, *args, **kwargs, &block)
      trace = ScopedTrace.active
      return super unless trace
      trace.observe(path, "file_open", "attempt")
      if block
        super(path, *args, **kwargs) do |file|
          trace&.observe(path, "file_open", "success")
          block.call(file)
        end
      else
        file = super(path, *args, **kwargs)
        trace&.observe(path, "file_open", "success")
        file
      end
    end
  end

  module IOReadHook
    def read(path, *args, **kwargs)
      trace = ScopedTrace.active
      trace&.observe(path, "io_read", "attempt")
      result = super
      trace&.observe(path, "io_read", "success")
      result
    end

    def binread(path, *args, **kwargs)
      trace = ScopedTrace.active
      trace&.observe(path, "io_binread", "attempt")
      result = super
      trace&.observe(path, "io_binread", "success")
      result
    end
  end

  module RequireHook
    def require(feature)
      trace = ScopedTrace.active
      result = super
      trace&.observe_require(feature)
      result
    end
    private :require
  end

  module PublicRequireHook
    def require(feature)
      trace = ScopedTrace.active
      result = super
      trace&.observe_require(feature)
      result
    end
  end

  module YamlHook
    def load_file(path, *args, **kwargs)
      trace = ScopedTrace.active
      trace&.observe(path, "yaml_load_file", "attempt")
      result = super
      trace&.observe(path, "yaml_load_file", "success")
      result
    end
  end
end
