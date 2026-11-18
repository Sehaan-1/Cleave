# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "json"

# Keep the browser fixture anchored to the actual Ruby emitter and fingerprint algorithm.
class WorkbenchArtifactFixtureTest < Minitest::Test
  def test_committed_fixture_is_the_ruby_v1_artifact_pair
    specs = %w[spec/alpha_spec.rb spec/beta_spec.rb]
    inventory = Cleave::Inventory.new("app/服务.rb" => "a" * 64, "config/boot.yml" => "b" * 64,
                                      specs[0] => "c" * 64, specs[1] => "d" * 64)
    index = Cleave::BitmapIndex.new(inventory_fingerprint: inventory.fingerprint, specs: specs,
                                     masks: { "app/服务.rb" => 3, "config/missing.json" => 2 },
                                     root_paths: ["config/boot.yml"],
                                     limitations: ["Partial trace: missing native and child process access."])
    fixtures = File.expand_path("../tests/fixtures/artifacts", __dir__)
    assert_equal inventory.to_h, JSON.parse(File.read(File.join(fixtures, "inventory.json")))
    assert_equal index.to_h, JSON.parse(File.read(File.join(fixtures, "bitmap_index.json")))
  end
end
