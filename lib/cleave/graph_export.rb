# frozen_string_literal: true

require "json"
require "tempfile"
require_relative "artifacts"

module Cleave
  # A portable visualization of recorded bitmap relationships, not a selector.
  module GraphExport
    module_function

    def render(inventory:, index:)
      raise ArgumentError, "expected Inventory and BitmapIndex" unless inventory.is_a?(Inventory) && index.is_a?(BitmapIndex)
      # Revalidate all serialized cross-references even for programmatically built indexes.
      index = BitmapIndex.load(JSON.generate(index.to_h), inventory: inventory)
      roots = index.root_paths.to_set
      paths = (index.masks.keys | index.root_paths).sort
      payload = {
        "fingerprint" => inventory.fingerprint,
        "inventory_count" => inventory.files.length,
        "specs" => index.specs,
        "files" => paths.map { |path| { "path" => path, "hex" => "0x#{index.masks.fetch(path, 0).to_s(16)}",
                                         "root" => roots.include?(path), "in_inventory" => inventory.files.key?(path) } },
        "limitations" => index.limitations
      }
      # Never let artifact data break out of the script element or HTML parser.
      json = JSON.generate(payload).gsub(/[<>&\u2028\u2029]/) { |char| format('\\u%04x', char.ord) }
      template = File.binread(File.join(__dir__, "graph_template.html")).force_encoding(Encoding::UTF_8)
      raise ArtifactError, "invalid graph template" unless template.scan("__CLEAVE_GRAPH_DATA__").length == 1
      template.sub("__CLEAVE_GRAPH_DATA__") { json }
    end

    # Explicit output only. Atomic replacement of regular files; no symlink targets.
    def write(path, inventory:, index:)
      raise ArgumentError, "output must be an .html file" unless path.is_a?(String) && path.end_with?(".html") && !path.include?("\0")
      html = render(inventory: inventory, index: index)
      target = File.expand_path(path)
      parent = File.realpath(File.dirname(target))
      target = File.join(parent, File.basename(target))
      raise ArtifactError, "output must not be a symlink" if File.symlink?(target)
      raise ArtifactError, "output must be a regular file" if File.exist?(target) && !File.file?(target)
      Tempfile.create([".cleave-graph-", ".tmp"], parent) do |file|
        file.write(html)
        file.flush
        file.fsync
        raise ArtifactError, "output must not be a symlink" if File.symlink?(target)
        File.rename(file.path, target)
      end
      target
    end
  end
end
