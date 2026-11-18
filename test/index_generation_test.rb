# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "json"

class IndexGenerationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-index")
    project = File.expand_path("..", __dir__)
    write("Gemfile", "source 'https://rubygems.org'\ngem 'cleave-ste', path: #{project.inspect}\ngem 'rspec', '~> 3.13'\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "lock", "--local", chdir: @root)
    raise output unless status.success?
    assert system("git", "-C", @root, "init", "-q")
    write(".gitignore", ".cleave/\nignored/\n")
    write("root.json", "{}")
    write("a.json", "{}")
    write("ignored/extra.json", "{}")
    write("spec/spec_helper.rb", "File.read('root.json')\n")
    write(".rspec", "--require ./spec/spec_helper.rb\n")
    write("spec/a_spec.rb", "RSpec.describe('a') { it('passes') { File.read('a.json'); File.read('ignored/extra.json') } }\n")
    write("spec/b_spec.rb", "RSpec.describe('b') { it('passes') { expect(true).to be(true) } }\n")
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write(path, data)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, data)
  end

  def run_index(**options)
    output = StringIO.new
    result = Cleave::RSpecRunner.run(root: @root, trace: true, index: true, output: output, **options)
    [result, output.string]
  end

  def test_generates_pair_from_real_full_suite_with_explicit_ignored_path
    result, output = run_index(includes: ["ignored/extra.json"])
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_equal "recorded", result.dig("index", "status")
    inventory, index = Cleave::Artifacts.read(File.join(@root, ".cleave"))
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb], index.specs
    assert_equal 1, index.masks.fetch("a.json")
    assert_equal 1, index.masks.fetch("ignored/extra.json")
    assert_includes index.root_paths, "root.json"
    assert inventory.files.key?("ignored/extra.json")
    refute inventory.files.keys.any? { |path| path.start_with?(".cleave/") }
    refute index.to_h["complete"]
    assert index.limitations.any? { |s| s.include?("not transactional") }
    html = Cleave::GraphExport.render(inventory: inventory, index: index)
    assert_includes html, "a.json"
    persisted = JSON.parse(File.read(File.join(@root, ".cleave/last_run.json")))
    assert_equal result.fetch("index"), persisted.fetch("index")
  end

  def test_ignored_observed_paths_can_be_absent_and_are_not_fabricated
    result, output = run_index
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
    inventory, index = Cleave::Artifacts.read(File.join(@root, ".cleave"))
    refute inventory.files.key?("ignored/extra.json")
    assert_equal 1, index.masks.fetch("ignored/extra.json")
  end

  def test_failing_examples_still_produce_diagnostic_pair
    write("spec/b_spec.rb", "RSpec.describe('b') { it('fails') { expect(1).to eq(2) } }\n")
    result, output = run_index
    assert_equal "failed", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal "recorded", result.dig("index", "status")
    assert_equal 1, result["exit_code"]
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb], Cleave::Artifacts.read(File.join(@root, ".cleave"))[1].specs
  end

  def test_changed_inventory_rejects_publication_but_runs_all_examples
    write("spec/b_spec.rb", "RSpec.describe('b') { it('changes') { File.write('a.json', 'changed') } }\n")
    write(".cleave/inventory.json", "old inventory")
    write(".cleave/bitmap_index.json", "old index")
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_match(/changed during/, result.dig("index", "error"))
    assert_equal "old inventory", File.read(File.join(@root, ".cleave/inventory.json"))
    assert_equal "old index", File.read(File.join(@root, ".cleave/bitmap_index.json"))
  end

  def test_ignored_specs_require_explicit_include
    write(".gitignore", ".cleave/\nspec/b_spec.rb\n")
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_match(/absent from inventory/, result.dig("index", "error"))
    result, output = run_index(includes: ["spec/b_spec.rb"])
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output}"
  end

  def test_setup_error_still_runs_full_suite_and_output_symlink_is_rejected
    result, output = run_index(includes: [".cleave/last_run.json"])
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal 2, result["example_count"]
    assert_match(/cannot include Cleave state/, result.dig("index", "error"))
    File.symlink(File.join(@root, "a.json"), File.join(@root, ".cleave/inventory.json"))
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_match(/symlink/, result.dig("index", "error"))
    assert_equal "{}", File.read(File.join(@root, "a.json"))
  end

  def test_crash_does_not_publish_pair
    write("spec/a_spec.rb", "RSpec.describe('crash') { it('exits') { exit! 7 } }\n")
    result, output = run_index
    assert_equal "incomplete", result["outcome"], "#{result.inspect}\n#{output}"
    assert_equal "incomplete", result.dig("index", "status")
    refute File.exist?(File.join(@root, ".cleave/inventory.json"))
  end

  def test_cli_and_invalid_combinations
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "run", "--trace", "--index", "--include", "ignored/extra.json", chdir: @root)
    assert status.success?, output
    assert_match(/Artifacts: recorded/, output)
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, index: true) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, trace: true, index: true, workers: 2) }
    assert_raises(ArgumentError) { Cleave::RSpecRunner.run(root: @root, includes: ["a.json"]) }
  end
end
