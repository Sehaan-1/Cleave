# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"

class StaticAnalysisTest < Minitest::Test
  def analyze(source, path: "spec/service_spec.rb", **options)
    Cleave::StaticAnalysis.analyze(source, path: path, **options)
  end

  def facts(result, kind)
    result.facts.select { |fact| fact.kind == kind }
  end

  def test_definitions_references_and_nesting_are_syntactic
    result = analyze(<<~RUBY, path: "app/router.rb")
      module Payments
        class Router::Worker < Base::Job
          ::Ledger::Entry.new
          External
        end
      end
    RUBY
    definitions = facts(result, :definition)
    assert_equal [["Payments", "ModuleNode", []], ["Router::Worker", "ClassNode", ["Payments"]]],
                 definitions.map { |f| [f.value, f.node_type, f.nesting] }
    references = facts(result, :reference)
    assert_equal ["Base::Job", "::Ledger::Entry", "External"], references.map(&:value)
    assert_equal ["Payments", "Router::Worker"], references.last.nesting
    assert_equal [2, 8, 14], [definitions.last.location.line, definitions.last.location.column, definitions.last.location.length]
    refute result.mandatory?
  end

  def test_literal_require_edges_and_dynamic_calls
    result = analyze(<<~'RUBY', path: "spec/services/router_spec.rb")
      require_relative "../../app/router"
      Kernel.require_relative 'helper.rb'
      require_relative "#{name}"
      other.require_relative "not_a_kernel_call"
    RUBY
    assert_equal ["../../app/router", "helper.rb"], facts(result, :require_relative).map(&:value)
    assert_equal ["app/router", "spec/services/helper.rb"], result.require_edges.map(&:target)
    assert_equal ["dynamic require_relative"], facts(result, :hazard).map(&:value)
    assert result.mandatory?
  end

  def test_hazards_in_specs_are_mandatory_with_precise_locations
    result = analyze(<<~RUBY)
      Dir.glob("db/*.rb")
      Dir["foo/*"]
      ::Dir.entries(".")
      Dir.children(".")
      Object.const_get(:Foo)
      eval("1 + 1")
      klass.class_eval("def foo; end")
      object.instance_eval("foo")
      klass.module_eval("foo")
      object.send(:run)
      object.public_send(:run)
      object.__send__(:run)
    RUBY
    hazards = facts(result, :hazard)
    assert_equal %w[glob [] entries children const_get eval class_eval instance_eval module_eval send public_send __send__], hazards.map(&:value)
    assert_equal (1..12).to_a, hazards.map { |f| f.location.line }
    assert hazards.all? { |f| f.node_type == "CallNode" && f.location.column == 0 }
    assert result.mandatory?
  end

  def test_non_specs_and_unrelated_calls_are_not_mandatory
    source = "Other.glob('x'); object.entries; Dir.pwd; Dir.glob('db/*')"
    file = analyze(source, path: "app/service.rb")
    assert_equal ["glob"], facts(file, :hazard).map(&:value)
    refute file.mandatory?
    assert analyze(source, path: "app/service.rb", spec: true).mandatory?
    refute analyze(source, spec: false).mandatory?
    refute analyze("Dir.pwd; Foo.glob('*.rb'); eval_count", path: "spec/a_spec.rb").mandatory?
  end

  def test_rejects_invalid_source_with_diagnostics_and_no_partial_result
    error = assert_raises(Cleave::ParseError) { analyze("class Broken\n", path: "spec/broken_spec.rb") }
    assert_equal "spec/broken_spec.rb", error.path
    assert_match(/\d+:\d+:/, error.message)
    refute_empty error.diagnostics
  end

  def test_locations_use_byte_columns_not_character_columns
    result = analyze("# é\n  Payment::Charge\n")
    fact = facts(result, :reference).first
    assert_equal [2, 2, 15], [fact.location.line, fact.location.column, fact.location.length]
  end

  def test_scan_sorts_and_excludes_dependency_directories
    root = File.expand_path("fixtures/project", __dir__)
    files = Cleave::StaticAnalysis.scan(root)
    assert_equal ["app/router.rb", "spec/services/router_spec.rb"], files.map(&:path)
    assert files.last.mandatory?
    refute files.first.mandatory?
  end

  def test_scan_does_not_follow_symlinks_and_aborts_on_invalid_file
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "spec"))
      FileUtils.mkdir_p(File.join(root, "node_modules", "broken"))
      FileUtils.mkdir_p(File.join(root, ".git", "broken"))
      File.write(File.join(root, "node_modules", "broken", "bad.rb"), "class Broken\n")
      File.write(File.join(root, ".git", "broken", "bad.rb"), "class Broken\n")
      File.write(File.join(root, "spec", "good_spec.rb"), "RSpec.describe(X) {}\n")
      File.symlink(File.join(root, "spec", "good_spec.rb"), File.join(root, "link.rb"))
      assert_equal ["spec/good_spec.rb"], Cleave::StaticAnalysis.scan(root).map(&:path)
      File.write(File.join(root, "bad.rb"), "class Nope\n")
      assert_raises(Cleave::ParseError) { Cleave::StaticAnalysis.scan(root) }
    end
  end
end
