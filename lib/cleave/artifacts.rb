# typed: false
# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require "open3"
require "pathname"
require "set"
require "tempfile"

module Cleave
  class ArtifactError < StandardError; end

  module ArtifactValidation
    module_function

    def path(value)
      unless value.is_a?(String) && [Encoding::UTF_8, Encoding::US_ASCII].include?(value.encoding) && value.valid_encoding? && !value.empty? &&
             !value.start_with?("/") && !value.include?("\\") && !value.include?("\0") &&
             value.split("/", -1).none? { |part| part.empty? || part == "." || part == ".." || part == ".git" }
        raise ArtifactError, "invalid repository-relative path: #{value.inspect}"
      end
      value.encode(Encoding::UTF_8)
    rescue EncodingError
      raise ArtifactError, "path is not UTF-8: #{value.inspect}"
    end

    def keys!(object, expected, name)
      raise ArtifactError, "invalid #{name} fields" unless object.is_a?(Hash) && object.keys.sort == expected.sort
    end

    def sorted_unique_strings!(array, name)
      unless array.is_a?(Array) && array.all? { |item| item.is_a?(String) && item.valid_encoding? } && array == array.sort.uniq
        raise ArtifactError, "#{name} must be a sorted array of unique strings"
      end
    end

    def paths!(array, name)
      sorted_unique_strings!(array, name)
      array.each { |item| path(item) }
    end

    def digest!(value, name)
      raise ArtifactError, "invalid #{name}" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    class UniqueObject < Hash
      def []=(key, value)
        raise ArtifactError, "duplicate JSON key: #{key}" if key?(key)
        super
      end
    end

    def parse(json)
      JSON.parse(json, object_class: UniqueObject)
    rescue JSON::ParserError => error
      raise ArtifactError, "invalid JSON: #{error.message}"
    end
  end

  # Immutable, path-sorted set of SHA-256 digests for regular files.
  class Inventory
    SCHEMA = "cleave.inventory"
    VERSION = 1
    attr_reader :files, :fingerprint

    def initialize(files)
      raise ArtifactError, "files must be a Hash" unless files.is_a?(Hash)
      raise ArtifactError, "inventory paths must be strings" unless files.keys.all? { |path| path.is_a?(String) && path.valid_encoding? }
      ordered = files.keys.sort
      ArtifactValidation.paths!(ordered, "inventory paths")
      @files = ordered.to_h do |path|
        digest = files.fetch(path)
        ArtifactValidation.digest!(digest, "SHA-256 for #{path}")
        [path.dup.freeze, digest.dup.freeze]
      end.freeze
      @fingerprint = Digest::SHA256.hexdigest(JSON.generate(payload)).freeze
      freeze
    end

    # `paths` is the requested universe. Missing files are omitted (deletions).
    # All existing paths must be regular files with no symlink components.
    def self.capture(root:, paths:)
      root = File.realpath(root)
      raise ArgumentError, "not a directory: #{root}" unless File.directory?(root)
      raise ArtifactError, "paths must be an array" unless paths.is_a?(Array)
      normalized = paths.map { |path| ArtifactValidation.path(path) }.uniq.sort
      files = {}
      normalized.each do |path|
        absolute = root
        missing = false
        stat = nil
        path.split("/").each do |part|
          absolute = File.join(absolute, part)
          begin
            stat = File.lstat(absolute)
          rescue Errno::ENOENT, Errno::ENOTDIR
            missing = true
            break
          end
          raise ArtifactError, "symlink not supported: #{path}" if stat.symlink?
        end
        next if missing
        raise ArtifactError, "not a regular file: #{path}" unless stat.file?
        files[path] = digest_file(absolute, path)
      end
      new(files)
    end

    # Tracked, staged and untracked non-ignored files, plus explicit generated files.
    # A deleted tracked file is absent from the resulting inventory.
    def self.capture_git(root:, generated: [])
      root = File.realpath(root)
      raise ArgumentError, "not a directory: #{root}" unless File.directory?(root)
      raise ArtifactError, "generated must be an array" unless generated.is_a?(Array)
      stdout, stderr, status = Open3.capture3("git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
      raise ArtifactError, "git ls-files failed: #{stderr.strip}" unless status.success?
      paths = stdout.split("\0").map do |entry|
        utf8 = entry.dup.force_encoding(Encoding::UTF_8)
        ArtifactValidation.path(utf8)
      end
      capture(root: root, paths: paths + generated)
    rescue Errno::ENOENT => error
      raise ArtifactError, "cannot invoke git: #{error.message}"
    end

    def self.digest_file(path, relative)
      File.open(path, "rb") do |file|
        before = file.stat
        raise ArtifactError, "not a regular file: #{relative}" unless before.file?
        hash = Digest::SHA256.new
        while (chunk = file.read(64 * 1024))
          hash.update(chunk)
        end
        after = file.stat
        current = File.lstat(path)
        identity = ->(s) { [s.dev, s.ino, s.size, s.mtime, s.ctime] }
        unless !current.symlink? && identity.call(before) == identity.call(after) && identity.call(after) == identity.call(current)
          raise ArtifactError, "file changed during hashing: #{relative}"
        end
        hash.hexdigest
      end
    end
    private_class_method :digest_file

    def diff(other)
      raise ArgumentError, "expected Inventory" unless other.is_a?(Inventory)
      added = other.files.keys - files.keys
      deleted = files.keys - other.files.keys
      modified = (files.keys & other.files.keys).select { |path| files[path] != other.files[path] }
      { added: added.sort, deleted: deleted.sort, modified: modified.sort }
    end

    def payload
      { "schema" => SCHEMA, "version" => VERSION, "files" => files.map { |path, sha| { "path" => path, "sha256" => sha } } }
    end

    def to_h
      payload.merge("fingerprint" => fingerprint)
    end

    def self.load(json)
      object = ArtifactValidation.parse(json)
      ArtifactValidation.keys!(object, %w[schema version files fingerprint], "inventory")
      raise ArtifactError, "unsupported inventory schema or version" unless object["schema"] == SCHEMA && object["version"] == VERSION
      entries = object["files"]
      raise ArtifactError, "files must be an array" unless entries.is_a?(Array)
      entries.each { |entry| ArtifactValidation.keys!(entry, %w[path sha256], "inventory file") }
      paths = entries.map { |entry| entry["path"] }
      ArtifactValidation.paths!(paths, "inventory paths")
      inventory = new(entries.to_h { |entry| [entry["path"], entry["sha256"]] })
      ArtifactValidation.digest!(object["fingerprint"], "inventory fingerprint")
      raise ArtifactError, "inventory fingerprint mismatch" unless inventory.fingerprint == object["fingerprint"]
      inventory
    end
  end

  # IDs are artifact-local sorted spec positions. Paths are the durable identity.
  class BitmapIndex
    SCHEMA = "cleave.bitmap_index"
    VERSION = 1
    attr_reader :inventory_fingerprint, :specs, :masks, :root_paths, :limitations

    def initialize(inventory_fingerprint:, specs:, masks:, root_paths:, limitations:)
      ArtifactValidation.digest!(inventory_fingerprint, "inventory fingerprint")
      ArtifactValidation.paths!(specs, "spec paths")
      ArtifactValidation.paths!(root_paths, "root paths")
      ArtifactValidation.sorted_unique_strings!(limitations, "limitations")
      raise ArtifactError, "limitations must describe incomplete coverage" if limitations.empty? || limitations.any?(&:empty?)
      raise ArtifactError, "masks must be a Hash" unless masks.is_a?(Hash)
      raise ArtifactError, "bitmap paths must be strings" unless masks.keys.all? { |path| path.is_a?(String) && path.valid_encoding? }
      ArtifactValidation.paths!(masks.keys.sort, "bitmap paths")
      max = (1 << specs.length) - 1
      masks.each do |path, mask|
        raise ArtifactError, "invalid mask for #{path}" unless mask.is_a?(Integer) && mask.positive? && mask <= max
      end
      @inventory_fingerprint = inventory_fingerprint.dup.freeze
      @specs = specs.map { |item| item.dup.freeze }.freeze
      @masks = masks.keys.sort.to_h { |path| [path.dup.freeze, masks.fetch(path)] }.freeze
      @root_paths = root_paths.map { |item| item.dup.freeze }.freeze
      @limitations = limitations.map { |item| item.dup.freeze }.freeze
      freeze
    end

    def self.build(inventory:, root:, specs:, reports:)
      raise ArgumentError, "expected Inventory" unless inventory.is_a?(Inventory)
      raise ArtifactError, "specs must be an array" unless specs.is_a?(Array)
      raise ArtifactError, "reports must be an array" unless reports.is_a?(Array)
      paths = specs.map { |path| ArtifactValidation.path(path) }
      raise ArtifactError, "duplicate spec path" unless paths.uniq.length == paths.length
      paths.sort!
      missing = paths - inventory.files.keys
      raise ArtifactError, "specs absent from inventory: #{missing.join(', ')}" unless missing.empty?
      root = File.realpath(root)
      ids = paths.each_with_index.to_h
      masks = Hash.new(0)
      root_paths = Set.new
      limitations = Set.new(["This index is not safe for test selection; observed traces may be incomplete."])
      limitations.add("No trace reports supplied.") if reports.empty?
      reports.each do |report|
        raise ArtifactError, "expected Cleave::TraceReport" unless report.is_a?(TraceReport)
        raise ArtifactError, "trace root does not match inventory root" unless report.root == root
        limitations.merge(report.limitations)
        report.events.each do |event|
          unless event.is_a?(Array) && event.length == 4 && event.all? { |value| value.is_a?(String) && value.valid_encoding? }
            raise ArtifactError, "invalid trace event"
          end
          scope, path, kind, status = event
          raise ArtifactError, "unknown spec scope: #{scope}" unless scope == "r" || ids.key?(scope)
          raise ArtifactError, "invalid trace operation" unless %w[file_open io_read io_binread yaml_load_file require].include?(kind) && %w[attempt success].include?(status)
          if Pathname.new(path).absolute?
            limitations.add("External paths were omitted from the index.")
            next
          end
          path = ArtifactValidation.path(path)
          if scope == "r"
            root_paths.add(path)
          else
            id = ids[scope]
            raise ArtifactError, "unknown spec scope: #{scope}" unless id
            masks[path] |= 1 << id
          end
        end
      end
      new(inventory_fingerprint: inventory.fingerprint, specs: paths, masks: masks, root_paths: root_paths.to_a.sort, limitations: limitations.to_a.sort)
    end

    def to_h
      { "schema" => SCHEMA, "version" => VERSION, "inventory_fingerprint" => inventory_fingerprint,
        "specs" => specs, "masks" => masks.map { |path, mask| { "path" => path, "hex" => "0x#{mask.to_s(16)}" } },
        "root_paths" => root_paths, "limitations" => limitations, "complete" => false }
    end

    def self.load(json, inventory:)
      raise ArgumentError, "expected Inventory" unless inventory.is_a?(Inventory)
      object = ArtifactValidation.parse(json)
      ArtifactValidation.keys!(object, %w[schema version inventory_fingerprint specs masks root_paths limitations complete], "bitmap index")
      raise ArtifactError, "unsupported bitmap schema or version" unless object["schema"] == SCHEMA && object["version"] == VERSION
      raise ArtifactError, "index is not bound to this inventory" unless object["inventory_fingerprint"] == inventory.fingerprint
      raise ArtifactError, "index cannot claim complete coverage" unless object["complete"] == false
      ArtifactValidation.paths!(object["specs"], "spec paths")
      raise ArtifactError, "specs absent from inventory" unless (object["specs"] - inventory.files.keys).empty?
      entries = object["masks"]
      raise ArtifactError, "masks must be an array" unless entries.is_a?(Array)
      entries.each { |entry| ArtifactValidation.keys!(entry, %w[path hex], "bitmap") }
      ArtifactValidation.paths!(entries.map { |entry| entry["path"] }, "bitmap paths")
      max_digits = (object["specs"].length + 3) / 4
      masks = entries.to_h do |entry|
        hex = entry["hex"]
        unless hex.is_a?(String) && hex.match?(/\A0x[1-9a-f][0-9a-f]*\z/) && hex.length - 2 <= max_digits
          raise ArtifactError, "invalid bitmap hex for #{entry['path']}"
        end
        [entry["path"], hex[2..].to_i(16)]
      end
      new(inventory_fingerprint: object["inventory_fingerprint"], specs: object["specs"], masks: masks,
          root_paths: object["root_paths"], limitations: object["limitations"])
    end
  end

  module Artifacts
    module_function

    def write(directory, inventory:, index:)
      raise ArtifactError, "index is not bound to this inventory" unless index.inventory_fingerprint == inventory.fingerprint
      FileUtils.mkdir_p(directory)
      [["inventory.json", inventory.to_h], ["bitmap_index.json", index.to_h]].each do |name, payload|
        Tempfile.create([".cleave-", ".tmp"], directory) do |file|
          file.write(JSON.pretty_generate(payload) + "\n")
          file.flush
          file.fsync
          File.rename(file.path, File.join(directory, name))
        end
      end
    end

    def read(directory)
      inventory = Inventory.load(File.binread(File.join(directory, "inventory.json")))
      index = BitmapIndex.load(File.binread(File.join(directory, "bitmap_index.json")), inventory: inventory)
      [inventory, index]
    rescue Errno::ENOENT => error
      raise ArtifactError, "artifact pair is incomplete: #{error.message}"
    end
  end
end
