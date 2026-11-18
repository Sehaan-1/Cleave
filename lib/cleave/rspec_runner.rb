# typed: false
# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"
require "tempfile"
require "set"
require_relative "artifacts"

module Cleave
  class RunnerError < StandardError; end

  # Runs the configured RSpec suite only. Never consumes a bitmap preview.
  module RSpecRunner
    module_function
    STATUS_SCHEMA = "cleave.rspec_run"
    STATUS_VERSION = 1
    MAX_WORKERS = 32

    def run(root:, workers: 1, output: $stdout)
      raise ArgumentError, "workers must be an integer from 1 to #{MAX_WORKERS}" unless workers.is_a?(Integer) && workers.between?(1, MAX_WORKERS)
      root = File.realpath(root)
      raise ArgumentError, "not a directory: #{root}" unless File.directory?(root)
      raise RunnerError, "project Gemfile not found in #{root}" unless File.file?(File.join(root, "Gemfile"))
      state_dir = File.join(root, ".cleave")
      raise RunnerError, ".cleave must not be a symlink" if File.symlink?(state_dir)
      FileUtils.mkdir_p(state_dir)
      raise RunnerError, ".cleave must not be a symlink" if File.symlink?(state_dir)
      lock_path = File.join(state_dir, "runner.lock")
      status_path = File.join(state_dir, "last_run.json")
      raise RunnerError, "runner files must not be symlinks" if File.symlink?(lock_path) || File.symlink?(status_path)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise RunnerError, "another Cleave run is active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        execute(root, state_dir, status_path, workers, output)
      ensure
        lock.flock(File::LOCK_UN) if lock
      end
    end

    def execute(root, state_dir, status_path, workers, output)
      state = { "schema" => STATUS_SCHEMA, "version" => STATUS_VERSION, "outcome" => "running",
                "requested_workers" => workers, "actual_workers" => 0, "exit_code" => nil,
                "observed_failed_specs" => [], "reports_complete" => false, "suite_coverage_verified" => false,
                "example_count" => 0, "errors" => [] }
      write_state(status_path, state)
      children = []
      begin
        Dir.mktmpdir("rspec-run-", state_dir) do |temp|
          files = workers > 1 ? discover(root, temp, output, children) : nil
          before = files && Inventory.capture(root: root, paths: files)
          raise RunnerError, "Discovered spec files are missing." if files && before.files.keys != files
          groups = if files.nil? || files.empty?
            [nil]
          else
            count = [workers, files.length].min
            files.each_with_index.each_with_object(Array.new(count) { [] }) { |(path, id), groups| groups[id % count] << path }
          end
          state["actual_workers"] = groups.length
          jobs = groups.each_with_index.map do |group, i|
            json = File.join(temp, "worker-#{i}.json")
            log = File.join(temp, "worker-#{i}.log")
            command = ["bundle", "exec", "rspec", "--format", "progress", "--format", "json", "--out", json]
            # RSpec can append cwd to explicit paths when a configured pattern
            # starts with a directory (e.g. spec/**/*_spec.rb). A **-prefixed
            # pattern disables that expansion; the discovered files remain authoritative.
            command += ["--pattern", "**/*", "--", *group] if group
            [spawn_job(root, command, log, children), json, log, group]
          end
          # Processes have already started concurrently; wait only for our own children.
          seen_examples = Set.new
          jobs.each do |pid, json, log, group|
            _, status = Process.wait2(pid)
            children.delete(pid)
            stream_log(log, output, groups.length > 1 ? "worker #{jobs.index { |item| item[0] == pid } + 1}" : nil)
            parse_report(root, json, status, group, state, seen_examples)
          end
          if files
            after = Inventory.capture(root: root, paths: files)
            state["errors"] << "Spec files changed during the parallel run." unless after.fingerprint == before.fingerprint
          end
          state["errors"] << "No RSpec examples were reported." if state["example_count"] == 0
          state["observed_failed_specs"] = state["observed_failed_specs"].uniq.sort
          state["reports_complete"] = state["errors"].empty?
          state["outcome"] = if !state["reports_complete"]
            "incomplete"
          elsif state["observed_failed_specs"].empty?
            "passed"
          else
            "failed"
          end
          state["exit_code"] = state["outcome"] == "passed" ? 0 : 1
        end
      rescue Interrupt
        terminate(children)
        state["outcome"] = "incomplete"
        state["exit_code"] = 130
        state["errors"] << "Run interrupted."
        write_state(status_path, state)
        raise
      rescue StandardError => error
        terminate(children)
        state["outcome"] = "incomplete"
        state["exit_code"] = 1
        state["errors"] << "#{error.class}: #{error.message}"
      ensure
        terminate(children)
      end
      state["observed_failed_specs"] = state["observed_failed_specs"].uniq.sort
      write_state(status_path, state)
      state
    end
    private_class_method :execute

    def discover(root, temp, output, children)
      json = File.join(temp, "manifest.json")
      log = File.join(temp, "discovery.log")
      formatter = File.expand_path("rspec_manifest_formatter.rb", __dir__)
      command = ["bundle", "exec", "rspec", "--dry-run", "--require", formatter,
                 "--format", "Cleave::RSpecManifestFormatter", "--out", json]
      pid = spawn_job(root, command, log, children)
      _, status = Process.wait2(pid)
      children.delete(pid)
      unless status.success?
        stream_log(log, output, "discovery")
        raise RunnerError, "RSpec discovery failed (#{status.exitstatus || 'signal'})."
      end
      manifest = JSON.parse(File.binread(json))
      raise RunnerError, "invalid RSpec discovery manifest" unless manifest.is_a?(Hash) && manifest.keys == ["files"] && manifest["files"].is_a?(Array)
      files = manifest["files"].map { |path| relative_path(root, path) }
      raise RunnerError, "duplicate RSpec discovery paths" unless files.uniq.length == files.length
      if files.any? { |path| path.match?(/[\[\]:]/) }
        raise RunnerError, "RSpec selector characters in filenames are unsupported in parallel mode; run serially."
      end
      files.sort
    rescue JSON::ParserError, Errno::ENOENT => error
      raise RunnerError, "invalid RSpec discovery output: #{error.message}"
    end
    private_class_method :discover

    def spawn_job(root, command, log, children)
      File.open(log, "wb") do |file|
        pid = Process.spawn({ "BUNDLE_GEMFILE" => File.join(root, "Gemfile") }, *command,
                            chdir: root, out: file, err: [:child, :out], pgroup: true)
        children << pid
        pid
      end
    end
    private_class_method :spawn_job

    def stream_log(path, output, label)
      output.puts("\n--- #{label} ---") if label
      File.open(path, "rb") do |file|
        while (chunk = file.read(64 * 1024))
          output.write(chunk)
        end
      end
      output.flush
    end
    private_class_method :stream_log

    def parse_report(root, path, status, group, state, seen_examples)
      data = JSON.parse(File.binread(path))
      summary = data.fetch("summary")
      examples = data.fetch("examples")
      raise RunnerError, "invalid RSpec report" unless summary.is_a?(Hash) && examples.is_a?(Array)
      total = summary.fetch("example_count")
      failed = summary.fetch("failure_count")
      outside = summary.fetch("errors_outside_of_examples_count", 0)
      unless [total, failed, outside].all? { |n| n.is_a?(Integer) && n >= 0 } && total == examples.length
        raise RunnerError, "inconsistent RSpec report counts"
      end
      failures = []
      examples.each do |example|
        unless example.is_a?(Hash) && %w[passed failed pending].include?(example["status"]) && example["id"].is_a?(String) && !example["id"].empty?
          raise RunnerError, "invalid RSpec example"
        end
        spec = relative_path(root, example.fetch("file_path"))
        raise RunnerError, "example outside assigned worker files: #{spec}" if group && !group.include?(spec)
        raise RunnerError, "duplicate RSpec example: #{example['id']}" unless seen_examples.add?(example["id"])
        failures << spec if example["status"] == "failed"
      end
      raise RunnerError, "inconsistent RSpec failure count" unless failures.length == failed
      state["observed_failed_specs"].concat(failures)
      state["example_count"] += total
      state["errors"] << "RSpec reported #{outside} error(s) outside examples." if outside.positive?
      if !status.exited? || (status.success? && (failed.positive? || outside.positive?)) || (!status.success? && failed.zero? && outside.zero?)
        state["errors"] << "RSpec exited without a consistent example result (#{status.exitstatus || 'signal'})."
      end
    rescue JSON::ParserError, KeyError, Errno::ENOENT => error
      raise RunnerError, "invalid or missing RSpec report: #{error.message}"
    end
    private_class_method :parse_report

    def relative_path(root, path)
      raise RunnerError, "RSpec returned a non-string path" unless path.is_a?(String) && !path.empty? && !path.include?("\0")
      absolute = File.expand_path(path, root)
      prefix = root.end_with?(File::SEPARATOR) ? root : root + File::SEPARATOR
      raise RunnerError, "RSpec path outside project root: #{path}" unless absolute.start_with?(prefix)
      ArtifactValidation.path(absolute.delete_prefix(prefix))
    end
    private_class_method :relative_path

    def terminate(children)
      groups = children.dup
      groups.each { |pid| Process.kill("TERM", -pid) rescue nil }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      pending = groups.dup
      loop do
        pending.delete_if do |pid|
          begin
            !!Process.waitpid(pid, Process::WNOHANG)
          rescue Errno::ECHILD
            true
          end
        end
        alive = groups.any? do |pid|
          begin
            Process.kill(0, -pid)
            true
          rescue Errno::ESRCH
            false
          rescue Errno::EPERM
            true
          end
        end
        break if (!alive && pending.empty?) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.02
      end
      groups.each { |pid| Process.kill("KILL", -pid) rescue nil }
      pending.each { |pid| Process.wait(pid) rescue nil }
      children.clear
    end
    private_class_method :terminate

    def write_state(path, data)
      raise RunnerError, "status file must not be a symlink" if File.symlink?(path)
      Tempfile.create([".rspec-status-", ".tmp"], File.dirname(path)) do |file|
        file.write(JSON.pretty_generate(data) + "\n")
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end
    private_class_method :write_state
  end
end
