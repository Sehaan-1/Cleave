# frozen_string_literal: true

require "json"
require "pathname"
require_relative "scoped_trace"
require_relative "artifacts"

module Cleave
  # Versioned process-local observations. They cannot authorize skipping tests.
  module TraceCapture
    module_function
    SCHEMA = "cleave.rspec_trace"
    VERSION = 1
    MAX_BYTES = 50 * 1024 * 1024
    MAX_FORK_REPORTS = 1024

    def read(path, root:)
      raise ArtifactError, "trace file must not be a symlink" if File.symlink?(path)
      bytes = File.binread(path, MAX_BYTES + 1)
      raise ArtifactError, "trace report exceeds 50 MiB" if bytes.bytesize > MAX_BYTES
      object = ArtifactValidation.parse(bytes)
      ArtifactValidation.keys!(object, %w[schema version status complete report], "trace capture")
      unless object["schema"] == SCHEMA && object["version"] == VERSION && object["status"] == "recorded" && object["complete"] == false
        raise ArtifactError, "trace capture is not a recorded v1 incomplete observation"
      end
      report_from_h(object["report"], root: root)
    end

    def report_from_h(data, root:, pid: nil)
      ArtifactValidation.keys!(data, %w[root pid events limitations complete], "trace report")
      raise ArtifactError, "trace root mismatch" unless data["root"] == File.realpath(root)
      # Windows runs batch launchers, so the traced interpreter pid differs
      # from the pid Process.spawn returned for the launcher.
      pid_matches = pid.nil? || data["pid"] == pid || Gem.win_platform?
      raise ArtifactError, "trace process mismatch" unless data["pid"].is_a?(Integer) && data["pid"].positive? && pid_matches
      raise ArtifactError, "trace cannot claim complete coverage" unless data["complete"] == false
      limitations = data["limitations"]
      ArtifactValidation.sorted_unique_strings!(limitations, "trace limitations")
      raise ArtifactError, "trace limitations are missing" if limitations.empty? || limitations.any?(&:empty?)
      events = data["events"]
      raise ArtifactError, "trace events must be an array" unless events.is_a?(Array)
      entries = events.map do |event|
        ArtifactValidation.keys!(event, %w[scope path kind status], "trace event")
        scope, path, kind, status = event.values_at("scope", "path", "kind", "status")
        ArtifactValidation.path(scope) unless scope == "r"
        unless path.is_a?(String) && path.valid_encoding? && !path.empty? && !path.include?("\0")
          raise ArtifactError, "invalid trace path"
        end
        ArtifactValidation.path(path) unless Pathname.new(path).absolute?
        raise ArtifactError, "invalid trace operation" unless %w[file_open io_read io_binread yaml_load_file require].include?(kind) && %w[attempt success].include?(status)
        [scope, path, kind, status]
      end
      raise ArtifactError, "duplicate or unsorted trace events" unless entries == entries.sort.uniq
      TraceReport.new(root: data["root"], pid: data["pid"], events: entries, limitations: limitations)
    end

    def collect(path, root:, pid:)
      content = File.binread(path, MAX_BYTES + 1)
      raise ArtifactError, "trace report exceeds 50 MiB" if content.bytesize > MAX_BYTES
      raw = ArtifactValidation.parse(content)
      ArtifactValidation.keys!(raw, %w[hook_installed report], "trace subprocess output")
      raise ArtifactError, "RSpec trace hook was not installed" unless raw["hook_installed"] == true
      report_from_h(raw["report"], root: root, pid: pid)
    rescue Errno::ENOENT => error
      raise ArtifactError, "missing trace subprocess output: #{error.message}"
    end

    # Read only atomically published child files observed after the parent exits.
    # This does not wait for or assert the existence of every forked process.
    def merge_forks(parent, directory, root:)
      raise ArtifactError, "fork report directory must be a real directory" if File.symlink?(directory) || !File.directory?(directory)
      names = Dir.children(directory).select { |name| name.end_with?(".json") }.sort
      raise ArtifactError, "too many fork reports" if names.length > MAX_FORK_REPORTS
      events = parent.events.dup
      limitations = parent.limitations.dup
      bytes_read = 0
      names.each do |name|
        match = name.match(/\A([1-9][0-9]*)-[0-9a-f]{16}\.json\z/)
        raise ArtifactError, "invalid fork report filename" unless match
        path = File.join(directory, name)
        raise ArtifactError, "fork report must not be a symlink" if File.symlink?(path)
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        # Windows File::NONBLOCK is 1, the write-only flag, so only OR it on POSIX.
        flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK) && !Gem.win_platform?
        content = File.open(path, flags) do |file|
          raise ArtifactError, "fork report must be a regular file" unless file.stat.file?
          file.read(MAX_BYTES + 1) || +""
        end
        bytes_read += content.bytesize
        raise ArtifactError, "fork reports exceed 50 MiB" if bytes_read > MAX_BYTES
        raw = ArtifactValidation.parse(content)
        ArtifactValidation.keys!(raw, %w[report], "fork subprocess output")
        child = report_from_h(raw["report"], root: root, pid: match[1].to_i)
        raise ArtifactError, "fork report cannot use parent process ID" if child.pid == parent.pid
        events.concat(child.events)
        limitations.concat(child.limitations)
      end
      merged = TraceReport.new(root: parent.root, pid: parent.pid, events: events.sort.uniq, limitations: limitations.uniq.sort)
      raise ArtifactError, "merged trace exceeds 50 MiB" if JSON.generate(recorded(merged)).bytesize > MAX_BYTES
      [merged, names.length]
    rescue Errno::ENOENT => error
      raise ArtifactError, "fork report disappeared: #{error.message}"
    end

    def recorded(report)
      { "schema" => SCHEMA, "version" => VERSION, "status" => "recorded", "complete" => false, "report" => report.to_h }
    end

    def incomplete(status)
      { "schema" => SCHEMA, "version" => VERSION, "status" => status, "complete" => false, "report" => nil }
    end
  end
end
