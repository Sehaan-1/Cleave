# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "cleave/ui_server"
require "net/http"
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
    write("spec/d_spec.rb", "RSpec.describe('d') { it('passes') {} }\n")
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
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb spec/d_spec.rb], plan["discovered_specs"]
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb spec/c_spec.rb], plan["candidate_specs"]
    assert_includes plan.dig("changes", "modified"), "a.json"
    assert_includes plan.dig("changes", "added"), "new.txt"
    assert_includes plan["unmapped_changes"], "new.txt"
    a, b, c, d = plan.fetch("decisions")
    assert_includes a.fetch("bitmap_sources"), "a.json"
    assert_includes a.fetch("reasons"), "bitmap_hit"
    assert_includes b.fetch("reasons"), "prism_hazard"
    assert b.fetch("hazards").any? { |hazard| hazard["name"].include?("glob") && hazard["line"].is_a?(Integer) }
    refute d.fetch("candidate")
    assert_includes d.fetch("reasons"), "incomplete_index_fallback"
    assert c.fetch("unindexed_spec")
    assert_includes c.fetch("reasons"), "unindexed_spec"
    assert_includes plan["fallback_reasons"], "incomplete_index"
    assert_includes plan["fallback_reasons"], "previous_failures_unavailable"
    refute File.exist?(File.join(@root, "example-ran"))
    assert_operator plan["union_nanoseconds"], :>=, 0
  end

  def test_static_dependencies_add_unobserved_edges_to_cli_and_ui_plan
    write("app/dependency.rb", "class Dependency; end\n")
    write("spec/d_spec.rb", "RSpec.describe('d') { it('passes') { require_relative '../app/dependency' if false } }\n")
    generated = Cleave::RSpecRunner.run(root: @root, trace: true, index: true, output: StringIO.new)
    assert_equal "passed", generated["outcome"], generated.inspect
    write("app/dependency.rb", "class Dependency; end\n# changed\n")
    default = build
    refute_includes default["candidate_specs"], "spec/d_spec.rb"
    plan = build(static_dependencies: true, previous_failures: true)
    assert_equal 3, plan["version"]
    assert plan["previous_failures_available"]
    refute plan["static_deleted_fallback"]
    decision = plan["decisions"].find { |item| item["spec"] == "spec/d_spec.rb" }
    assert_includes decision["static_sources"], "app/dependency.rb"
    assert_includes decision["reasons"], "static_dependency"
    assert_includes decision["static_uncertainties"], "unresolved_constant" # RSpec is external
    assert_includes plan["fallback_reasons"], "static_uncertainty"
    assert plan["requires_full_suite"]
    refute plan["execution_ready"]
    stdout, stderr, status = Open3.capture3(@env, "bundle", "exec", "cleave", "plan", "--static-dependencies", chdir: @root)
    assert status.success?, stderr
    from_cli = JSON.parse(stdout)
    assert_equal 3, from_cli["version"]
    assert_nil from_cli["previous_failures_source_sha256"]
    refute from_cli["previous_failures_available"]
    assert_includes from_cli["decisions"].find { |item| item["spec"] == "spec/d_spec.rb" }["static_sources"], "app/dependency.rb"
    server = Cleave::UIServer.new(root: @root, plan: true, static_dependencies: true, output: StringIO.new)
    thread = Thread.new { server.start }
    begin
      uri = URI(server.url)
      response = Net::HTTP.new(uri.host, uri.port, nil).get(uri.path + "artifacts/plan.json")
      assert_equal 3, JSON.parse(response.body)["version"]
    ensure
      server.shutdown
      thread.join(5)
    end
    assert_raises(ArgumentError) { Cleave::UIServer.new(root: @root, static_dependencies: true) }
  end

  def test_previous_failures_are_opt_in_and_use_latest_consistent_run
    original = File.read(File.join(@root, "spec/d_spec.rb"))
    write("spec/d_spec.rb", "RSpec.describe('d') { it('fails') { expect(1).to eq(2) } }\n")
    failed = Cleave::RSpecRunner.run(root: @root, output: StringIO.new)
    assert_equal "failed", failed["outcome"]
    write("spec/d_spec.rb", original)
    default = build
    refute default["previous_failures_available"]
    refute_includes default["candidate_specs"], "spec/d_spec.rb"
    plan = build(previous_failures: true)
    assert_equal 2, plan["version"]
    assert plan["previous_failures_available"]
    refute_includes plan["fallback_reasons"], "previous_failures_unavailable"
    assert_equal [], plan["unmatched_previous_failures"]
    assert_includes plan["candidate_specs"], "spec/d_spec.rb"
    assert_includes plan["decisions"].find { |d| d["spec"] == "spec/d_spec.rb" }["reasons"], "previous_failure"
    assert_equal Digest::SHA256.file(File.join(@root, ".cleave/last_run.json")).hexdigest, plan["previous_failures_source_sha256"]
    assert plan["requires_full_suite"]
    refute plan["execution_ready"]
    stdout, stderr, status = Open3.capture3(@env, "bundle", "exec", "cleave", "plan", "--previous-failures", chdir: @root)
    assert status.success?, stderr
    assert_includes JSON.parse(stdout)["candidate_specs"], "spec/d_spec.rb"
    server = Cleave::UIServer.new(root: @root, plan: true, previous_failures: true, output: StringIO.new)
    thread = Thread.new { server.start }
    begin
      uri = URI(server.url)
      response = Net::HTTP.new(uri.host, uri.port, nil).get(uri.path + "artifacts/plan.json")
      assert_equal 2, JSON.parse(response.body)["version"]
    ensure
      server.shutdown
      thread.join(5)
    end
    File.delete(File.join(@root, "spec/d_spec.rb"))
    plan = build(previous_failures: true)
    assert_equal ["spec/d_spec.rb"], plan["unmatched_previous_failures"]
    assert_includes plan["fallback_reasons"], "previous_failures_unmatched"
  end

  def test_previous_failures_known_empty_and_reject_bad_records
    plan = build(previous_failures: true)
    assert plan["previous_failures_available"]
    assert_equal [], plan["unmatched_previous_failures"]
    refute_includes plan["fallback_reasons"], "previous_failures_unavailable"
    path = File.join(@root, ".cleave/last_run.json")
    good = JSON.parse(File.read(path))
    variants = []
    variants << good.merge("outcome" => "running")
    variants << good.merge("outcome" => "incomplete")
    variants << good.merge("reports_complete" => false)
    variants << good.merge("suite_coverage_verified" => true)
    variants << good.merge("outcome" => "failed", "exit_code" => 1)
    variants << good.merge("observed_failed_specs" => ["../bad.rb"])
    variants << good.merge("observed_failed_specs" => ["spec/a_spec.rb", "spec/a_spec.rb"])
    variants << good.merge("telemetry" => good.fetch("telemetry").merge("failed_examples" => 1))
    variants.each do |bad|
      File.write(path, JSON.generate(bad))
      assert_raises(Cleave::ArtifactError) { build(previous_failures: true) }
      refute build["previous_failures_available"]
    end
    File.write(path, '{"schema":"cleave.rspec_run","schema":"cleave.rspec_run"}')
    assert_raises(Cleave::ArtifactError) { build(previous_failures: true) }
    File.delete(path)
    assert_raises(Cleave::ArtifactError) { build(previous_failures: true) }
    begin
      File.symlink(File.join(@root, "a.json"), path)
      assert_match(/symlink/, assert_raises(Cleave::ArtifactError) { build(previous_failures: true) }.message)
    rescue NotImplementedError, Errno::EACCES
      # symlink creation requires privileges unavailable on this platform
    end
    assert_raises(ArgumentError) { Cleave::UIServer.new(root: @root, previous_failures: true) }
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

  def test_local_ui_plan_serves_real_immutable_snapshot_with_same_artifacts
    write("a.json", "changed")
    server = Cleave::UIServer.new(root: @root, plan: true, output: StringIO.new)
    thread = Thread.new { server.start }
    begin
      uri = URI(server.url)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      html = http.get(uri.path)
      assert_includes html.body, 'name="cleave-local-plan"'
      response = http.get(uri.path + "artifacts/plan.json")
      assert_equal "200", response.code
      plan = JSON.parse(response.body)
      inventory = JSON.parse(http.get(uri.path + "artifacts/inventory.json").body)
      assert_equal inventory["fingerprint"], plan["baseline_fingerprint"]
      assert_includes plan.dig("changes", "modified"), "a.json"
      assert_equal false, plan["execution_ready"]
      assert_includes plan["decisions"].find { |item| item["spec"] == "spec/a_spec.rb" }["bitmap_sources"], "a.json"
      write("a.json", "changed again")
      assert_equal response.body.b, http.get(uri.path + "artifacts/plan.json").body.b
      assert_equal "404", http.get("/artifacts/plan.json").code
      request = Net::HTTP::Get.new(uri.path + "artifacts/plan.json")
      request["Origin"] = "https://evil.example"
      assert_equal "403", http.request(request).code
    ensure
      server.shutdown
      thread.join(5)
    end
  end

  def test_expected_artifact_bytes_prevent_same_inventory_index_mix
    inventory_path = File.join(@root, ".cleave/inventory.json")
    index_path = File.join(@root, ".cleave/bitmap_index.json")
    expected = [Digest::SHA256.file(inventory_path).hexdigest, Digest::SHA256.file(index_path).hexdigest]
    File.write(index_path, File.read(index_path) + " ") # Same parsed index and inventory fingerprint, different bytes.
    assert_match(/artifact pair changed/, assert_raises(Cleave::ArtifactError) { build(expected_artifacts: expected) }.message)
    assert_raises(ArgumentError) { Cleave::UIServer.new(root: @root, includes: ["a.json"]) }
  end

  def test_missing_invalid_symlink_artifacts_and_busy_lock_are_rejected
    index_path = File.join(@root, ".cleave/bitmap_index.json")
    content = File.binread(index_path)
    File.write(index_path, "{}")
    assert_raises(Cleave::ArtifactError) { build }
    File.delete(index_path)
    assert_raises(Cleave::ArtifactError) { build }
    begin
      File.symlink(File.join(@root, "a.json"), index_path)
      assert_match(/symlink/, assert_raises(Cleave::ArtifactError) { build }.message)
      File.unlink(index_path)
    rescue NotImplementedError, Errno::EACCES
      # symlink creation requires privileges unavailable on this platform
    end
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
