# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "tmpdir"
require "fileutils"
require "json"
require "open3"

class GraphExportTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-graph")
    @specs = %w[spec/a_spec.rb spec/b_spec.rb]
    @danger = "lib/</script><script>evil()</script>.rb"
    @inventory = Cleave::Inventory.new((@specs + ["lib/a.rb"]).to_h { |path| [path, "a" * 64] })
    @index = Cleave::BitmapIndex.new(inventory_fingerprint: @inventory.fingerprint, specs: @specs,
                                     masks: { @danger => 2, "lib/a.rb" => 3 }, root_paths: ["config/missing.yml", "lib/a.rb"],
                                     limitations: ["partial <script> & \u2028 data"])
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def render
    Cleave::GraphExport.render(inventory: @inventory, index: @index)
  end

  def test_render_preserves_masks_root_scope_and_absent_paths_without_html_injection
    html = render
    data = JSON.parse(html.match(/const data = (.*);/)[1])
    assert_equal @specs, data.fetch("specs")
    assert_equal @inventory.fingerprint, data.fetch("fingerprint")
    assert_equal ["config/missing.yml", @danger, "lib/a.rb"].sort, data.fetch("files").map { |file| file.fetch("path") }
    assert_equal({ "path" => "lib/a.rb", "hex" => "0x3", "root" => true, "in_inventory" => true }, data.fetch("files").find { |f| f["path"] == "lib/a.rb" })
    refute data.fetch("files").find { |f| f["path"] == @danger }.fetch("in_inventory")
    assert_equal ["partial <script> & \u2028 data"], data.fetch("limitations")
    refute_includes html, "</script><script>evil()"
    refute_includes html, "partial <script>"
    assert_includes html, "Incomplete index"
  end

  def test_revalidates_artifacts_and_supports_empty_indexes
    wrong = Cleave::Inventory.new(@inventory.files.merge("other.rb" => "b" * 64))
    assert_raises(Cleave::ArtifactError) { Cleave::GraphExport.render(inventory: wrong, index: @index) }
    index = Cleave::BitmapIndex.new(inventory_fingerprint: @inventory.fingerprint, specs: [], masks: {}, root_paths: [], limitations: ["no observations"])
    data = JSON.parse(Cleave::GraphExport.render(inventory: @inventory, index: index).match(/const data = (.*);/)[1])
    assert_empty data["files"]
    assert_empty data["specs"]
    assert_raises(ArgumentError) { Cleave::GraphExport.render(inventory: nil, index: @index) }
  end

  def test_atomic_output_rejects_symlinks_and_invalid_targets
    output = File.join(@root, "graph.html")
    assert_equal output, Cleave::GraphExport.write(output, inventory: @inventory, index: @index)
    assert_equal render, File.read(output)
    File.write(output, "old")
    Cleave::GraphExport.write(output, inventory: @inventory, index: @index)
    assert_equal render, File.read(output)
    File.delete(output)
    victim = File.join(@root, "victim")
    File.write(victim, "safe")
    File.symlink(victim, output)
    assert_raises(Cleave::ArtifactError) { Cleave::GraphExport.write(output, inventory: @inventory, index: @index) }
    assert_equal "safe", File.read(victim)
    assert_raises(ArgumentError) { Cleave::GraphExport.write(File.join(@root, "graph.txt"), inventory: @inventory, index: @index) }
    Dir.mkdir(File.join(@root, "directory.html"))
    assert_raises(Cleave::ArtifactError) { Cleave::GraphExport.write(File.join(@root, "directory.html"), inventory: @inventory, index: @index) }
    assert_empty Dir.glob(File.join(@root, ".cleave-graph-*.tmp"))
  end

  def test_cli_from_bundled_project_and_packaged_template
    project = File.expand_path("..", __dir__)
    assert_includes Gem::Specification.load(File.join(project, "cleave.gemspec")).files, "lib/cleave/graph_template.html"
    File.write(File.join(@root, "Gemfile"), "source 'https://rubygems.org'\ngem 'cleave-ste', path: #{project.inspect}\n")
    env = { "BUNDLE_GEMFILE" => File.join(@root, "Gemfile"), "BUNDLE_FROZEN" => "false" }
    output, status = Open3.capture2e(env, "bundle", "lock", "--local", chdir: @root)
    assert status.success?, output
    Cleave::Artifacts.write(File.join(@root, ".cleave"), inventory: @inventory, index: @index)
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "graph", "--output", "graph.html", chdir: @root)
    assert status.success?, output
    assert_match(/incomplete index; do not use to skip tests/, output)
    assert_equal render, File.read(File.join(@root, "graph.html"))
    File.delete(File.join(@root, ".cleave/bitmap_index.json"))
    output, status = Open3.capture2e(env, "bundle", "exec", "cleave", "graph", "--output", "other.html", chdir: @root)
    assert_equal 2, status.exitstatus, output
    assert_match(/artifact pair is incomplete/, output)
    refute File.exist?(File.join(@root, "other.html"))
  end
end
