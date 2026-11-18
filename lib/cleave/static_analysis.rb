# typed: strict
# frozen_string_literal: true

require "prism"
require "sorbet-runtime"
require "find"
require "pathname"
require "set"

module Cleave
  class Location < T::Struct
    const :line, Integer
    const :column, Integer
    const :length, Integer
  end

  class Fact < T::Struct
    # `kind` is definition, reference, require_relative, or hazard.
    const :kind, Symbol
    const :value, String
    const :node_type, String
    const :location, Location
    # Syntactic nesting, not Ruby constant resolution.
    const :nesting, T::Array[String]
  end

  class RequireEdge < T::Struct
    const :source, String
    # Lexically resolved path, without assuming a Ruby extension or file existence.
    const :target, String
    const :location, Location
  end

  class FileAnalysis < T::Struct
    const :path, String
    const :facts, T::Array[Fact]
    const :spec, T::Boolean

    extend T::Sig
    sig { returns(T::Boolean) }
    def mandatory?
      spec && facts.any? { |fact| fact.kind == :hazard }
    end

    sig { returns(T::Array[RequireEdge]) }
    def require_edges
      facts.select { |fact| fact.kind == :require_relative }.map do |fact|
        target = Pathname.new(path).dirname.join(fact.value).cleanpath.to_s
        RequireEdge.new(source: path, target: target, location: fact.location)
      end
    end
  end

  class ParseError < StandardError
    extend T::Sig
    sig { returns(String) }
    attr_reader :path

    sig { returns(T::Array[String]) }
    attr_reader :diagnostics

    sig { params(path: String, diagnostics: T::Array[String]).void }
    def initialize(path, diagnostics)
      @path = path
      @diagnostics = diagnostics
      super("#{path}: #{diagnostics.join('; ')}")
    end
  end

  # Extracts syntactic facts only. It does not resolve constants or execute code.
  class DependencyVisitor < Prism::Visitor
    extend T::Sig
    DIR_METHODS = T.let(%i[glob [] entries children].freeze, T::Array[Symbol])
    DYNAMIC_METHODS = T.let(%i[const_get eval class_eval instance_eval module_eval send public_send __send__].freeze, T::Array[Symbol])

    sig { returns(T::Array[Fact]) }
    attr_reader :facts

    sig { void }
    def initialize
      super()
      @facts = T.let([], T::Array[Fact])
      @nesting = T.let([], T::Array[String])
      @definition_nodes = T.let(Set.new, T::Set[Integer])
    end

    sig { override.params(node: Prism::ClassNode).void }
    def visit_class_node(node)
      visit_definition(node, node.constant_path)
    end

    sig { override.params(node: Prism::ModuleNode).void }
    def visit_module_node(node)
      visit_definition(node, node.constant_path)
    end

    sig { override.params(node: Prism::ConstantReadNode).void }
    def visit_constant_read_node(node)
      add(:reference, node.slice, node) unless @definition_nodes.include?(node.object_id)
      super
    end

    sig { override.params(node: Prism::ConstantPathNode).void }
    def visit_constant_path_node(node)
      # A path is one lookup, not a separate lookup for every prefix.
      unless @definition_nodes.include?(node.object_id)
        add(:reference, node.slice, node)
        mark_constant_path(node.parent) if node.parent
      end
      super
    end

    sig { override.params(node: Prism::CallNode).void }
    def visit_call_node(node)
      receiver = node.receiver&.slice
      if ((receiver == "Dir" || receiver == "::Dir") && DIR_METHODS.include?(node.name)) || DYNAMIC_METHODS.include?(node.name)
        add(:hazard, node.name.to_s, node)
      end
      args = node.arguments&.arguments
      if node.name == :require_relative && (receiver.nil? || receiver == "Kernel" || receiver == "::Kernel")
        if args && args.length == 1 && args.first.is_a?(Prism::StringNode)
          add(:require_relative, args.first.unescaped, node)
        else
          add(:hazard, "dynamic require_relative", node)
        end
      end
      super
    end

    private

    sig { params(node: T.any(Prism::ClassNode, Prism::ModuleNode), path: Prism::Node).void }
    def visit_definition(node, path)
      add(:definition, path.slice, node, path.location)
      mark_constant_path(path)
      @nesting.push(path.slice)
      begin
        node.compact_child_nodes.each { |child| child.accept(self) }
      ensure
        @nesting.pop
      end
    end

    sig { params(node: Prism::Node).void }
    def mark_constant_path(node)
      return unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      @definition_nodes.add(node.object_id)
      mark_constant_path(node.parent) if node.is_a?(Prism::ConstantPathNode) && node.parent
    end

    sig { params(kind: Symbol, value: String, node: Prism::Node, location: Prism::Location).void }
    def add(kind, value, node, location = node.location)
      @facts << Fact.new(kind: kind, value: value, node_type: node.class.name.split("::").last,
                         location: Location.new(line: location.start_line, column: location.start_column, length: location.length), nesting: @nesting.dup)
    end
  end

  module StaticAnalysis
    extend T::Sig
    SCAN_EXCLUDED = T.let(%w[.git node_modules].freeze, T::Array[String])

    sig { params(source: String, path: String, spec: T.nilable(T::Boolean)).returns(FileAnalysis) }
    def self.analyze(source, path:, spec: nil)
      result = Prism.parse(source, filepath: path)
      unless result.success?
        diagnostics = result.errors.map { |error| "#{error.location.start_line}:#{error.location.start_column}: #{error.message}" }
        raise ParseError.new(path, diagnostics)
      end
      visitor = DependencyVisitor.new
      result.value.accept(visitor)
      spec = path.tr("\\", "/").match?(%r{(?:\A|/)spec/.*_spec\.rb\z}) if spec.nil?
      FileAnalysis.new(path: path, facts: visitor.facts, spec: spec)
    end

    # Deterministic, fail-closed scan: any unreadable or invalid Ruby aborts the scan.
    # Directory symlinks are not followed and file symlinks are excluded.
    sig { params(root: String).returns(T::Array[FileAnalysis]) }
    def self.scan(root)
      absolute = File.realpath(root)
      raise ArgumentError, "not a directory: #{root}" unless File.directory?(absolute)
      paths = T.let([], T::Array[String])
      Find.find(absolute, ignore_error: false) do |path|
        next if path == absolute
        stat = File.lstat(path)
        next if stat.symlink?
        if stat.directory?
          Find.prune if SCAN_EXCLUDED.include?(File.basename(path))
          next
        end
        next unless stat.file? && path.end_with?(".rb")
        paths << Pathname.new(path).relative_path_from(Pathname.new(absolute)).to_s
      end
      paths.sort.map { |path| analyze(File.binread(File.join(absolute, path)), path: path) }
    end
  end
end
