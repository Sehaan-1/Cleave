# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "json"

class DiagnosticPlanTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-plan")
    project = File.expand_path("..", __dir__)
    write("Gemfile", "source 'https://rubygems.org'\ngem 'cleave-ste', path: #{project.inspect}\ngem 'rspec', '~> 3.13'\n")
    @env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    out, status = Open3.capture2e(@env, "bundle", "lock", "--local", chdir: @root)
    raise out unless status.success?
    assert system("git", "-C", @root, "init", "-q")
    write(".gitignore", ".cleave/\nignored/\n")
    write("a.json", "{}")
    write("boot.json", "{}")
    write("spec/spec_helper.rb", "File.read('boot.json')\n")
    write(".rspec", "--require ./spec/spec_helper.rb\n")
    write("spec/a_spec.rb", "RSpec.describe('a') { it('reads') { File.read('a.json') } }\n")
    write("spec/b_spec.rb", "RSpec.describe('b') { it('hazard') { Dir.glob('*.json') } }\n")
    output = StringIO.new
    result = Cleave::RSpecRunner.run(root: @root, trace: true, index: true, output: output)
    assert_equal "passed", result["outcome"], "#{result.inspect}\n#{output.string}"
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def write(path, data)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, data)
  end

  def build(**options)
    Cleave::DiagnosticPlan.build(root: @root, output: StringIO.new, **options)
  end

  def test_real_index_current_changes_guardrails_and_new_spec
    write("a.json", "changed")
    write("new.txt", "new")
    write("spec/c_spec.rb", "RSpec.describe('c') { it('does not execute') { File.write('example-ran', 'yes') } }\n")
    plan = build
    assert_equal "cleave.diagnostic_plan", plan["schema"]
    assert_equal 1, plan["version"]
    assert_equal true, plan["diagnostic_only"]
    assert_equal true, plan["requires_full_suite"]
    assert_equal false, plan["execution_ready"]
    assert_equal false, plan["suite_coverage_verified"]
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb], plan["discovered_specs"]
    assert_equal plan["discovered_specs"], plan["candidate_specs"]
    assert_includes plan.dig("changes", "modified"), "a.json"
    assert_includes plan.dig("changes", "added"), "new.txt"
    assert_includes plan["unmapped_changes"], "new.txt"
    a, b, c = plan.fetch("decisions")
    assert_includes a.fetch("bitmap_sources"), "a.json"
    assert_includes a.fetch("reasons"), "bitmap_hit"
    assert_includes b.fetch("reasons"), "prism_hazard"
    assert b.fetch("hazards").any? { |hazard| hazard["name"].include?("glob") && hazard["line"].is_a?(Integer) }
    assert c.fetch("unindexed_spec")
    assert_includes c.fetch("reasons"), "unindexed_spec"
    assert_includes plan["fallback_reasons"], "incomplete_index"
    assert_includes plan["fallback_reasons"], "previous_failures_unavailable"
    refute File.exist?(File.join(@root, "example-ran"))
    assert_operator plan["union_nanoseconds"], :>=, 0
  end

  def test_changed_root_falls_back_in_candidate
    write("boot.json", "changed")
    plan = build
    assert_includes plan["root_changes"], "boot.json"
    assert_equal plan["discovered_specs"], plan["candidate_specs"]
    assert plan["decisions"].all? { |item| item["reasons"].include?("root_scope_fallback") }
  end

  def test_cli_prints_json_only_and_does_not_replace_run_state
    before = File.binread(File.join(@root, ".cleave/last_run.json"))
    stdout, stderr, status = Open3.capture3(@env, "bundle", "exec", "cleave", "plan", chdir: @root)
    assert status.success?, stderr
    json = JSON.parse(stdout)
    assert_equal "cleave.diagnostic_plan", json.fetch("schema")
    assert_equal before, File.binread(File.join(@root, ".cleave/last_run.json"))
  end

  def test_missing_invalid_symlink_artifacts_and_busy_lock_are_rejected
    index_path = File.join(@root, ".cleave/bitmap_index.json")
    content = File.binread(index_path)
    File.write(index_path, "{}")
    assert_raises(Cleave::ArtifactError) { build }
    File.delete(index_path)
    assert_raises(Cleave::ArtifactError) { build }
    File.symlink(File.join(@root, "a.json"), index_path)
    assert_match(/symlink/, assert_raises(Cleave::ArtifactError) { build }.message)
    File.delete(index_path)
    File.binwrite(index_path, content)
    File.open(File.join(@root, ".cleave/runner.lock"), File::RDWR) do |lock|
      lock.flock(File::LOCK_EX)
      assert_match(/active/, assert_raises(Cleave::RunnerError) { build }.message)
    end
  end

  def test_discovery_changes_abort_and_ignored_new_specs_require_include
    write("spec/spec_helper.rb", "File.write('a.json', 'changed during discovery')\n")
    assert_match(/changed during discovery/, assert_raises(Cleave::ArtifactError) { build }.message)
    write("spec/spec_helper.rb", "File.read('boot.json')\n")
    write("ignored/custom_spec.rb", "RSpec.describe('ignored') { it('works') {} }\n")
    write(".rspec", "--require ./spec/spec_helper.rb\n--pattern ignored/*_spec.rb,spec/*_spec.rb\n")
    assert_match(/ignored spec/, assert_raises(Cleave::ArtifactError) { build }.message)
    plan = build(includes: ["ignored/custom_spec.rb"])
    assert_includes plan["discovered_specs"], "ignored/custom_spec.rb"
    assert_raises(Cleave::ArtifactError) { build(includes: ["ignored/missing"]) }
    assert_raises(Cleave::ArtifactError) { build(includes: [".cleave/last_run.json"]) }
  end

  def test_discovery_failure_and_empty_suite_are_not_valid_plans
    write("spec/a_spec.rb", "raise 'bad spec load'\n")
    assert_raises(Cleave::RunnerError) { build }
    write(".rspec", "--pattern nothing/*_spec.rb\n")
    assert_match(/no spec files/, assert_raises(Cleave::ArtifactError) { build }.message)
  end
end
