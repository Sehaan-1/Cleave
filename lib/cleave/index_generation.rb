# frozen_string_literal: true

require_relative "shadow_verification"
require_relative "trace_capture"

module Cleave
  # Builds a diagnostic index from the same run whose project snapshots surround it.
  module IndexGeneration
    module_function

    LIMITATIONS = [
      "The inventory covers Git tracked and non-ignored files and explicit includes, not all project or external files.",
      "Snapshots are not transactional and cannot detect changes reverted during the run.",
      "RSpec reported spec files are observations, not a verified complete suite."
    ].freeze

    def prepare(root:, includes:)
      raise ArtifactError, "includes must be an array" unless includes.is_a?(Array)
      paths = includes.map { |path| ArtifactValidation.path(path) }.uniq.sort
      if paths.any? { |path| path == ".cleave" || path.start_with?(".cleave/") }
        raise ArtifactError, "cannot include Cleave state"
      end
      stdout, stderr, status = Open3.capture3("git", "-C", root, "rev-parse", "--show-toplevel")
      raise ArtifactError, "git root unavailable: #{stderr.strip}" unless status.success?
      raise ArtifactError, "index generation requires the Git project root" unless File.realpath(stdout.strip) == root
      inventory = ShadowVerification.capture(root, paths)
      missing = paths - inventory.files.keys
      raise ArtifactError, "included files are missing: #{missing.join(', ')}" unless missing.empty?
      [inventory, paths]
    rescue Errno::ENOENT => error
      raise ArtifactError, "cannot access Git root: #{error.message}"
    end

    def finish(root:, directory:, before:, includes:, report:, specs:)
      after = ShadowVerification.capture(root, includes)
      raise ArtifactError, "project files changed during the traced run" unless before.fingerprint == after.fingerprint
      raise ArtifactError, "reported spec files absent from inventory; include ignored specs explicitly" unless (specs - before.files.keys).empty?
      enriched = TraceReport.new(root: report.root, pid: report.pid, events: report.events,
                                 limitations: (report.limitations + LIMITATIONS).uniq.sort)
      index = BitmapIndex.build(inventory: before, root: root, specs: specs, reports: [enriched])
      %w[inventory.json bitmap_index.json].each do |name|
        raise ArtifactError, "artifact output must not be a symlink: #{name}" if File.symlink?(File.join(directory, name))
      end
      Artifacts.write(directory, inventory: before, index: index)
      { "status" => "recorded", "complete" => false, "inventory_fingerprint" => before.fingerprint,
        "spec_count" => index.specs.length, "path_count" => index.masks.length }
    end
  end
end
