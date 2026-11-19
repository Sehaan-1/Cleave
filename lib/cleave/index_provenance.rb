# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "tempfile"
require_relative "artifacts"

module Cleave
  # A local publication marker, not a signature or evidence of coverage.
  module IndexProvenance
    module_function
    SCHEMA = "cleave.index_provenance"
    VERSION = 1
    NAME = "index_provenance.json"
    MAX_BYTES = 64 * 1024
    MAX_ARTIFACT_BYTES = 10 * 1024 * 1024
    FIELDS = %w[schema version status complete generation_id inventory_fingerprint inventory_sha256 index_sha256 failed_examples suite_coverage_verified].freeze

    def begin_run(directory)
      id = SecureRandom.hex(16)
      write(directory, marker("running", id))
      id
    end

    def incomplete(directory, id)
      write(directory, marker("incomplete", id))
    end

    # Publish last, after both files have been replaced. Bind exact serialized
    # bytes, not just the common inventory fingerprint.
    def recorded(directory, id:, inventory:, index:, failed_examples:)
      raise ArtifactError, "invalid failed-example flag" unless [true, false].include?(failed_examples)
      inventory_text = JSON.pretty_generate(inventory.to_h) + "\n"
      index_text = JSON.pretty_generate(index.to_h) + "\n"
      inventory_sha = Digest::SHA256.hexdigest(inventory_text)
      index_sha = Digest::SHA256.hexdigest(index_text)
      unless digest_regular(File.join(directory, "inventory.json")) == inventory_sha &&
             digest_regular(File.join(directory, "bitmap_index.json")) == index_sha
        raise ArtifactError, "artifact files changed before provenance publication"
      end
      data = marker("recorded", id).merge("inventory_fingerprint" => inventory.fingerprint,
                                         "inventory_sha256" => inventory_sha, "index_sha256" => index_sha,
                                         "failed_examples" => failed_examples)
      write(directory, data)
      data
    end

    # Validate against exact artifact bytes already captured by the caller. A
    # missing marker is a legacy/unknown pair; malformed or stale markers fail.
    def check(directory, inventory_text:, index_text:, inventory:)
      path = File.join(directory, NAME)
      return { "status" => "unavailable", "complete" => false } unless File.exist?(path) || File.symlink?(path)
      data = ArtifactValidation.parse(read_regular(path, MAX_BYTES))
      ArtifactValidation.keys!(data, FIELDS, "index provenance")
      unless data["schema"] == SCHEMA && data["version"] == VERSION && data["complete"] == false && data["suite_coverage_verified"] == false &&
             data["generation_id"].is_a?(String) && data["generation_id"].match?(/\A[0-9a-f]{32}\z/) &&
             %w[running incomplete recorded].include?(data["status"])
        raise ArtifactError, "invalid index provenance marker"
      end
      if data["status"] != "recorded"
        unless %w[inventory_fingerprint inventory_sha256 index_sha256 failed_examples].all? { |key| data[key].nil? }
          raise ArtifactError, "invalid incomplete index provenance marker"
        end
        raise ArtifactError, "index provenance is #{data['status']}; artifacts may be stale or mixed"
      end
      %w[inventory_fingerprint inventory_sha256 index_sha256].each { |key| ArtifactValidation.digest!(data[key], key) }
      raise ArtifactError, "invalid failed-example flag" unless [true, false].include?(data["failed_examples"])
      unless data["inventory_fingerprint"] == inventory.fingerprint && data["inventory_sha256"] == Digest::SHA256.hexdigest(inventory_text) &&
             data["index_sha256"] == Digest::SHA256.hexdigest(index_text)
        raise ArtifactError, "artifact pair does not match index provenance"
      end
      data
    end

    def read_pair(root:)
      root = File.realpath(root)
      directory = File.join(root, ".cleave")
      raise ArtifactError, ".cleave must be a real directory, not a symlink" if File.symlink?(directory) || !File.directory?(directory)
      inventory_text = read_regular(File.join(directory, "inventory.json"), MAX_ARTIFACT_BYTES)
      index_text = read_regular(File.join(directory, "bitmap_index.json"), MAX_ARTIFACT_BYTES)
      inventory = Inventory.load(inventory_text)
      index = BitmapIndex.load(index_text, inventory: inventory)
      provenance = check(directory, inventory_text: inventory_text, index_text: index_text, inventory: inventory)
      [inventory, index, provenance]
    rescue ArtifactError => error
      raise ArtifactError, "artifact pair is incomplete: #{error.message}" if error.message.start_with?("missing file:")
      raise
    end

    def inspect_pair(root:)
      read_pair(root: root).last
    end

    def marker(status, id)
      { "schema" => SCHEMA, "version" => VERSION, "status" => status, "complete" => false,
        "generation_id" => id, "inventory_fingerprint" => nil, "inventory_sha256" => nil,
        "index_sha256" => nil, "failed_examples" => nil, "suite_coverage_verified" => false }
    end
    private_class_method :marker

    def write(directory, data)
      path = File.join(directory, NAME)
      raise ArtifactError, "index provenance must not be a symlink" if File.symlink?(path)
      Tempfile.create([".index-provenance-", ".tmp"], directory) do |file|
        file.binmode
        file.write(JSON.pretty_generate(data) + "\n")
        file.flush
        file.fsync
        raise ArtifactError, "index provenance must not be a symlink" if File.symlink?(path)
        file.close
        File.rename(file.path, path)
      end
    end
    private_class_method :write

    def open_regular(path)
      raise ArtifactError, "file must not be a symlink: #{File.basename(path)}" if File.symlink?(path)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      # Windows File::NONBLOCK is 1, the write-only flag, so only OR it on POSIX.
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK) && !Gem.win_platform?
      File.open(path, flags) do |file|
        raise ArtifactError, "file must be regular: #{File.basename(path)}" unless file.stat.file?
        yield file
      end
    rescue Errno::ENOENT
      raise ArtifactError, "missing file: #{File.basename(path)}"
    end
    private_class_method :open_regular

    def read_regular(path, limit)
      open_regular(path) do |file|
        bytes = file.read(limit + 1) || +""
        raise ArtifactError, "file exceeds limit: #{File.basename(path)}" if bytes.bytesize > limit
        bytes.force_encoding(Encoding::UTF_8)
        raise ArtifactError, "file is not UTF-8: #{File.basename(path)}" unless bytes.valid_encoding?
        bytes
      end
    end
    private_class_method :read_regular

    def digest_regular(path)
      open_regular(path) do |file|
        digest = Digest::SHA256.new
        while (chunk = file.read(64 * 1024))
          digest.update(chunk)
        end
        digest.hexdigest
      end
    end
    private_class_method :digest_regular
  end
end
