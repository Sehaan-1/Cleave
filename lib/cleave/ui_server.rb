# frozen_string_literal: true

require "webrick"
require "securerandom"
require "rbconfig"
require_relative "artifacts"

module Cleave
  # Read-only, loopback-only server for a validated immutable artifact snapshot.
  class UIServer
    MAX_ARTIFACT_BYTES = 10 * 1024 * 1024
    CONTENT_TYPES = { ".js" => "text/javascript; charset=utf-8", ".css" => "text/css; charset=utf-8",
                      ".woff2" => "font/woff2", ".svg" => "image/svg+xml", ".png" => "image/png" }.freeze
    CSP = "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; " \
          "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    attr_reader :url, :port

    def initialize(root:, port: 0)
      raise ArgumentError, "port must be an integer from 0 to 65535" unless port.is_a?(Integer) && port.between?(0, 65_535)
      root = File.realpath(root)
      state = File.join(root, ".cleave")
      raise ArtifactError, ".cleave must be a real directory, not a symlink" if File.symlink?(state) || !File.directory?(state)
      inventory_text = read_artifact(File.join(state, "inventory.json"))
      index_text = read_artifact(File.join(state, "bitmap_index.json"))
      inventory = Inventory.load(inventory_text)
      BitmapIndex.load(index_text, inventory: inventory)
      public_dir = File.expand_path("../../public", __dir__)
      index_path = File.join(public_dir, "index.html")
      raise ArtifactError, "packaged workbench assets are missing; rebuild or reinstall the gem" unless File.file?(index_path)
      html = File.binread(index_path)
      raise ArtifactError, "invalid packaged workbench" unless html.include?("</head>")
      html = html.sub("</head>", "<meta name=\"cleave-local-ui\" content=\"1\"></head>")
      @responses = { "" => ["text/html; charset=utf-8", html],
                     "artifacts/inventory.json" => ["application/json; charset=utf-8", inventory_text],
                     "artifacts/bitmap_index.json" => ["application/json; charset=utf-8", index_text] }
      assets = File.join(public_dir, "assets")
      raise ArtifactError, "packaged workbench assets are missing" unless File.directory?(assets) && !File.symlink?(assets)
      Dir.children(assets).sort.each do |name|
        next unless name.match?(/\A[A-Za-z0-9_.-]+\z/) && CONTENT_TYPES.key?(File.extname(name))
        path = File.join(assets, name)
        raise ArtifactError, "invalid packaged asset: #{name}" if File.symlink?(path) || !File.file?(path)
        @responses["assets/#{name}"] = [CONTENT_TYPES.fetch(File.extname(name)), File.binread(path)]
      end
      @responses.freeze
      @token = SecureRandom.hex(32)
      @server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: port, AccessLog: [],
                                        Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL),
                                        DoNotReverseLookup: true, RequestTimeout: 5, MaxClients: 16)
      @port = @server.listeners.fetch(0).addr[1]
      @origin = "http://127.0.0.1:#{@port}"
      @url = "#{@origin}/#{@token}/"
      @server.mount_proc("/") { |req, res| respond(req, res) }
    end

    def start
      @server.start
    ensure
      @server.shutdown
    end

    def shutdown
      @server.shutdown
    end

    def open_browser
      os = RbConfig::CONFIG["host_os"]
      command = if os.match?(/darwin/i)
        "open"
      elsif os.match?(/linux/i) && (ENV["DISPLAY"] || ENV["WAYLAND_DISPLAY"])
        "xdg-open"
      end
      Process.detach(Process.spawn(command, url, out: File::NULL, err: File::NULL)) if command
    rescue SystemCallError
      nil # Printed URL remains usable if no browser launcher exists.
    end

    private

    def read_artifact(path)
      raise ArtifactError, "artifact must not be a symlink: #{File.basename(path)}" if File.symlink?(path)
      raise ArtifactError, "artifact must be a regular file: #{File.basename(path)}" unless File.lstat(path).file?
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      flags |= File::NONBLOCK if File.const_defined?(:NONBLOCK)
      File.open(path, flags) do |file|
        raise ArtifactError, "artifact must be a regular file: #{File.basename(path)}" unless file.stat.file?
        content = file.read(MAX_ARTIFACT_BYTES + 1) || ""
        raise ArtifactError, "artifact exceeds 10 MiB: #{File.basename(path)}" if content.bytesize > MAX_ARTIFACT_BYTES
        content.force_encoding(Encoding::UTF_8)
        raise ArtifactError, "artifact is not UTF-8: #{File.basename(path)}" unless content.valid_encoding?
        content.freeze
      end
    rescue Errno::ENOENT
      raise ArtifactError, "artifact pair is incomplete: missing #{File.basename(path)}"
    end

    def respond(req, res)
      res["Cache-Control"] = "no-store"
      res["X-Content-Type-Options"] = "nosniff"
      res["Referrer-Policy"] = "no-referrer"
      res["Content-Security-Policy"] = CSP
      res["Cross-Origin-Resource-Policy"] = "same-origin"
      res["X-Frame-Options"] = "DENY"
      unless req["host"] == "127.0.0.1:#{port}" && (!req["origin"] || req["origin"] == @origin) && req["sec-fetch-site"] != "cross-site"
        res.status = 403
        res.body = "Forbidden"
        return
      end
      unless %w[GET HEAD].include?(req.request_method)
        res.status = 405
        res["Allow"] = "GET, HEAD"
        res.body = "Method not allowed"
        return
      end
      prefix = "/#{@token}/"
      entry = req.path.start_with?(prefix) && @responses[req.path.delete_prefix(prefix)]
      if entry
        res["Content-Type"] = entry[0]
        res.body = entry[1]
      else
        res.status = 404
        res.body = "Not found"
      end
    end
  end
end
