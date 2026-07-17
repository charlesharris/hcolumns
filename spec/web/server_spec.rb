# frozen_string_literal: true

require "net/http"

# The routing is a pure function, so most of it is testable without a socket. One
# end-to-end case actually binds an ephemeral port to prove the HTTP framing.
RSpec.describe HColumns::Web::Server do
  def now = FIXED_NOW

  let(:graph) { HColumns::Providers::InMemoryFixture.build(now: now) }
  let(:workspace) { HColumns::Workspace.new(graph: graph) }
  let(:orders_id) { HColumns::Providers::InMemoryFixture.orders_id }
  let(:app) { HColumns::Web::App.new(workspace: workspace, root_id: orders_id, now: now) }
  let(:server) { described_class.new(app) }

  describe "#respond (pure router)" do
    it "serves the client shell at / with the root id patched in" do
      status, type, body = server.respond("GET", "/", {})
      expect(status).to eq(200)
      expect(type).to include("text/html")
      expect(body).to include(orders_id)        # window ROOT_ID injected
      expect(body).to include("<title>hcolumns")
    end

    it "serves a node's panel JSON at /panel" do
      status, type, body = server.respond("GET", "/panel", { "id" => orders_id })
      expect(status).to eq(200)
      expect(type).to eq("application/json")
      expect(JSON.parse(body)["node"]["id"]).to eq(orders_id)
    end

    it "honors the mode query param" do
      _, _, body = server.respond("GET", "/panel", { "id" => orders_id, "mode" => "details" })
      expect(JSON.parse(body)["mode"]).to eq("details")
    end

    it "404s an unknown node with a JSON error body" do
      status, type, body = server.respond("GET", "/panel", { "id" => "obj:nope" })
      expect(status).to eq(404)
      expect(type).to eq("application/json")
      expect(JSON.parse(body)).to include("error" => "no such node")
    end

    it "404s an unknown path and 405s a non-GET method" do
      expect(server.respond("GET", "/favicon.ico", {}).first).to eq(404)
      expect(server.respond("POST", "/", {}).first).to eq(405)
    end

    it "routes /dispatch and /ask to the app, 404ing when there's no dispatcher" do
      # This app has no dispatcher (static serve), so both refuse with a JSON error.
      expect(server.respond("GET", "/dispatch", { "id" => orders_id }).first).to eq(404)
      expect(server.respond("GET", "/ask", { "prompt" => "hi" }).first).to eq(404)
    end

    it "returns the dispatch receipt as JSON when a dispatcher is wired" do
      dispatcher = instance_double(HColumns::Dispatcher, ask: { ok: true, queued: "ask" })
      wired = HColumns::Web::App.new(workspace: workspace, root_id: orders_id, now: now, dispatcher: dispatcher)
      status, type, body = described_class.new(wired).respond("GET", "/ask", { "prompt" => "summarize" })

      expect(status).to eq(200)
      expect(type).to eq("application/json")
      expect(JSON.parse(body)).to include("ok" => true, "queued" => "ask")
    end
  end

  describe "over a real socket" do
    it "binds, serves the panel JSON, and frames a proper HTTP response" do
      bound = described_class.new(app, port: 0)
      thread = Thread.new { bound.start { Thread.current[:ready] = true } }
      sleep 0.01 until bound.port && bound.port.positive? && thread[:ready]

      uri = URI("http://#{bound.host}:#{bound.port}/panel?id=#{URI.encode_www_form_component(orders_id)}")
      response = Net::HTTP.get_response(uri)

      expect(response.code).to eq("200")
      expect(response["content-type"]).to eq("application/json")
      expect(JSON.parse(response.body)["node"]["id"]).to eq(orders_id)
    ensure
      thread&.kill
    end
  end
end
