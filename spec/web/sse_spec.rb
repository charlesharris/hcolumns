# frozen_string_literal: true

require "socket"
require "tmpdir"

# Server-Sent Events over the file-tail server: each connection projects its own
# tail of the shared read-only log (lock-free) and is pushed a {version, done}
# frame whenever the log grows — the push form of the /state poll.
RSpec.describe "Web::Server SSE (/events)" do
  AS = HColumns::Providers::AgentSession

  around { |ex| Dir.mktmpdir { |d| @path = File.join(d, "live.jsonl"); ex.run } }

  def append(*lines)
    File.open(@path, "a") { |f| lines.each { |l| f.puts(l) } }
  end

  def line(kind, payload)
    HColumns::Persistence.line_for(kind: kind, payload: payload)
  end

  # A factory like the CLI's tail_server: a fresh App tailing the file per call.
  def factory(root)
    lambda do
      graph = HColumns::Graph.new
      HColumns::Web::App.new(workspace: HColumns::Workspace.new(graph: graph), root_id: root,
                             now: FIXED_NOW, feed: HColumns::TailReader.new(@path))
    end
  end

  def start_server(root)
    server = HColumns::Web::Server.new(app_factory: factory(root), streaming: true, port: 0)
    thread = Thread.new { server.start { Thread.current[:ready] = true } }
    sleep 0.01 until server.port&.positive? && thread[:ready]
    [server, thread]
  end

  # Read `data:` frames off an open SSE socket until a done frame or the deadline.
  def read_frames(socket, until_done: true, deadline: Time.now + 3)
    buf = +""
    frames = []
    while Time.now < deadline
      break unless IO.select([socket], nil, nil, 0.2)

      chunk = socket.read_nonblock(4096, exception: false)
      break if chunk.nil?          # server closed the stream
      next if chunk == :wait_readable

      buf << chunk
      while (nl = buf.index("\n"))
        row = buf.slice!(0..nl)
        frames << JSON.parse(row.sub(/\Adata:\s*/, "").strip) if row.start_with?("data:")
      end
      break if until_done && frames.any? { |f| f["done"] }
    end
    frames
  end

  def open_events(server)
    socket = TCPSocket.new(server.host, server.port)
    socket.write("GET /events HTTP/1.1\r\nHost: x\r\n\r\n")
    socket
  end

  it "injects STREAM=true into the client shell for a streaming server (false otherwise)" do
    server, thread = start_server(AS.session_id)
    _, _, html = server.respond("GET", "/", {})
    expect(html).to include("const STREAM = true").and include("const LIVE = true")

    static = HColumns::Web::App.new(workspace: HColumns::Workspace.new(graph: HColumns::Graph.new),
                                    root_id: "x", now: FIXED_NOW)
    static_html = HColumns::Web::Server.new(static).respond("GET", "/", {}).last
    expect(static_html).to include("const STREAM = false")
  ensure
    thread&.kill
  end

  it "pushes a final done frame with the full version for an already-complete log" do
    # a whole session on disk (produced + eof), then a client connects
    io = StringIO.new
    described_producer = HColumns::LogProducer.new(AS.script(now: FIXED_NOW), io: io,
                                                   clock: -> { FIXED_NOW }, sleeper: ->(_s) {})
    described_producer.run
    append(*io.string.each_line.map(&:strip).reject(&:empty?))

    server, thread = start_server(AS.session_id)
    socket = open_events(server)
    frames = read_frames(socket)

    expect(frames).not_to be_empty
    expect(frames.last["done"]).to be(true)
    expect(frames.last["version"]).to eq(AS.script(now: FIXED_NOW).size) # every event folded
  ensure
    socket&.close
    thread&.kill
  end

  it "pushes a new frame as the log grows under an open stream" do
    a = HColumns::Node.new(type: :Session, identity: { scheme: "agent.session", key: "s1" },
                           properties: { name: "root", phase: :editing })
    append(line(:node, a)) # a root so the server can start

    server, thread = start_server(a.id)
    socket = open_events(server)

    first = read_frames(socket, until_done: false, deadline: Time.now + 2)
    expect(first.last["version"]).to eq(1)
    expect(first.last["done"]).to be(false)

    b = HColumns::Node.new(type: :SourceFile, identity: { scheme: "fs.path", key: "f" },
                           properties: { name: "f" })
    append(line(:node, b), HColumns::Persistence.eof_line) # grow, then end

    rest = read_frames(socket, deadline: Time.now + 3)
    expect(rest.last["version"]).to eq(2)
    expect(rest.last["done"]).to be(true)
  ensure
    socket&.close
    thread&.kill
  end
end
