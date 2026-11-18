# frozen_string_literal: true

require "minitest/autorun"
require "cleave"
require "cleave/ui_server"
require "tmpdir"
require "fileutils"
require "net/http"
require "open3"
require "timeout"
require "json"

class UIServerTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("cleave-ui")
    directory = File.join(@root, ".cleave")
    FileUtils.mkdir_p(directory)
    fixtures = File.expand_path("../tests/fixtures/artifacts", __dir__)
    %w[inventory.json bitmap_index.json].each { |name| FileUtils.cp(File.join(fixtures, name), directory) }
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  def request(url, path: nil, headers: {}, method: Net::HTTP::Get)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port, nil)
    http.open_timeout = 5
    http.read_timeout = 5
    req = method.new(path || uri.request_uri)
    headers.each { |name, value| req[name] = value }
    http.start { |session| session.request(req) }
  end

  def test_serves_only_snapshot_and_packaged_assets_with_loopback_guards
    server = Cleave::UIServer.new(root: @root)
    thread = Thread.new { server.start }
    begin
      uri = URI(server.url)
      assert_equal "127.0.0.1", uri.host
      assert_match(%r{\A/[0-9a-f]{64}/\z}, uri.path)
      response = request(server.url)
      assert_equal "200", response.code
      assert_includes response.body, 'name="cleave-local-ui"'
      assert_match(/frame-ancestors 'none'/, response["content-security-policy"])
      assert_equal "no-store", response["cache-control"]
      assert_equal "no-referrer", response["referrer-policy"]
      js = response.body.match(%r{src="\./(assets/[^"\s]+\.js)"})[1]
      assert_equal "200", request(server.url, path: uri.path + js).code
      inventory = request(server.url, path: uri.path + "artifacts/inventory.json")
      assert_equal "200", inventory.code
      assert_equal JSON.parse(File.read(File.join(@root, ".cleave/inventory.json"))), JSON.parse(inventory.body)
      File.write(File.join(@root, ".cleave/inventory.json"), "modified after startup")
      assert_equal inventory.body, request(server.url, path: uri.path + "artifacts/inventory.json").body
      assert_equal "404", request(server.url, path: "/artifacts/inventory.json").code
      assert_equal "404", request(server.url, path: uri.path + "artifacts/last_run.json").code
      assert_equal "404", request(server.url, path: uri.path + "assets/../../.cleave/inventory.json").code
      assert_equal "403", request(server.url, headers: { "Host" => "evil.example:#{server.port}" }).code
      assert_equal "403", request(server.url, headers: { "Origin" => "https://evil.example" }).code
      assert_equal "403", request(server.url, headers: { "Sec-Fetch-Site" => "cross-site" }).code
      assert_equal "405", request(server.url, method: Net::HTTP::Post).code
    ensure
      server.shutdown
      thread.join(5)
    end
  end

  def test_rejects_invalid_missing_symlink_and_oversized_inputs
    assert_raises(ArgumentError) { Cleave::UIServer.new(root: @root, port: 65_536) }
    index = File.join(@root, ".cleave/bitmap_index.json")
    File.delete(index)
    assert_match(/incomplete/, assert_raises(Cleave::ArtifactError) { Cleave::UIServer.new(root: @root) }.message)
    File.symlink(File.join(@root, ".cleave/inventory.json"), index)
    assert_match(/symlink/, assert_raises(Cleave::ArtifactError) { Cleave::UIServer.new(root: @root) }.message)
    File.delete(index)
    File.write(index, "a" * (Cleave::UIServer::MAX_ARTIFACT_BYTES + 1))
    assert_match(/exceeds/, assert_raises(Cleave::ArtifactError) { Cleave::UIServer.new(root: @root) }.message)
    File.write(index, "")
    assert_raises(Cleave::ArtifactError) { Cleave::UIServer.new(root: @root) }
  end

  def test_installed_gem_runs_without_node_and_serves_artifact_pair
    project = File.expand_path("..", __dir__)
    gemfile = File.join(@root, "cleave.gem")
    env = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil }
    log, status = Open3.capture2e(env, Gem.ruby, "-S", "gem", "build", "cleave.gemspec", "--output", gemfile, chdir: project)
    assert status.success?, log
    gem_home = File.join(@root, "gems")
    log, status = Open3.capture2e(env, Gem.ruby, "-S", "gem", "install", gemfile, "--local", "--ignore-dependencies", "--no-document", "--install-dir", gem_home, chdir: @root)
    assert status.success?, log
    env["GEM_HOME"] = gem_home
    env["GEM_PATH"] = ([gem_home] + Gem.path).uniq.join(File::PATH_SEPARATOR)
    env["PATH"] = "" # The command must not need Node, npm, or browser utilities.
    pid = nil
    Open3.popen2e(env, Gem.ruby, File.join(gem_home, "bin/cleave"), "ui", "--no-open", chdir: @root) do |stdin, stream, wait|
      pid = wait.pid
      stdin.close
      line = Timeout.timeout(20) { stream.gets }
      assert_match(%r{Cleave workbench: http://127\.0\.0\.1:\d+/[0-9a-f]{64}/}, line.to_s)
      url = line.split.last
      response = request(url)
      assert_equal "200", response.code
      assert_includes response.body, 'name="cleave-local-ui"'
      uri = URI(url)
      assert_equal "200", request(url, path: uri.path + "artifacts/bitmap_index.json").code
      Process.kill("INT", pid)
      Timeout.timeout(10) { wait.value }
      pid = nil
    end
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end
