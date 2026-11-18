# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require "open3"

class ArtifactsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-index")
    FileUtils.mkdir_p(File.join(@root, "spec"))
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "spec", "a_spec.rb"), "# a\n")
    File.write(File.join(@root, "spec", "b_spec.rb"), "# b\n")
    File.write(File.join(@root, "config", "rails.yml"), "enabled: true\n")
    @paths = %w[spec/a_spec.rb spec/b_spec.rb config/rails.yml]
    @inventory = Cleave::Inventory.capture(root: @root, paths: @paths)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def report(events, root: @root, limitations: ["partial"])
    Cleave::TraceReport.new(root: File.realpath(root), pid: 42, events: events, limitations: limitations)
  end

  def build(reports = [])
    Cleave::BitmapIndex.build(inventory: @inventory, root: @root, specs: %w[spec/b_spec.rb spec/a_spec.rb], reports: reports)
  end

  def test_sha_inventory_is_deterministic_and_diff_handles_add_modify_delete
    assert_equal Digest::SHA256.file(File.join(@root, "config/rails.yml")).hexdigest, @inventory.files.fetch("config/rails.yml")
    assert_equal @inventory.to_h, Cleave::Inventory.capture(root: @root, paths: @paths.reverse + [@paths.first]).to_h
    assert @inventory.files.frozen?
    File.write(File.join(@root, "config", "rails.yml"), "enabled: false\n")
    File.delete(File.join(@root, "spec", "a_spec.rb"))
    File.write(File.join(@root, "new.rb"), "new\n")
    current = Cleave::Inventory.capture(root: @root, paths: @paths + ["new.rb"])
    assert_equal({ added: ["new.rb"], deleted: ["spec/a_spec.rb"], modified: ["config/rails.yml"] }, @inventory.diff(current))
  end

  def test_git_capture_includes_new_nonignored_and_explicit_generated_files
    assert system("git", "-C", @root, "init", "-q")
    File.write(File.join(@root, ".gitignore"), "generated/\n")
    assert system("git", "-C", @root, "add", "spec/a_spec.rb")
    FileUtils.mkdir_p(File.join(@root, "generated"))
    File.write(File.join(@root, "generated", "output.json"), "{}")
    baseline = Cleave::Inventory.capture_git(root: @root, generated: ["generated/output.json"])
    assert_includes baseline.files.keys, "spec/a_spec.rb"
    assert_includes baseline.files.keys, "spec/b_spec.rb"
    assert_includes baseline.files.keys, "generated/output.json"
    refute_includes Cleave::Inventory.capture_git(root: @root).files.keys, "generated/output.json"
    File.delete(File.join(@root, "spec", "a_spec.rb"))
    assert_equal ["spec/a_spec.rb"], baseline.diff(Cleave::Inventory.capture_git(root: @root, generated: ["generated/output.json"]))[:deleted]
  end

  def test_invalid_paths_symlinks_and_nonfiles_fail_closed
    ["/etc/passwd", "../outside", "spec/../bad", ".git/config", "a//b", "a\\b", "x\0y", ""].each do |path|
      assert_raises(Cleave::ArtifactError) { Cleave::Inventory.capture(root: @root, paths: [path]) }
    end
    File.symlink(File.join(@root, "config"), File.join(@root, "link"))
    assert_raises(Cleave::ArtifactError) { Cleave::Inventory.capture(root: @root, paths: ["link/rails.yml"]) }
    assert_raises(Cleave::ArtifactError) { Cleave::Inventory.capture(root: @root, paths: ["config"]) }
    if system("mkfifo", File.join(@root, "pipe"))
      assert_raises(Cleave::ArtifactError) { Cleave::Inventory.capture(root: @root, paths: ["pipe"]) }
    end
  end

  def test_reports_build_masks_for_missing_attempts_and_root_observations
    trace = report([
      ["r", "config/rails.yml", "file_open", "success"],
      ["spec/a_spec.rb", "config/rails.yml", "io_read", "success"],
      ["spec/b_spec.rb", "config/rails.yml", "yaml_load_file", "attempt"],
      ["spec/b_spec.rb", "config/missing.json", "io_read", "attempt"],
      ["spec/a_spec.rb", "/external/data.json", "io_read", "success"]
    ])
    index = build([trace])
    assert_equal %w[spec/a_spec.rb spec/b_spec.rb], index.specs
    assert_equal 3, index.masks.fetch("config/rails.yml")
    assert_equal 2, index.masks.fetch("config/missing.json")
    assert_equal ["config/rails.yml"], index.root_paths
    assert_includes index.limitations, "partial"
    assert_includes index.limitations, "External paths were omitted from the index."
    assert_equal false, index.to_h.fetch("complete")
  end

  def test_actual_tracer_feeds_the_index
    tracer = Cleave::ScopedTrace.start(root: @root)
    begin
      File.read(File.join(@root, "config/rails.yml"))
      tracer.with_spec("spec/a_spec.rb") { File.read(File.join(@root, "config/rails.yml")) }
    ensure
      result = tracer.stop
    end
    index = build([result])
    assert_equal 1, index.masks.fetch("config/rails.yml")
    assert_includes index.root_paths, "config/rails.yml"
    refute_empty index.limitations
  end

  def test_1200_bit_masks_and_deterministic_spec_order
    specs = 1200.times.map { |n| format("spec/%04d_spec.rb", n) }
    inventory = Cleave::Inventory.new(specs.to_h { |path| [path, "a" * 64] })
    trace = report([[specs[0], "app/service.rb", "io_read", "success"], [specs[1199], "app/service.rb", "io_read", "success"]])
    index = Cleave::BitmapIndex.build(inventory: inventory, root: @root, specs: specs.reverse, reports: [trace])
    assert_equal (1 | (1 << 1199)), index.masks.fetch("app/service.rb")
    loaded = Cleave::BitmapIndex.load(JSON.generate(index.to_h), inventory: inventory)
    assert_equal index.to_h, loaded.to_h
  end

  def test_round_trip_and_reject_mismatched_or_corrupt_artifacts
    index = build([report([["spec/a_spec.rb", "config/rails.yml", "io_read", "success"]])])
    directory = File.join(@root, ".cleave")
    Cleave::Artifacts.write(directory, inventory: @inventory, index: index)
    loaded_inventory, loaded_index = Cleave::Artifacts.read(directory)
    assert_equal @inventory.to_h, loaded_inventory.to_h
    assert_equal index.to_h, loaded_index.to_h
    modified = Cleave::Inventory.new(@inventory.files.merge("different.rb" => "a" * 64))
    assert_raises(Cleave::ArtifactError) { Cleave::BitmapIndex.load(JSON.generate(index.to_h), inventory: modified) }
    assert_raises(Cleave::ArtifactError) { Cleave::Artifacts.write(directory, inventory: modified, index: index) }
    bad_inventory = @inventory.to_h.merge("fingerprint" => "0" * 64)
    assert_raises(Cleave::ArtifactError) { Cleave::Inventory.load(JSON.generate(bad_inventory)) }
    assert_raises(Cleave::ArtifactError) { Cleave::Inventory.load('{"schema":"x","schema":"y"}') }
    mutations = [
      index.to_h.merge("complete" => true),
      index.to_h.merge("version" => 99),
      index.to_h.merge("masks" => [{ "path" => "x", "hex" => "0x4" }]),
      index.to_h.merge("masks" => [{ "path" => "x", "hex" => "0x01" }]),
      index.to_h.merge("masks" => [{ "path" => "../x", "hex" => "0x1" }]),
      index.to_h.merge("specs" => ["spec/a_spec.rb", "spec/a_spec.rb"]),
      index.to_h.merge("root_paths" => ["/etc/passwd"]),
      index.to_h.merge("limitations" => []),
      index.to_h.merge("unexpected" => true)
    ]
    mutations.each { |item| assert_raises(Cleave::ArtifactError) { Cleave::BitmapIndex.load(JSON.generate(item), inventory: @inventory) } }
    File.write(File.join(directory, "inventory.json"), JSON.generate(modified.to_h))
    assert_raises(Cleave::ArtifactError) { Cleave::Artifacts.read(directory) }
    File.delete(File.join(directory, "bitmap_index.json"))
    assert_match(/artifact pair is incomplete/, assert_raises(Cleave::ArtifactError) { Cleave::Artifacts.read(directory) }.message)
  end

  def test_reject_unknown_scopes_missing_specs_and_malformed_trace_events
    assert_raises(Cleave::ArtifactError) { build([report([["spec/unknown_spec.rb", "/tmp/a", "io_read", "success"]])]) }
    assert_raises(Cleave::ArtifactError) { build([report([["spec/a_spec.rb", "config/rails.yml", "invented", "success"]])]) }
    assert_raises(Cleave::ArtifactError) { Cleave::BitmapIndex.build(inventory: @inventory, root: @root, specs: ["spec/absent_spec.rb"], reports: []) }
    assert_raises(Cleave::ArtifactError) { Cleave::BitmapIndex.build(inventory: @inventory, root: @root, specs: ["spec/a_spec.rb", "spec/a_spec.rb"], reports: []) }
    Dir.mktmpdir do |other|
      assert_raises(Cleave::ArtifactError) { build([report([], root: other)]) }
    end
    assert_includes build.limitations, "No trace reports supplied."
  end
end
