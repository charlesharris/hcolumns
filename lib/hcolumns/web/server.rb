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
      STREAM_POLL = 0.3 # seconds between SSE pushes while a stream is open

      attr_reader :host, :port

      # Three ways in, all resolving to an AppSource (the concurrency seam — see
      # app_source.rb). `Server.new(app)` wraps one shared App in a Single source
      # (static serve, or the in-memory Feed demo — single-threaded, /state poll).
      # `Server.new(app_factory:, streaming: true)` wraps the factory in a
      # PerConnection source: each connection projects its own graph from the
      # shared read-only sources, so a long-lived /events stream beside /panel
      # fetches shares no mutable state and needs no lock. `apps:` passes any
      # source directly — how a mutex-based shared strategy would plug in.
      def initialize(app = nil, host: "127.0.0.1", port: 4567, app_factory: nil,
                     streaming: false, apps: nil)
        @apps = apps ||
                (app_factory ? AppSource::PerConnection.new(app_factory) : AppSource::Single.new(app))
        @streaming = streaming
        @host = host
        @port = port
        sample = @apps.checkout # a representative app for the shell (root id + flags)
        @root_id = sample.root_id
        @live = sample.live?
        @dispatch = sample.respond_to?(:dispatch_available?) && sample.dispatch_available?
        @execute = sample.respond_to?(:execution_available?) && sample.execution_available?
      end

      def live?
        @live
      end

      # (method, path, query-hash) -> [status, content_type, body]. The only
      # side effect is the live pump: a live App releases any due events before it
      # answers, so every request — a poll or a descend — sees the current graph
      # (single-writer, request-driven; no background thread).
      def respond(method, path, query)
        return [405, "text/plain", "method not allowed\n"] unless method == "GET"

        app = @apps.checkout
        app.pump if app.live?

        case path
        when "/" then [200, "text/html; charset=utf-8", index_html]
        when "/root" then json_response(app.root)
        when "/state" then json_response({ version: app.version, done: app.done? })
        when "/panel"
          id = query["id"]
          json_response(id && app.panel(id, mode: query["mode"]),
                        missing: { error: "no such node", id: id })
        when "/flag"
          id = query["id"]
          json_response(id && app.flag(id, query["level"]),
                        missing: { error: "no such node or level", id: id })
        when "/dispatch"
          id = query["id"]
          json_response(id && app.dispatch(id),
                        missing: { error: "no such suggestion, no fix to hand off, or dispatch unavailable", id: id })
        when "/ask"
          json_response(app.ask(query["prompt"]),
                        missing: { error: "empty prompt or dispatch unavailable" })
        when "/retry"
          key = query["key"]
          json_response(key && app.retry_task(key),
                        missing: { error: "no such failed task, or execution not enabled (--dispatch)", key: key })
        when "/review"
          key = query["key"]
          json_response(key && app.review(key),
                        missing: { error: "no branch for this task", key: key })
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
        # A streaming server holds /events connections open, so each connection gets
        # its own thread; otherwise the accept loop would block on the first stream.
        # The static/Feed server has only short requests and stays single-threaded.
        loop do
          socket = server.accept
          @streaming ? Thread.new { handle(socket) } : handle(socket)
        end
      ensure
        server&.close
      end

      private

      def handle(socket)
        method, target = parse_request(socket)
        return unless method

        path, query = split_target(target)
        if @streaming && method == "GET" && path == "/events"
          stream_events(socket)
        else
          status, type, body = respond(method, path, query)
          write_response(socket, status, type, body)
        end
      rescue StandardError
        # a single malformed/aborted connection shouldn't take the server (or a
        # connection thread) down
      ensure
        socket&.close
      end

      # Server-Sent Events: a long-lived connection that projects its OWN tail of
      # the shared read-only log (no shared mutable state → no lock) and pushes a
      # compact {version, done} frame whenever the log grows — the push form of the
      # /state poll. The client re-fetches its open /panel columns on each frame.
      def stream_events(socket)
        socket.write("HTTP/1.1 200 OK\r\n" \
                     "Content-Type: text/event-stream\r\n" \
                     "Cache-Control: no-cache\r\n" \
                     "Connection: keep-alive\r\n\r\n")
        socket.flush
        app = @apps.checkout # held for the stream's life: its tail advances incrementally
        last = nil
        loop do
          app.pump if app.live?
          version = app.version
          done = app.done?
          if version != last || done
            socket.write("data: #{JSON.generate(version: version, done: done)}\n\n")
            socket.flush
            last = version
          end
          break if done

          sleep(STREAM_POLL)
        end
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
        INDEX_HTML.sub("__ROOT_ID__", @root_id.to_s)
                  .sub("__LIVE__", @live.to_s)
                  .sub("__STREAM__", @streaming.to_s)
                  .sub("__DISPATCH__", @dispatch.to_s)
                  .sub("__EXECUTE__", @execute.to_s)
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
          header .live { color: #3fb950; margin-left: 8px; }
          @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: .35; } }
          header .live.on { animation: pulse 1.4s ease-in-out infinite; }
          #board {
            flex: 1 1 auto; display: flex; align-items: stretch;
            overflow-x: auto; overflow-y: hidden;
          }
          .col {
            flex: 0 0 24em; min-width: 24em; overflow: auto;
            border-right: 1px solid #262b36; padding: 6px 0;
          }
          .col.blamecol { flex-basis: 48em; min-width: 48em; } /* blame wants room */
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
          .act {
            display: inline-block; margin: 6px 12px 0; cursor: pointer;
            padding: 2px 10px; border-radius: 10px; font-size: 11px;
            border: 1px solid #2ea04366; color: #3fb950; background: #2ea04314;
          }
          .act:hover { border-color: #3fb950; background: #2ea04326; }
          .act.busy { opacity: .5; cursor: default; }
          .ask { display: inline-flex; gap: 6px; margin-left: 12px; vertical-align: middle; }
          .ask input {
            width: 22em; padding: 2px 8px; font: inherit; color: #c9d1d9;
            background: #0f1116; border: 1px solid #30363d; border-radius: 10px;
          }
          .ask input:focus { outline: none; border-color: #58a6ff; }
          .ask button {
            padding: 2px 10px; font: inherit; font-size: 11px; cursor: pointer;
            color: #3fb950; background: #2ea04314; border: 1px solid #2ea04366; border-radius: 10px;
          }
          .ask button:hover { border-color: #3fb950; }
          .sec-head {
            padding: 8px 12px 2px; color: #f0883e; font-size: 11px;
            text-transform: uppercase; letter-spacing: .04em;
          }
          .line { padding: 1px 12px; color: #8b949e; white-space: pre; }
          .line.add { color: #3fb950; }
          .line.del { color: #f85149; }
          .line.hunk { color: #58a6ff; }
          .line.meta { color: #6e7681; }
          .item {
            padding: 2px 12px; cursor: pointer; display: flex;
            gap: 8px; align-items: baseline;
          }
          .item:hover { background: #1c2129; }
          .item.sel { background: #1f6feb22; }
          .glyph { color: #d2a8ff; width: 1em; flex: 0 0 auto; }
          .label { flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .bar { color: #3fb950; font-size: 10px; letter-spacing: -1px; flex: 0 0 auto; }
          /* blame rows: a muted sha column + the code line (indentation preserved) */
          .item.blame { gap: 12px; }
          .item.blame .sha { color: #6e7681; flex: 0 0 auto; font-variant-numeric: tabular-nums; }
          .item.blame.uncommitted .sha { color: #d29922; }
          .item.blame .code {
            flex: 1 1 auto; white-space: pre; overflow: hidden;
            text-overflow: ellipsis; color: #adbac7;
          }
          #dock {
            flex: 0 0 auto; max-height: 30vh; overflow: auto;
            border-top: 1px solid #262b36; background: #0f1116;
            padding: 8px 14px; white-space: pre-wrap; color: #adbac7;
          }
          #dock:empty { display: none; }
        </style>
        </head>
        <body>
        <header><b>hcolumns</b> — click an item to descend · tabs are the node's modes<span id="livebadge"></span><span id="askbox"></span></header>
        <div id="board"></div>
        <pre id="dock"></pre>
        <script>
        const ROOT_ID = "__ROOT_ID__";
        const LIVE = __LIVE__;
        const STREAM = __STREAM__;
        const DISPATCH = __DISPATCH__; // a bridge log is here — clicks can queue work
        const EXECUTE = __EXECUTE__;   // --dispatch is on — a queued request will actually RUN
        const board = document.getElementById('board');
        const dock = document.getElementById('dock');
        const columns = []; // {id, mode} per open column, parallel to board.children

        function esc(s) {
          return String(s).replace(/[&<>"]/g, c =>
            ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
        }

        function bar(c) {
          if (c == null) return '';
          const n = Math.max(0, Math.min(10, Math.round(c * 10)));
          return '█'.repeat(n) + '░'.repeat(10 - n);
        }

        // diff lines get +/-/@@ coloring, but only inside a gitdiff panel so a
        // markdown bullet ('- item') in a source listing isn't mistaken for a del.
        function lineClass(line, mode) {
          if (mode !== 'gitdiff') return 'line';
          if (line.startsWith('+')) return 'line add';
          if (line.startsWith('-')) return 'line del';
          if (line.startsWith('@@')) return 'line hunk';
          if (/^(diff |index |commit |Author:|Date:)/.test(line)) return 'line meta';
          return 'line';
        }

        async function fetchPanel(id, mode) {
          const u = new URL('/panel', location.origin);
          u.searchParams.set('id', id);
          if (mode) u.searchParams.set('mode', mode);
          const r = await fetch(u);
          return r.ok ? r.json() : null;
        }

        let selected = null; // the last-clicked item — what the flag keys act on

        function selectItem(row, it) {
          document.querySelectorAll('.item.sel').forEach(e => e.classList.remove('sel'));
          row.classList.add('sel');
          selected = it;
          const lines = (it.detail && it.detail.length) ? it.detail : (it.reason ? [it.reason] : []);
          dock.textContent = lines.join('\n');
        }

        // Flag the selected item's target: - down, +/= up, x exclude, u clear
        // (same keys as the TUI). The flag lands as an event server-side; every
        // open column re-fetches so the re-ranking shows immediately.
        document.addEventListener('keydown', async (e) => {
          const level = { '-': 'down', '+': 'up', '=': 'up', 'x': 'exclude', 'u': 'clear' }[e.key];
          if (!level || !selected || !selected.target_id) return;
          const u = new URL('/flag', location.origin);
          u.searchParams.set('id', selected.target_id);
          u.searchParams.set('level', level);
          const r = await fetch(u);
          if (r.ok) refreshOpen();
        });

        // Queue work: hit a dispatch URL, then refresh the open columns so the new
        // Request node shows immediately. Guards against a double-click while in
        // flight. The button (or ask input) is passed so it can show a busy state.
        async function queue(el, url) {
          if (el.classList.contains('busy')) return;
          el.classList.add('busy');
          try {
            const r = await fetch(url);
            if (r.ok) { liveVersion = -1; await refreshOpen(); }
          } finally {
            el.classList.remove('busy');
          }
        }

        // The ask box (only when a bridge log is here): queue an arbitrary prompt,
        // the browser echo of `hcol ask`. Enter or the button submits.
        function initAsk() {
          if (!DISPATCH) return;
          const box = document.getElementById('askbox');
          box.className = 'ask';
          box.innerHTML = '<input placeholder="ask… (queues a request)"><button>queue</button>';
          const input = box.querySelector('input');
          const submit = async () => {
            const prompt = input.value.trim();
            if (!prompt) return;
            await queue(input, new URL('/ask?prompt=' + encodeURIComponent(prompt), location.origin));
            input.value = '';
          };
          box.querySelector('button').onclick = submit;
          input.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
        }

        function renderColumn(panel, depth) {
          const col = document.createElement('div');
          col.className = 'col' + (panel.mode === 'blame' ? ' blamecol' : '');

          const head = document.createElement('div');
          head.className = 'col-head';
          head.innerHTML = `<span class="type">${esc(panel.node.type)}</span> ${esc(panel.node.name)}`;
          col.appendChild(head);

          // A Suggestion with a fix gets a one-click "dispatch fix" — it queues a
          // Request on the bridge log (the browser echo of `hcol fix`), which appears
          // in the columns on the next frame. Queue only; nothing runs from here.
          const props = panel.node.properties || {};
          if (DISPATCH && panel.node.type === 'Suggestion' && props.fix) {
            const btn = document.createElement('span');
            btn.className = 'act';
            btn.textContent = '▷ dispatch fix';
            btn.onclick = () => queue(btn, new URL('/dispatch?id=' + encodeURIComponent(panel.node.id), location.origin));
            col.appendChild(btn);
          }

          // A FAILED task gets a retry — user-initiated by design: nothing auto-retries
          // a stall, so this is the human seeing the failure and choosing to re-run.
          // The retry is a fresh second task on the same Request; history isn't rewritten.
          if (EXECUTE && panel.node.type === 'LLMTask' && props.state === 'failed' && props.task_key) {
            const btn = document.createElement('span');
            btn.className = 'act';
            btn.textContent = '↻ retry';
            btn.onclick = () => queue(btn, new URL('/retry?key=' + encodeURIComponent(props.task_key), location.origin));
            col.appendChild(btn);
          }

          // A finished isolated task left a branch behind. REVIEW-ONLY: this shows what
          // to merge and never merges it — a browser click must not touch the working
          // tree. Fetched lazily so a repo question stays off the render path.
          if (EXECUTE && panel.node.type === 'LLMTask' && props.task_key) {
            const note = document.createElement('span');
            note.className = 'act';
            note.textContent = '⎇ review branch';
            note.onclick = async () => {
              const r = await fetch(new URL('/review?key=' + encodeURIComponent(props.task_key), location.origin));
              if (!r.ok) { note.textContent = '⎇ no branch yet'; return; }
              const rev = await r.json();
              dock.textContent = `${rev.branch}\n${rev.diffstat}\n\n` +
                (rev.commits || []).map(c => `${c.sha.slice(0, 8)} ${c.subject}`).join('\n') +
                `\n\n(review only — merge it yourself: git merge ${rev.branch})`;
            };
            col.appendChild(note);
          }

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
              l.className = lineClass(line, panel.mode);
              l.textContent = line;
              col.appendChild(l);
            });
            (s.items || []).forEach(it => {
              const row = document.createElement('div');
              // Blame rows read fugitive-style: a muted sha column + the code line;
              // the author/date/summary lives in the dock on select. Other items
              // keep the glyph + label + confidence-bar layout.
              if (panel.mode === 'blame') {
                row.className = 'item blame' + (it.target_id ? '' : ' uncommitted');
                row.innerHTML =
                  `<span class="sha">${esc(it.glyph || '')}</span>` +
                  `<span class="code">${esc(it.label)}</span>`;
              } else {
                row.className = 'item';
                row.innerHTML =
                  `<span class="glyph">${esc(it.glyph || '•')}</span>` +
                  `<span class="label">${esc(it.label)}</span>` +
                  `<span class="bar">${bar(it.confidence)}</span>`;
              }
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
          while (board.children.length > depth) { board.removeChild(board.lastChild); columns.pop(); }
          const panel = await fetchPanel(id, mode);
          if (!panel) return;
          columns[depth] = { id, mode };
          board.appendChild(renderColumn(panel, depth));
          board.scrollLeft = board.scrollWidth;
        }

        // Live: re-fetch every open column in place (no truncation, no scroll jump),
        // so a column grows new items and an auto-mode column re-resolves its tab as
        // the agent's phase moves. Passing the stored mode (null = auto) preserves a
        // pinned tab while letting auto follow the phase.
        async function refreshOpen() {
          for (let i = 0; i < columns.length; i++) {
            const panel = await fetchPanel(columns[i].id, columns[i].mode);
            if (!panel || !board.children[i]) continue;
            board.replaceChild(renderColumn(panel, i), board.children[i]);
          }
        }

        let liveVersion = -1;
        async function pollLive() {
          try {
            const r = await fetch('/state');
            if (r.ok) {
              const s = await r.json();
              if (s.version !== liveVersion) { liveVersion = s.version; await refreshOpen(); }
              if (s.done) { setBadge('✓ session complete', false); return; }
            }
          } catch (e) { /* keep polling */ }
          setTimeout(pollLive, 700);
        }

        function setBadge(text, pulsing) {
          const b = document.getElementById('livebadge');
          b.textContent = text;
          b.className = 'live' + (pulsing ? ' on' : '');
        }

        // Live via SSE (the file-tail server): the server pushes a {version, done}
        // frame whenever the log grows — the push form of pollLive. Same reaction:
        // re-fetch the open columns on a version bump, stop on done. The browser
        // reconnects on a dropped stream on its own.
        function connectSSE() {
          const es = new EventSource('/events');
          es.onmessage = (e) => {
            const s = JSON.parse(e.data);
            if (s.version !== liveVersion) { liveVersion = s.version; refreshOpen(); }
            if (s.done) { setBadge('✓ session complete', false); es.close(); }
          };
        }

        initAsk();
        openColumn(ROOT_ID, null, 0).then(() => {
          if (LIVE) { setBadge('● live', true); STREAM ? connectSSE() : pollLive(); }
        });
        </script>
        </body>
        </html>
      HTML
    end
  end
end
