# frozen_string_literal: true

require "socket"
require "json"
require "uri"

module HColumns
  module Web
    # A dependency-free HTTP front-end over an App. Raw TCPServer — no webrick,
    # rack, or sinatra — so `hcol` stays runtime-dependency-free like the rest of
    # the project (the TUI is hand-rolled raw mode for the same reason). Two real
    # routes: `/` serves the static columns client, `/panel?id=&mode=` serves the
    # Serializer JSON the client fetches to render a column and descend.
    #
    # The routing is a pure function (`respond`) returning [status, type, body];
    # only `serve_one` touches the socket. That split keeps the interesting part
    # testable without binding a port.
    class Server
      STATUS_TEXT = { 200 => "OK", 404 => "Not Found", 405 => "Method Not Allowed" }.freeze

      attr_reader :host, :port

      def initialize(app, host: "127.0.0.1", port: 4567)
        @app = app
        @host = host
        @port = port
      end

      # (method, path, query-hash) -> [status, content_type, body]. No I/O.
      def respond(method, path, query)
        return [405, "text/plain", "method not allowed\n"] unless method == "GET"

        case path
        when "/" then [200, "text/html; charset=utf-8", index_html]
        when "/root" then json_response(@app.root)
        when "/panel"
          id = query["id"]
          json_response(id && @app.panel(id, mode: query["mode"]),
                        missing: { error: "no such node", id: id })
        else
          [404, "text/plain", "not found\n"]
        end
      end

      # Bind and serve forever. Yields self once bound (port resolved) so a caller
      # — or a test — can learn the actual port when 0 was requested.
      def start
        server = TCPServer.new(@host, @port)
        @port = server.addr[1]
        yield self if block_given?
        loop { serve_one(server) }
      ensure
        server&.close
      end

      private

      def serve_one(server)
        socket = server.accept
        method, target = parse_request(socket)
        if method
          path, query = split_target(target)
          status, type, body = respond(method, path, query)
          write_response(socket, status, type, body)
        end
      rescue StandardError
        # a single malformed connection shouldn't take the server down
      ensure
        socket&.close
      end

      def parse_request(socket)
        request_line = socket.gets
        return [nil, nil] unless request_line

        method, target, = request_line.split(" ", 3)
        while (line = socket.gets) # drain headers; we serve GET only, no body
          break if line == "\r\n" || line == "\n"
        end
        [method, target]
      end

      def split_target(target)
        path, query_string = target.to_s.split("?", 2)
        query = query_string ? URI.decode_www_form(query_string).to_h : {}
        [path, query]
      end

      def write_response(socket, status, content_type, body)
        bytes = body.to_s
        socket.write("HTTP/1.1 #{status} #{STATUS_TEXT[status] || 'OK'}\r\n")
        socket.write("Content-Type: #{content_type}\r\n")
        socket.write("Content-Length: #{bytes.bytesize}\r\n")
        socket.write("Connection: close\r\n\r\n")
        socket.write(bytes)
      end

      def json_response(hash, missing: { error: "not found" })
        return [404, "application/json", JSON.generate(missing)] unless hash

        [200, "application/json", JSON.generate(hash)]
      end

      def index_html
        INDEX_HTML.sub("__ROOT_ID__", @app.root_id.to_s)
      end

      # The whole client, inline. Single-quoted heredoc so the JS `${}` template
      # literals are left untouched; the one dynamic value (the root node id) is
      # patched in via `sub` above.
      INDEX_HTML = <<~'HTML'
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>hcolumns — web</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body {
            margin: 0; font: 13px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
            background: #14161c; color: #c9d1d9; height: 100vh;
            display: flex; flex-direction: column;
          }
          header {
            padding: 8px 14px; border-bottom: 1px solid #262b36;
            color: #8b949e; flex: 0 0 auto;
          }
          header b { color: #d2a8ff; }
          #board {
            flex: 1 1 auto; display: flex; align-items: stretch;
            overflow-x: auto; overflow-y: hidden;
          }
          .col {
            flex: 0 0 24em; min-width: 24em; overflow-y: auto;
            border-right: 1px solid #262b36; padding: 6px 0;
          }
          .col-head {
            padding: 4px 12px 8px; color: #e6edf3; font-weight: 600;
            position: sticky; top: 0; background: #14161c;
          }
          .col-head .type {
            color: #7ee787; font-weight: 400; font-size: 11px;
            text-transform: uppercase; letter-spacing: .04em;
          }
          .tabs { padding: 0 8px 8px; display: flex; flex-wrap: wrap; gap: 4px; }
          .tab {
            cursor: pointer; padding: 1px 8px; border-radius: 10px;
            border: 1px solid #30363d; color: #8b949e; font-size: 11px;
          }
          .tab:hover { border-color: #58a6ff; color: #c9d1d9; }
          .tab.active { background: #1f6feb33; border-color: #1f6feb; color: #58a6ff; }
          .sec-head {
            padding: 8px 12px 2px; color: #f0883e; font-size: 11px;
            text-transform: uppercase; letter-spacing: .04em;
          }
          .line { padding: 1px 12px; color: #8b949e; white-space: pre; }
          .item {
            padding: 2px 12px; cursor: pointer; display: flex;
            gap: 8px; align-items: baseline;
          }
          .item:hover { background: #1c2129; }
          .item.sel { background: #1f6feb22; }
          .glyph { color: #d2a8ff; width: 1em; flex: 0 0 auto; }
          .label { flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .bar { color: #3fb950; font-size: 10px; letter-spacing: -1px; flex: 0 0 auto; }
          #dock {
            flex: 0 0 auto; max-height: 30vh; overflow: auto;
            border-top: 1px solid #262b36; background: #0f1116;
            padding: 8px 14px; white-space: pre-wrap; color: #adbac7;
          }
          #dock:empty { display: none; }
        </style>
        </head>
        <body>
        <header><b>hcolumns</b> — click an item to descend · tabs are the node's modes</header>
        <div id="board"></div>
        <pre id="dock"></pre>
        <script>
        const ROOT_ID = "__ROOT_ID__";
        const board = document.getElementById('board');
        const dock = document.getElementById('dock');

        function esc(s) {
          return String(s).replace(/[&<>"]/g, c =>
            ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
        }

        function bar(c) {
          if (c == null) return '';
          const n = Math.max(0, Math.min(10, Math.round(c * 10)));
          return '█'.repeat(n) + '░'.repeat(10 - n);
        }

        async function fetchPanel(id, mode) {
          const u = new URL('/panel', location.origin);
          u.searchParams.set('id', id);
          if (mode) u.searchParams.set('mode', mode);
          const r = await fetch(u);
          return r.ok ? r.json() : null;
        }

        function selectItem(row, it) {
          document.querySelectorAll('.item.sel').forEach(e => e.classList.remove('sel'));
          row.classList.add('sel');
          const lines = (it.detail && it.detail.length) ? it.detail : (it.reason ? [it.reason] : []);
          dock.textContent = lines.join('\n');
        }

        function renderColumn(panel, depth) {
          const col = document.createElement('div');
          col.className = 'col';

          const head = document.createElement('div');
          head.className = 'col-head';
          head.innerHTML = `<span class="type">${esc(panel.node.type)}</span> ${esc(panel.node.name)}`;
          col.appendChild(head);

          const tabs = document.createElement('div');
          tabs.className = 'tabs';
          (panel.modes || []).forEach(m => {
            const t = document.createElement('span');
            t.className = 'tab' + (m === panel.mode ? ' active' : '');
            t.textContent = m;
            t.onclick = () => openColumn(panel.node.id, m, depth);
            tabs.appendChild(t);
          });
          col.appendChild(tabs);

          (panel.sections || []).forEach(s => {
            if (s.heading) {
              const sh = document.createElement('div');
              sh.className = 'sec-head';
              sh.textContent = s.heading;
              col.appendChild(sh);
            }
            (s.lines || []).forEach(line => {
              const l = document.createElement('div');
              l.className = 'line';
              l.textContent = line;
              col.appendChild(l);
            });
            (s.items || []).forEach(it => {
              const row = document.createElement('div');
              row.className = 'item';
              row.innerHTML =
                `<span class="glyph">${esc(it.glyph || '•')}</span>` +
                `<span class="label">${esc(it.label)}</span>` +
                `<span class="bar">${bar(it.confidence)}</span>`;
              row.onclick = () => {
                selectItem(row, it);
                if (it.target_id) openColumn(it.target_id, null, depth + 1);
              };
              col.appendChild(row);
            });
          });
          return col;
        }

        async function openColumn(id, mode, depth) {
          while (board.children.length > depth) board.removeChild(board.lastChild);
          const panel = await fetchPanel(id, mode);
          if (!panel) return;
          board.appendChild(renderColumn(panel, depth));
          board.scrollLeft = board.scrollWidth;
        }

        openColumn(ROOT_ID, null, 0);
        </script>
        </body>
        </html>
      HTML
    end
  end
end
