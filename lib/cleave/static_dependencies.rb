# frozen_string_literal: true

require "digest"
require "set"
require_relative "static_analysis"
require_relative "artifacts"

module Cleave
  # A bounded syntactic graph over the *current inventoried* Ruby files. It is
  # intentionally approximate and can add diagnostic candidates, never remove
  # them or prove that a test is safe to skip.
  module StaticDependencies
    module_function

    MAX_FILES = 20_000
    MAX_FILE_BYTES = 2 * 1024 * 1024
    MAX_TOTAL_BYTES = 64 * 1024 * 1024
    MAX_EDGES = 250_000
    MAX_MATCHES = 2_000_000
    MAX_TRAVERSAL = 2_000_000
    LIMITATION = "Static dependencies are syntactic approximations over current inventoried Ruby files, not Ruby constant resolution or complete dependency coverage."

    def analyze(root:, current:, specs:, changes:)
      paths = current.files.keys.select { |path| path.end_with?(".rb") }
      raise ArtifactError, "static analysis exceeds #{MAX_FILES} Ruby files" if paths.length > MAX_FILES
      captured = Inventory.capture(root: root, paths: paths)
      raise ArtifactError, "static files do not match the inventory" unless captured.files == current.files.slice(*paths)
      analyses = {}
      bytes = 0
      paths.each do |path|
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
        content = File.open(File.join(root, path), flags) do |file|
          raise ArtifactError, "static source must be a regular file: #{path}" unless file.stat.file?
          file.read(MAX_FILE_BYTES + 1) || +""
        end
        raise ArtifactError, "static source exceeds size limit: #{path}" if content.bytesize > MAX_FILE_BYTES
        bytes += content.bytesize
        raise ArtifactError, "static sources exceed total size limit" if bytes > MAX_TOTAL_BYTES
        raise ArtifactError, "static source changed during analysis: #{path}" unless Digest::SHA256.hexdigest(content) == current.files.fetch(path)
        analyses[path] = StaticAnalysis.analyze(content, path: path, spec: false)
      end

      definitions = Hash.new { |hash, key| hash[key] = Set.new }
      analyses.each do |path, file|
        file.facts.each { |fact| definitions[leaf(fact.value)].add(path) if fact.kind == :definition }
      end
      edges = {}
      uncertainty = {}
      edge_count = 0
      match_count = 0
      analyses.each do |path, file|
        targets = Set.new
        notes = Set.new
        notes.add("dynamic_or_directory_operation") if file.facts.any? { |fact| fact.kind == :hazard }
        file.facts.each do |fact|
          if fact.kind == :reference
            matches = definitions.fetch(leaf(fact.value), [])
            match_count += matches.length
            raise ArtifactError, "static graph exceeds constant match limit" if match_count > MAX_MATCHES
            notes.add("unresolved_constant") if matches.empty?
            matches.each { |target| targets.add(target) unless target == path }
          elsif fact.kind == :runtime_load
            notes.add("unresolved_runtime_load")
          elsif fact.kind == :require_relative
            target = relative_target(path, fact.value)
            if target && analyses.key?(target)
              targets.add(target) unless target == path
            else
              notes.add("unresolved_require_relative")
            end
          end
          raise ArtifactError, "static graph exceeds edge limit" if edge_count + targets.length > MAX_EDGES
        end
        edges[path] = targets.to_a.sort
        uncertainty[path] = notes.to_a.sort
        edge_count += targets.length
      end

      changed = changes.values.flatten.to_set
      deleted = changes.fetch(:deleted).any? { |path| path.end_with?(".rb") }
      traversal = 0
      results = specs.to_h do |spec|
        visited = Set.new
        stack = [spec]
        notes = Set.new
        until stack.empty?
          path = stack.pop
          next unless visited.add?(path)
          traversal += 1 + edges.fetch(path).length
          raise ArtifactError, "static graph exceeds traversal limit" if traversal > MAX_TRAVERSAL
          notes.merge(uncertainty.fetch(path))
          stack.concat(edges.fetch(path))
        end
        [spec, { sources: visited.select { |path| changed.include?(path) }.sort, uncertainties: notes.to_a.sort }]
      end
      [results, deleted]
    end

    def leaf(value)
      value.split("::").last
    end
    private_class_method :leaf

    def relative_target(source, literal)
      return nil if literal.empty? || literal.start_with?("/") || literal.include?("\\") || literal.include?("\0")
      literal = literal.dup.force_encoding(Encoding::UTF_8)
      return nil unless literal.valid_encoding?
      raw = Pathname.new(source).dirname.join(literal).cleanpath.to_s
      candidate = raw.end_with?(".rb") ? raw : "#{raw}.rb"
      ArtifactValidation.path(candidate)
    rescue ArtifactError, ArgumentError
      nil
    end
    private_class_method :relative_target
  end
end
