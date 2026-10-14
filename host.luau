--!strict
-- host.luau: the `rmd.notebook` block, an R Markdown file as a notebook.
--
-- The file is split into cells (rmd.luau): Markdown shows rendered, chunks
-- show as code with their output underneath. Keys work like Jupyter's: a
-- command mode that moves between cells and an edit mode that types into one
-- (buffer.luau). Chunks run in one R session per notebook (kernel.luau and
-- kernel.R), so variables carry over from chunk to chunk as in RStudio.

local ui = tern.ui
local rmd = require("./rmd")
local textbuf = require("./buffer")
local kernel = require("./kernel")

math.randomseed(os.time() + math.floor(tern.now() * 1000))

local TICK_MS = 1000
local HEARTBEAT_TICKS = 20
local DISK_TICKS = 2
local AUTOSAVE_MS = 1500
local STREAM_MS = 300
local TABLE_PAGE = 10
local TEXT_PREVIEW_LINES = 60
local CONSOLE_PREVIEW_LINES = 12
local LIVE_CONSOLE_BYTES = 48 * 1024
-- The console log is read whole while it is at most this big; past it, only
-- its end is read (with `tail`), so a long package build stays cheap to show.
local LIVE_READ_MAX = 1024 * 1024
local MAX_DOC_BYTES = 64 * 1024 * 1024
local MAX_PLOT_BYTES = 64 * 1024 * 1024
local FIG_W, FIG_H, DPI = 7, 5, 192

type Cell = rmd.Cell

-- What running a chunk left: its outputs and how the run went.
type Run = {
	outputs: { any },
	live: { any }?, -- outputs streamed so far while it runs
	live_sig: string?, -- what `live` was built from, to skip unchanged polls
	-- The stream file as decoded so far: bytes consumed, the items, and how
	-- much of the console log those items already reported.
	stream_pos: number,
	stream_items: { any },
	stream_upto: number,
	state: "idle" | "queued" | "running",
	count: number?,
	ms: number?,
	started: number?,
	collapsed: boolean,
	pages: { [number]: number },
}

type Mode = "command" | "edit" | "header"

type Completion = { all: { string }, items: { string }, sel: number, from: number, to: number }

type State = {
	cx: BlockCx,
	path: string?,
	dir: string,
	name: string,
	doc: rmd.Doc?,
	problem: string?,
	runs: { [number]: Run },
	sel: number?, -- the selected cell's id
	mode: Mode,
	buf: textbuf.Buf?,
	edit_id: number?,
	disk: string, -- the file's text as last read or written
	dirty: boolean,
	changes: number, -- bumped by every edit, for autosave
	typing: number, -- bumped by every typed character, for completion
	conflict: boolean,
	queue: { number },
	running: number?,
	count: number,
	k: kernel.Kernel?,
	pending: string?, -- first key of dd / ii / 00
	clip: { Cell },
	trash: { { at: number, cells: { Cell } } },
	overlay: ("help" | "vars" | "knit")?,
	vars: { any }?,
	vars_note: string?, -- why the environment list is empty (R busy or not running)
	-- The latest knit or notebook export (see render), for the status bar.
	knit: { status: "running" | "done" | "failed", kind: "knit" | "export", out: string?, log: string? }?,
	export_again: boolean, -- a notebook export asked for while a render ran
	completion: Completion?,
	blobs: { [string]: string },
	picker: { files: { string }, sel: number }?,
	stopped: boolean,
	ticks: number,
}

-- Paths --------------------------------------------------------------------

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

local function basename(path: string): string
	return string.match(path, "([^/]*)$") or path
end

local function absolute(path: string, cwd: string?): string
	if string.sub(path, 1, 1) == "/" then
		return path
	end
	if string.sub(path, 1, 2) == "~/" then
		return (tern.getenv("HOME") or "") .. string.sub(path, 2)
	end
	return (cwd or tern.getenv("HOME") or "") .. "/" .. path
end

-- A folder name for the document's cache: readable, unique per path.
local function doc_key(path: string): string
	local h = 2166136261
	for i = 1, #path do
		h = bit32.band(bit32.bxor(h, string.byte(path, i)) * 16777619, 0xFFFFFFFF)
	end
	local stem = string.gsub(string.sub(basename(path), 1, 40), "[^%w%-_.]", "_")
	return string.format("%s-%08x", stem, h)
end

local function data_dir(state: State): string
	return tern.plugin.data .. "/docs/" .. doc_key(state.path or "untitled")
end

-- The docs folder holds every notebook's outputs (and its name lists them):
-- keep it to the person. kernel.luau also makes each notebook's own folder
-- private before R starts.
local docs_private = false
local function make_docs_private()
	if docs_private then
		return
	end
	docs_private = true
	local docs = tern.plugin.data .. "/docs"
	pcall(tern.fs.mkdir, docs)
	pcall(tern.process.run, { "chmod", "700", docs }, nil, function(_r) end)
end

-- The file an output names (a plot, a full console log), as a path in this
-- document's data folder. Only the file's name is taken from the output, so
-- whatever a reply or outputs.json says, the plugin reads, opens and deletes
-- files in that folder alone.
local function data_file(state: State, path: any): string?
	if type(path) ~= "string" then
		return nil
	end
	local name = basename(path)
	if name == "." or name == ".." or not string.match(name, "^[%w._%-]+$") then
		return nil
	end
	return data_dir(state) .. "/" .. name
end

-- Output items as the view can draw them: tables with a string `type`.
-- Replies and outputs.json are checked with this before anything uses them.
local function clean_outputs(list: any): { any }
	local out = {}
	if type(list) == "table" then
		for _, o in list do
			if type(o) == "table" and type(o.type) == "string" then
				table.insert(out, o)
			end
		end
	end
	return out
end

-- The document's text, or nil and why it can't be read. Only regular files
-- (not links, pipes or devices) up to MAX_DOC_BYTES are read, so opening a
-- notebook can never hang or flood the plugin.
local function read_doc(path: string): (string?, string?)
	local ok, text = pcall(tern.fs.read, path, MAX_DOC_BYTES)
	if ok then
		return text, nil
	end
	return nil, tostring(text)
end

local function running(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

-- Cells --------------------------------------------------------------------

local function cells(state: State): { Cell }
	return if state.doc then state.doc.cells else {}
end

local function index_of(state: State, id: number?): number?
	for i, c in cells(state) do
		if c.id == id then
			return i
		end
	end
	return nil
end

local function find(state: State, id: number?): Cell?
	local i = index_of(state, id)
	return if i then cells(state)[i] else nil
end

-- The cells a person sees and selects: every cell but the spacers.
local function visible(state: State): { Cell }
	local out = {}
	for _, c in cells(state) do
		if not c.spacer then
			table.insert(out, c)
		end
	end
	return out
end

local function selected(state: State): Cell?
	return find(state, state.sel)
end

local function run_of(state: State, id: number): Run
	local r = state.runs[id]
	if not r then
		r = {
			outputs = {},
			stream_pos = 0,
			stream_items = {},
			stream_upto = 0,
			state = "idle",
			collapsed = false,
			pages = {},
		}
		state.runs[id] = r
	end
	return r
end

local function cell_node_id(id: number): string
	return "main.c" .. id
end

local function editor_id(id: number): string
	return "main.c" .. id .. ".body.ed"
end

local function header_id(id: number): string
	return "main.c" .. id .. ".body.hd"
end

local function reveal(state: State, id: number?)
	if id then
		state.cx:render()
		state.cx:frame({ { "reveal", cell_node_id(id), "nearest" } })
	end
end

local function select(state: State, id: number?)
	if id and id ~= state.sel then
		state.sel = id
		state.pending = nil
		reveal(state, id)
	end
end

-- The visible cell `delta` steps from the selection.
local function neighbour(state: State, delta: number): Cell?
	local vis = visible(state)
	for i, c in vis do
		if c.id == state.sel then
			return vis[math.clamp(i + delta, 1, #vis)]
		end
	end
	return vis[1]
end

-- Saving ------------------------------------------------------------------

local function text_of(state: State): string
	return if state.doc then rmd.serialize(state.doc) else ""
end

local function write_cache(state: State)
	if not state.path then
		return
	end
	local entries = {}
	for _, c in cells(state) do
		local r = state.runs[c.id]
		if c.kind == "code" and r and #r.outputs > 0 then
			table.insert(entries, { src = c.src, outputs = r.outputs, count = r.count, ms = r.ms })
		end
	end
	pcall(function()
		tern.fs.mkdir(data_dir(state))
		tern.fs.write(data_dir(state) .. "/outputs.json", tern.json.encode({ cells = tern.json.array(entries) }))
	end)
end

local function save_file(state: State): boolean
	if not state.path or not state.doc then
		return false
	end
	local text = text_of(state)
	local path = state.path :: string
	local ok, err = pcall(function()
		tern.fs.write(path, text)
	end)
	if not ok then
		state.cx:toast("error", "Couldn't save " .. state.name, tostring(err))
		return false
	end
	state.disk = text
	state.dirty = false
	state.conflict = false
	write_cache(state)
	return true
end

local function changed(state: State)
	state.dirty = true
	state.changes += 1
	local at = state.changes
	tern.timer(AUTOSAVE_MS, function()
		if not state.stopped and state.dirty and state.changes == at then
			save_file(state)
			state.cx:render()
		end
	end)
end

-- Outputs ------------------------------------------------------------------

local function send_blobs(state: State, outputs: { any })
	for _, o in outputs do
		local file = data_file(state, o.file)
		if o.type == "plot" and file and not state.blobs[o.file] then
			local ok, bytes = pcall(tern.fs.read, file, MAX_PLOT_BYTES)
			if ok then
				state.blobs[o.file] = state.cx:blob(bytes, "image/png")
			end
		end
	end
end

-- Deletes the files (plots, full console logs) of outputs being replaced.
local function drop_files(state: State, outputs: { any })
	for _, o in outputs do
		local file = data_file(state, o.file)
		if file then
			pcall(tern.fs.remove, file)
			state.blobs[o.file] = nil
		end
	end
end

local function restore_cache(state: State)
	local ok, text = pcall(tern.fs.read, data_dir(state) .. "/outputs.json")
	if not ok then
		return
	end
	local ok2, data = pcall(tern.json.decode, text)
	if not ok2 or type(data) ~= "table" or type(data.cells) ~= "table" then
		return
	end
	local used: { [number]: boolean } = {}
	for _, c in cells(state) do
		if c.kind == "code" then
			for i, e in data.cells do
				if not used[i] and type(e) == "table" and e.src == c.src then
					used[i] = true
					local r = run_of(state, c.id)
					r.outputs = clean_outputs(e.outputs)
					r.ms = tonumber(e.ms)
					r.count = tonumber(e.count)
					send_blobs(state, r.outputs)
					break
				end
			end
		end
	end
end

-- Loading ------------------------------------------------------------------

local TEMPLATE = [[
---
title: "Untitled"
output: html_notebook
---

```{r}

```
]]

local function load(state: State, text: string)
	state.doc = rmd.parse(text, state.doc and state.doc.seq or 0)
	local vis = visible(state)
	state.sel = if vis[1] then vis[1].id else nil
end

-- Reads the file again after another program changed it, keeping the
-- outputs of chunks whose code didn't change.
local function reload(state: State, text: string)
	local old: { [string]: { Run } } = {}
	for _, c in cells(state) do
		local r = state.runs[c.id]
		if c.kind == "code" and r then
			old[c.src] = old[c.src] or {}
			table.insert(old[c.src], r)
		end
	end
	local at = 1
	local vis = visible(state)
	for i, c in vis do
		if c.id == state.sel then
			at = i
		end
	end
	state.doc = rmd.parse(text, state.doc and state.doc.seq or 0)
	state.disk = text
	state.runs = {}
	for _, c in cells(state) do
		local list = old[c.src]
		if c.kind == "code" and list and #list > 0 then
			state.runs[c.id] = table.remove(list, 1) :: Run
		end
	end
	vis = visible(state)
	state.sel = if #vis > 0 then vis[math.min(at, #vis)].id else nil
	state.queue = {}
end

local function open_path(state: State, path: string)
	state.path = path
	state.dir = dirname(path)
	state.name = basename(path)
	local text, err = read_doc(path)
	if text then
		state.disk = text
		load(state, text)
	elseif not tern.fs.exists(path) then
		-- A new notebook: written on the first save.
		state.disk = ""
		load(state, TEMPLATE)
		state.dirty = true
	else
		state.problem = string.format(
			"Couldn't open %s as a notebook (%s). Notebooks open from regular files up to %d MiB; "
				.. "for a link, open the file it points to.",
			path,
			tostring(err),
			MAX_DOC_BYTES // (1024 * 1024)
		)
		state.doc = nil
	end
end

-- Running chunks -------------------------------------------------------------

local run_next: (State) -> ()

local function finish(state: State, id: number, outputs: { any }, ms: number?, failed: boolean)
	local r = run_of(state, id)
	if state.running == id then
		state.running = nil
	end
	drop_files(state, r.outputs)
	r.outputs = outputs
	r.live = nil
	r.ms = ms
	r.state = "idle"
	r.started = nil
	send_blobs(state, outputs)
	if failed then
		-- Like Jupyter: an error stops the cells queued after it.
		for _, qid in state.queue do
			run_of(state, qid).state = "idle"
		end
		state.queue = {}
	end
	write_cache(state)
end

-- Decodes the stream file's new lines (whole ones only: the last may still
-- be being written) onto the run. kernel.R caps the file, and earlier lines
-- are never decoded twice.
local function read_stream(r: Run, file: string)
	local ok, text = pcall(tern.fs.read, file, 16 * 1024 * 1024)
	if not ok or #text <= r.stream_pos then
		return
	end
	local last = string.find(text, "\n[^\n]*$", r.stream_pos + 1)
	if not last then
		return
	end
	for line in string.gmatch(string.sub(text, r.stream_pos + 1, last), "([^\n]*)\n") do
		local okd, o = pcall(tern.json.decode, line)
		if okd and type(o) == "table" and type(o.type) == "string" then
			table.insert(r.stream_items, o)
			if o.type == "console" then
				r.stream_upto = math.max(r.stream_upto, tonumber(o.upto) or 0)
			end
		end
	end
	r.stream_pos = last
end

-- The console log's size and its last LIVE_CONSOLE_BYTES, for `cb`. A log up
-- to LIVE_READ_MAX is read whole; a bigger one (a long package build) goes
-- through `wc` and `tail`, since tern.fs only reads whole files.
local function console_tail(path: string, cb: (size: number, tail: string) -> ())
	local ok, text = pcall(tern.fs.read, path, LIVE_READ_MAX)
	if ok then
		cb(#text, string.sub(text, -LIVE_CONSOLE_BYTES))
		return
	end
	if not tern.fs.exists(path) then
		cb(0, "")
		return
	end
	local script = 'wc -c <"$1"; tail -c "$2" "$1"'
	local started = pcall(function()
		tern.process.run({ "sh", "-c", script, "sh", path, tostring(LIVE_CONSOLE_BYTES) }, nil, function(r)
			local size, tail = string.match(r.stdout, "^%s*(%d+)\n(.*)$")
			cb(tonumber(size) or 0, tail or "")
		end)
	end)
	if not started then
		cb(0, "")
	end
end

-- While a chunk runs: the outputs kernel.R has streamed so far, plus what
-- R's subprocesses (compilers under install.packages(), system() calls)
-- wrote to the console log since the last console output it reported, so
-- a long build shows its progress instead of looking stuck.
local function poll_stream(state: State, id: number, file: string, log: string)
	tern.timer(STREAM_MS, function()
		if state.stopped or state.running ~= id then
			return
		end
		local r = run_of(state, id)
		read_stream(r, file)
		console_tail(log, function(size, tail)
			if state.stopped or state.running ~= id then
				return
			end
			local live = table.clone(r.stream_items)
			local unseen = size - r.stream_upto
			if unseen > 0 then
				local text = if unseen <= #tail then string.sub(tail, -unseen) else "…\n" .. tail
				table.insert(live, { type = "console", text = text })
			end
			local sig = #live .. ":" .. size
			if sig ~= r.live_sig then
				send_blobs(state, live)
				r.live = live
				r.live_sig = sig
				state.cx:render()
			end
			poll_stream(state, id, file, log)
		end)
	end)
end

local function output_width(state: State): number
	return math.clamp(state.cx.cols - 8, 40, 160)
end

-- Sends `code` (the whole chunk, or a line of it) for cell `id`.
local function exec(state: State, id: number, code: string)
	local c = find(state, id)
	local k = state.k
	if not c or not k then
		return
	end
	local engine, rest = rmd.engine(c)
	state.count += 1
	local r = run_of(state, id)
	r.state = "running"
	r.started = tern.now()
	r.count = state.count
	r.live = {}
	r.live_sig = nil
	r.stream_pos, r.stream_items, r.stream_upto = 0, {}, 0
	state.running = id
	if engine ~= "r" then
		finish(state, id, {
			{ type = "error", text = "Only R chunks run in this notebook; this one is `" .. engine .. "`.", call = "" },
		}, 0, true)
		run_next(state)
		return
	end
	local eid = "e" .. state.count .. "-" .. tostring(math.random(100000, 999999))
	local stream = k.data .. "/" .. eid .. ".jsonl"
	local fig_w, fig_h = FIG_W, FIG_H
	kernel.exec(k, {
		id = eid,
		-- without the fence's prefix (`> `, a list indent), as knitr runs it
		code = rmd.code(c, code),
		opts = rest,
		width = output_width(state),
		fig_width = fig_w,
		fig_height = fig_h,
		dpi = DPI,
		stream = stream,
		max_rows = 1000,
	}, function(res, err)
		pcall(tern.fs.remove, stream)
		if state.stopped then
			return
		end
		if type(res) == "table" then
			finish(state, id, clean_outputs(res.outputs), tonumber(res.ms), res.error == true)
		else
			local why = if state.k and state.k.why then state.k.why else tostring(err)
			finish(state, id, { { type = "error", text = "The R session ended: " .. why, call = "" } }, nil, true)
		end
		run_next(state)
		state.cx:render()
		-- Bring the new output into view while its cell is still the selected
		-- one (it lands under the code, often below the fold).
		if state.sel == id and #run_of(state, id).outputs > 0 then
			state.cx:frame({ { "reveal", "main.c" .. id .. ".body.out", "nearest" } })
		end
	end)
	poll_stream(state, id, stream, kernel.console_log(k))
end

function run_next(state: State)
	local k = state.k
	if state.running or #state.queue == 0 or not k then
		return
	end
	if k.status == "off" or k.status == "dead" then
		kernel.start(k)
		return
	end
	if k.status ~= "idle" then
		return -- starting or busy: the status change calls back here
	end
	local id = table.remove(state.queue, 1)
	local c = find(state, id)
	if c and c.kind == "code" then
		exec(state, c.id, c.src)
	else
		run_next(state)
	end
end

local function enqueue(state: State, ids: { number })
	for _, id in ids do
		local c = find(state, id)
		if c and c.kind == "code" and state.running ~= id and not table.find(state.queue, id) then
			table.insert(state.queue, id)
			run_of(state, id).state = "queued"
		end
	end
	run_next(state)
end

local function run_all(state: State, upto: number?)
	local ids = {}
	for _, c in cells(state) do
		if upto and c.id == upto then
			break
		end
		if c.kind == "code" then
			table.insert(ids, c.id)
		end
	end
	enqueue(state, ids)
end

local function interrupt(state: State)
	for _, qid in state.queue do
		run_of(state, qid).state = "idle"
	end
	state.queue = {}
	if state.k then
		kernel.interrupt(state.k)
	end
end

local function restart(state: State)
	interrupt(state)
	if state.running then
		finish(state, state.running, run_of(state, state.running).live or {}, nil, true)
	end
	state.count = 0
	if state.k then
		kernel.start(state.k)
	end
	state.cx:toast("info", "Restarting R", "Objects from earlier chunks are gone; run them again.")
end

-- Editing ------------------------------------------------------------------

local function lang_of(c: Cell): string
	if c.kind == "md" then
		return "markdown"
	elseif c.kind == "yaml" then
		return "yaml"
	end
	return (rmd.engine(c))
end

local function enter_edit(state: State, c: Cell, at_end: boolean?)
	state.sel = c.id
	state.mode = "edit"
	state.edit_id = c.id
	state.buf = textbuf.new(c.src, if at_end then #c.src else 0)
	state.completion = nil
	state.cx:render()
	state.cx:frame({ { "focus", editor_id(c.id) } })
	state.cx:frame({ { "reveal", cell_node_id(c.id), "nearest" } })
end

local function leave_edit(state: State)
	state.mode = "command"
	state.edit_id = nil
	state.buf = nil
	state.completion = nil
	state.cx:frame({ { "focus", tern.json.null :: any } })
end

local function edit_header(state: State, c: Cell)
	if c.kind ~= "code" then
		return
	end
	state.sel = c.id
	state.mode = "header"
	state.edit_id = c.id
	state.buf = textbuf.new(c.header)
	state.cx:render()
	state.cx:frame({ { "focus", header_id(c.id) } })
end

-- Keeps the edited cell's text in step with its buffer.
local function sync(state: State)
	local c = find(state, state.edit_id)
	local b = state.buf
	if c and b and state.mode == "edit" and c.src ~= b.text then
		c.src = b.text
		changed(state)
	end
end

-- Structure -----------------------------------------------------------------

local function insert_at(state: State, at: number, list: { Cell })
	local doc = state.doc
	if not doc then
		return
	end
	for i, c in list do
		table.insert(doc.cells, at + i - 1, c)
	end
end

-- Whether the file text before a new chunk already ends in a blank line.
local function ends_blank(c: Cell?): boolean
	return c ~= nil and c.kind == "md" and (c.spacer or string.find(c.trail, "\n\n", 1, true) ~= nil)
end

-- Whether the file text after a new chunk already starts with a blank line.
local function starts_blank(c: Cell?): boolean
	return c ~= nil and c.kind == "md" and (c.spacer or c.lead ~= "")
end

-- Puts cell `c` at index `at`, with blank lines around it where the file
-- would otherwise run a fence into its neighbours, as RStudio inserts chunks.
local function place(state: State, at: number, c: Cell)
	local doc = state.doc
	if not doc then
		return
	end
	local prev, nxt = doc.cells[at - 1], doc.cells[at]
	local list = { c }
	if prev and not ends_blank(prev) then
		table.insert(list, 1, rmd.new_spacer(doc))
	end
	if nxt and not starts_blank(nxt) then
		table.insert(list, rmd.new_spacer(doc))
	end
	insert_at(state, at, list)
end

-- Inserts a new code cell above or below the selection.
local function insert_cell(state: State, below: boolean, src: string?): Cell?
	local doc = state.doc
	if not doc then
		return nil
	end
	local c = rmd.new_code(doc, src)
	local i = index_of(state, state.sel)
	if not i then
		place(state, #doc.cells + 1, c)
	elseif below or doc.cells[i].kind == "yaml" then
		place(state, i + 1, c)
	else
		place(state, i, c)
	end
	state.sel = c.id
	changed(state)
	reveal(state, c.id)
	return c
end

-- Removes the selected cell and one spacer beside it, so deleting undoes an
-- insert. Returns the removed cells (for undo and the clipboard).
local function remove_selected(state: State): { Cell }?
	local doc = state.doc
	local i = index_of(state, state.sel)
	if not doc or not i or doc.cells[i].kind == "yaml" then
		return nil
	end
	local next_cell = neighbour(state, 1)
	local prev_cell = neighbour(state, -1)
	local at = i
	local removed = { doc.cells[i] }
	if doc.cells[i + 1] and doc.cells[i + 1].spacer then
		table.insert(removed, doc.cells[i + 1])
	elseif doc.cells[i - 1] and doc.cells[i - 1].spacer then
		table.insert(removed, 1, doc.cells[i - 1])
		at = i - 1
	end
	for _ = 1, #removed do
		table.remove(doc.cells, at)
	end
	table.insert(state.trash, { at = at, cells = removed })
	if #state.trash > 20 then
		table.remove(state.trash, 1)
	end
	local gone = removed[1].spacer and removed[2] or removed[1]
	state.sel = if next_cell and next_cell.id ~= gone.id then next_cell.id elseif prev_cell then prev_cell.id else nil
	for qi, qid in state.queue do
		if qid == gone.id then
			table.remove(state.queue, qi)
			break
		end
	end
	changed(state)
	return removed
end

local function copy_cell(c: Cell, doc: rmd.Doc): Cell
	local n = if c.kind == "md" then rmd.new_md(doc, c.src) else rmd.new_code(doc, c.src)
	if c.kind == "code" then
		rmd.set_header(n, c.header)
	end
	return n
end

local function paste(state: State, below: boolean)
	local doc = state.doc
	if not doc or #state.clip == 0 then
		return
	end
	local first = true
	for _, src in state.clip do
		local c = copy_cell(src, doc)
		local i = index_of(state, state.sel)
		if not i then
			place(state, #doc.cells + 1, c)
		elseif below or not first or doc.cells[i].kind == "yaml" then
			place(state, i + 1, c)
		else
			place(state, i, c)
		end
		state.sel = c.id
		first = false
	end
	changed(state)
	reveal(state, state.sel)
end

-- Moves the selected cell past its visible neighbour. The cell leaves its
-- old place without leaving a double blank line behind, and lands with
-- blank lines around it (place), so fences never run together.
local function move_selected(state: State, delta: number)
	local doc = state.doc
	local i = index_of(state, state.sel)
	local target = neighbour(state, delta)
	if not doc or not i or not target or target.id == state.sel then
		return
	end
	if doc.cells[i].kind == "yaml" or target.kind == "yaml" then
		return
	end
	local c = table.remove(doc.cells, i) :: Cell
	if doc.cells[i - 1] and doc.cells[i] and doc.cells[i - 1].spacer and doc.cells[i].spacer then
		table.remove(doc.cells, i)
	end
	local j = index_of(state, target.id) :: number
	place(state, if delta > 0 then j + 1 else j, c)
	changed(state)
	reveal(state, c.id)
end

-- Knitting and the notebook's HTML ------------------------------------------
--
-- Two ways to HTML, both in a separate R process so the session stays free:
-- knitting renders the whole document afresh, and the notebook export writes
-- NAME.nb.html from the outputs the notebook shows, running no chunk. That
-- is what RStudio does for an `output: html_notebook` document: on every
-- save, and when you press Ctrl+Shift+K (its Preview).

type RenderKind = "knit" | "export"

-- What a failed render most likely needs, put ahead of its log.
local function knit_hint(log: string, kind: RenderKind): string
	local what = if kind == "knit" then "Knitting" else "Saving the notebook's HTML"
	if string.find(log, "no package called", 1, true) and string.find(log, "rmarkdown", 1, true) then
		return what .. ' needs the rmarkdown package. In R, run: install.packages("rmarkdown")\n\n'
	end
	local lower = string.lower(log)
	if string.find(lower, "pandoc", 1, true) and (string.find(lower, "not found", 1, true) or string.find(lower, "required", 1, true)) then
		return what .. " needs Pandoc: install it from https://pandoc.org/installing.html (RStudio ships one too).\n\n"
	end
	return ""
end

-- Whether the front matter asks for an R Notebook (`output: html_notebook`).
local function is_notebook(state: State): boolean
	local first = cells(state)[1]
	return first ~= nil and first.kind == "yaml" and string.find(first.src, "html_notebook", 1, true) ~= nil
end

local export: (state: State, announce: boolean) -> ()

-- Runs `argv` (an Rscript) in the document's folder; the last line it prints
-- is the file it wrote. `announce` toasts success and opens the log on
-- failure; a quiet run (the export after a save) only updates the status bar.
local function render(state: State, kind: RenderKind, argv: { string }, announce: boolean)
	local dir = state.dir
	state.knit = { status = "running", kind = kind }
	local function settle()
		if state.export_again then
			state.export_again = false
			export(state, false)
		end
		state.cx:render()
	end
	local function failed(log: string)
		state.knit = { status = "failed", kind = kind, log = knit_hint(log, kind) .. log }
		if announce then
			state.overlay = "knit"
		else
			state.cx:toast("error", "Couldn't write the notebook's HTML", "Click “HTML failed” in the status bar to see why.")
		end
		settle()
	end
	-- Like the session, R reads the folder's .Rprofile only when the folder
	-- is the person's own (see kernel.dotfile_env).
	kernel.dotfile_env(dir, function(env, _skipped)
		if state.stopped then
			return
		end
		local ok, err = pcall(function()
			tern.process.run(argv, { cwd = dir, env = env }, function(r)
				if state.stopped then
					return
				end
				if r.status ~= 0 then
					failed(r.stderr .. r.stdout)
					return
				end
				local out = string.match(r.stdout, "([^\n]+)%s*$")
				state.knit = { status = "done", kind = kind, out = out }
				if announce then
					local title = if kind == "knit" then "Knitted " .. state.name else "Saved the notebook's HTML"
					state.cx:toast("success", title, if out then basename(out) else nil)
				end
				settle()
			end)
		end)
		if not ok then
			failed("Couldn't start Rscript (is R installed and on the PATH?): " .. tostring(err))
		end
	end)
end

-- Writes NAME.nb.html beside the .Rmd from the outputs on screen (export.R);
-- a request while another render runs is done once that one finishes.
function export(state: State, announce: boolean)
	if not state.path or not state.doc then
		return
	end
	if state.knit and state.knit.status == "running" then
		state.export_again = true
		return
	end
	if state.dirty then
		save_file(state)
	end
	-- Every chunk in order, with the outputs it shows; files only from the
	-- notebook's own data folder.
	local entries = {}
	for _, c in cells(state) do
		if c.kind == "code" then
			local r = state.runs[c.id]
			local shown: { any } = if r then r.outputs else {}
			local outputs = {}
			for _, o in shown do
				local item = table.clone(o)
				if o.file ~= nil then
					item.file = data_file(state, o.file)
				end
				table.insert(outputs, item)
			end
			table.insert(entries, { code = rmd.code(c), outputs = tern.json.array(outputs) })
		end
	end
	local list = data_dir(state) .. "/export.json"
	local ok, err = pcall(function()
		tern.fs.mkdir(data_dir(state))
		tern.fs.write(list, tern.json.encode(tern.json.array(entries)))
	end)
	if not ok then
		state.cx:toast("error", "Couldn't write the notebook's HTML", tostring(err))
		return
	end
	render(state, "export", { "Rscript", tern.plugin.dir .. "/export.R", state.path :: string, list }, announce)
end

-- K / Ctrl+Shift+K: an R Notebook writes its HTML from what you see (RStudio's
-- Preview); any other document is knitted afresh.
local function knit(state: State)
	if not state.path or (state.knit and state.knit.status == "running") then
		return
	end
	if is_notebook(state) then
		export(state, true)
		return
	end
	if state.dirty then
		save_file(state)
	end
	local script = "a <- commandArgs(TRUE); out <- rmarkdown::render(a[1], quiet = TRUE, envir = new.env()); cat(normalizePath(out))"
	render(state, "knit", { "Rscript", "-e", script, state.path :: string }, true)
end

-- s / Ctrl+S: the file, and an R Notebook's HTML beside it, as RStudio does.
local function save_now(state: State)
	if save_file(state) then
		local notebook = is_notebook(state)
		state.cx:toast("success", "Saved " .. state.name, if notebook then "Writing its HTML too" else nil)
		if notebook then
			export(state, false)
		end
	end
end

-- Completion ---------------------------------------------------------------
--
-- Tab asks R for the names that complete the word before the caret: one
-- match goes straight in, several open a list at the caret. While typing R
-- code the list also opens on its own after a short pause. Typing narrows
-- it; Tab or Enter accepts, ↑/↓ move, Esc closes.

local AUTO_COMPLETE_MS = 150
local AUTO_MIN_CHARS = 3

local function common_prefix(items: { string }): string
	local p = items[1] or ""
	for _, s in items do
		while string.sub(s, 1, #p) ~= p do
			p = string.sub(p, 1, -2)
		end
	end
	return p
end

-- Narrows the open list to what was typed since it opened, or closes it.
local function narrow(state: State)
	local comp = state.completion
	local b = state.buf
	if not comp or not b then
		return
	end
	local typed = string.sub(b.text, comp.from + 1, b.cursor)
	if b.cursor < comp.from or string.find(typed, "[^%w_.$@:]") then
		state.completion = nil
		return
	end
	local items = {}
	for _, s in comp.all do
		if s ~= typed and string.sub(s, 1, #typed) == typed then
			table.insert(items, s)
		end
	end
	if #items == 0 then
		state.completion = nil
		return
	end
	comp.items, comp.sel, comp.to = items, 1, b.cursor
end

-- Whether the line up to the caret ends in a name worth completing on its
-- own: at least three characters (or right after `$`, `@`, `::`), and not
-- inside a string or a comment.
local function wants_auto(line: string): boolean
	local quote: string? = nil
	local i = 1
	while i <= #line do
		local ch = string.sub(line, i, i)
		if quote then
			if ch == "\\" then
				i += 1
			elseif ch == quote then
				quote = nil
			end
		elseif ch == '"' or ch == "'" or ch == "`" then
			quote = ch
		elseif ch == "#" then
			return false
		end
		i += 1
	end
	if quote then
		return false
	end
	if string.match(line, "[%$@]$") or string.match(line, "::$") then
		return true
	end
	local word = string.match(line, "[%w_.]+$") or ""
	return #word >= AUTO_MIN_CHARS and not string.match(word, "^[%d.]")
end

local function complete(state: State, auto: boolean)
	local b = state.buf
	local k = state.k
	local c = find(state, state.edit_id)
	if not b or not k or not c or c.kind ~= "code" or rmd.engine(c) ~= "r" then
		return
	end
	local line = textbuf.line_prefix(b)
	local id, at, text = c.id, b.cursor, b.text
	kernel.complete(k, line, function(token, matches)
		local cur = state.buf
		if state.stopped or state.edit_id ~= id or not cur or cur.cursor ~= at or cur.text ~= text then
			return
		end
		local list = {}
		for _, m in matches do
			if m ~= token then
				table.insert(list, m)
			end
		end
		if #list == 0 then
			return
		end
		local from = at - #token
		if not auto then
			if #list == 1 then
				textbuf.replace(cur, from, at, list[1])
				sync(state)
				state.cx:render()
				return
			end
			local prefix = common_prefix(list)
			if #prefix > #token then
				textbuf.replace(cur, from, at, prefix)
				sync(state)
			end
		end
		state.completion = { all = list, items = list, sel = 1, from = from, to = cur.cursor }
		narrow(state)
		state.cx:render()
	end)
end

-- After a typed character, opens the list once typing pauses.
local function complete_later(state: State)
	state.typing += 1
	local n, id = state.typing, state.edit_id
	tern.timer(AUTO_COMPLETE_MS, function()
		local b = state.buf
		if state.stopped or state.typing ~= n or state.edit_id ~= id or state.completion or not b then
			return
		end
		if wants_auto(textbuf.line_prefix(b)) then
			complete(state, true)
		end
	end)
end

local function accept_completion(state: State)
	local comp = state.completion
	local b = state.buf
	if comp and b then
		textbuf.replace(b, comp.from, comp.to, comp.items[comp.sel])
		sync(state)
	end
	state.completion = nil
end

-- Views --------------------------------------------------------------------

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function icon_button(name: string, act: string, title: string, key: string): Node
	return ui.node("icon", { name = name, key = key, title = title, role = "rmd.btn", actions = { click = act } })
end

local function fmt_ms(ms: number?): string
	if not ms then
		return ""
	elseif ms < 1000 then
		return string.format("%d ms", math.floor(ms + 0.5))
	elseif ms < 60000 then
		return string.format("%.2f s", ms / 1000)
	end
	return string.format("%dm %02ds", ms // 60000, (ms % 60000) // 1000)
end

local function table_node(id: number, i: number, o: any, page: number): Node
	local cols: { any } = {}
	local has_names = type(o.rownames) == "table"
	if has_names then
		table.insert(cols, { id = "_rn", head = "", priority = 100 })
	end
	local names: { any } = if type(o.cols) == "table" then o.cols else {}
	local types: { any } = if type(o.types) == "table" then o.types else {}
	for j, name in names do
		local kind = if types[j] ~= nil then tostring(types[j]) else nil
		local numeric = kind == "dbl" or kind == "int"
		table.insert(cols, {
			id = "c" .. j,
			head = { ui.span(tostring(name), "strong"), ui.span(if kind then " " .. kind else "", "muted") },
			align = if numeric then "end" else "start",
			priority = 100 - j,
		})
	end
	local data: { any } = if type(o.rows) == "table" then o.rows else {}
	local first = page * TABLE_PAGE + 1
	local last = math.min(#data, first + TABLE_PAGE - 1)
	local rows = {}
	for r = first, last do
		local cells_: { [string]: any } = {}
		if has_names then
			cells_._rn = { ui.span(tostring(o.rownames[r] or ""), "muted") }
		end
		if type(data[r]) == "table" then
			for j, v in data[r] do
				cells_["c" .. j] = tostring(v)
			end
		end
		table.insert(rows, { id = "r" .. r, cells = cells_ })
	end
	local nrow = tonumber(o.nrow) or #data
	local pages = math.max(1, math.ceil(#data / TABLE_PAGE))
	local caption: { any } = {
		ui.span(string.format("%s × %s", tostring(nrow), tostring(o.ncol or #names)), "num"),
		ui.span("  " .. tostring(o.class or "data.frame"), "muted"),
	}
	if #data < nrow then
		table.insert(caption, ui.span(string.format("  (first %d rows)", #data), "muted"))
	end
	local bar: { Node } = { ui.text(caption) }
	if pages > 1 then
		table.insert(bar, ui.node("spacer", { grow = 1 }))
		table.insert(bar, icon_button("chev-up", string.format("page=%d:%d:-1", id, i), "Previous rows", "prev"))
		table.insert(bar, ui.text({ ui.span(string.format("%d–%d of %d", first, last, #data), "muted") }))
		table.insert(bar, icon_button("chev", string.format("page=%d:%d:1", id, i), "Next rows", "next"))
	end
	return ui.node("col", { key = "o" .. i, role = "rmd.table" }, {
		ui.node("table", { key = "t", cols = cols, rows = rows }),
		with(ui.row(bar), { key = "bar", role = "rmd.tablebar" }),
	})
end

local function output_node(state: State, id: number, i: number, o: any, r: Run): Node?
	local t = o.type
	if t == "text" then
		return ui.node("ansi", { key = "o" .. i, text = o.text or "", preview = { lines = TEXT_PREVIEW_LINES }, role = "rmd.text" })
	elseif t == "message" then
		return ui.node("ansi", { key = "o" .. i, text = o.text or "", role = "rmd.msg" })
	elseif t == "console" then
		-- What R's subprocesses printed (a package build, system()): its last
		-- lines, which is where builds report what went wrong.
		local log = ui.node("ansi", {
			key = "log",
			text = o.text or "",
			preview = { lines = CONSOLE_PREVIEW_LINES },
			follow = true,
			role = "rmd.console",
		})
		local kids: { Node } = { log }
		if type(o.file) == "string" then
			table.insert(kids, with(ui.text({ ui.span("Open the full log", "link") }), {
				key = "full",
				role = "rmd.loglink",
				actions = { click = string.format("log=%d:%d", id, i) },
			}))
		end
		return ui.node("col", { key = "o" .. i, role = "rmd.consolebox" }, kids)
	elseif t == "warning" or t == "error" then
		local label = if t == "error" then "Error" else "Warning"
		local spans: { any } = { ui.span(label, (if t == "error" then "error" else "warning") .. " strong") }
		if o.call and o.call ~= "" then
			table.insert(spans, ui.span(" in " .. o.call, "muted"))
		end
		table.insert(spans, ui.span(": " .. tostring(o.text or ""), if t == "error" then "error" else nil))
		return with(ui.text(spans), { key = "o" .. i, role = "rmd." .. t, tone = if t == "error" then "error" else "warning" })
	elseif t == "plot" then
		local blob = state.blobs[o.file or ""]
		return ui.node("image", {
			key = "o" .. i,
			blob = blob,
			w = o.width,
			h = o.height,
			alt = "Plot " .. i,
			role = "rmd.plot",
			path = data_file(state, o.file),
		})
	elseif t == "table" then
		return table_node(id, i, o, r.pages[i] or 0)
	end
	return nil
end

local function outputs_node(state: State, c: Cell, r: Run): Node?
	local list = r.live or r.outputs
	if #list == 0 then
		return nil
	end
	if r.collapsed then
		return with(ui.text({ ui.span(string.format("%d output%s hidden · o to show", #list, if #list == 1 then "" else "s"), "muted") }), {
			key = "out",
			role = "rmd.hidden",
			actions = { click = "fold=" .. c.id },
		})
	end
	local nodes = {}
	for i, o in list do
		local n = output_node(state, c.id, i, o, r)
		if n then
			table.insert(nodes, n)
		end
	end
	return ui.node("col", { key = "out", role = "rmd.out" }, nodes)
end

local function prompt_node(r: Run?): Node
	local text: string
	if r and r.state == "running" then
		return ui.node("spinner", { key = "pr", style = "braille", role = "rmd.prompt" })
	elseif r and r.state == "queued" then
		text = "[*]"
	elseif r and r.count then
		text = "[" .. r.count .. "]"
	else
		text = "[ ]"
	end
	return ui.node("text", { key = "pr", role = "rmd.prompt", spans = { ui.span(text, "muted mono") } })
end

local function code_head(state: State, c: Cell, r: Run?): Node
	local engine, rest = rmd.engine(c)
	local kids: { Node } = { ui.badge(engine, if engine == "r" then "accent" else "neutral") }
	if state.mode == "header" and state.edit_id == c.id and state.buf then
		local b = state.buf
		local a, z = textbuf.selection(b)
		return ui.node("input", {
			key = "hd",
			text = b.text,
			cursor = textbuf.utf16(b.text, b.cursor),
			anchor = if a and z then textbuf.utf16(b.text, if b.cursor == a then z else a) else nil,
			placeholder = "r label, fig.width=8, echo=FALSE",
			prompt = { ui.span("```{", "muted") },
			role = "rmd.hdinput",
		})
	end
	if rest ~= "" then
		local label = rmd.label(c)
		local opts = rest
		if label then
			table.insert(kids, ui.text({ ui.span(label, "strong") }))
			opts = string.gsub(string.sub(rest, #label + 1), "^%s*,?%s*", "")
		end
		if opts ~= "" then
			table.insert(kids, ui.text({ ui.span(opts, "muted mono") }))
		end
	end
	table.insert(kids, ui.node("spacer", { grow = 1, key = "sp" }))
	if r and r.state == "running" and r.started then
		table.insert(kids, ui.node("elapsed", { key = "el", age = tern.now() - r.started }))
		table.insert(kids, icon_button("stop", "stop=" .. c.id, "Interrupt R (i i)", "stop"))
	else
		if r and r.ms then
			table.insert(kids, ui.text({ ui.span(fmt_ms(r.ms), "muted") }))
		end
		table.insert(kids, icon_button("fast-forward", "above=" .. c.id, "Run all chunks above", "above"))
		table.insert(kids, icon_button("play", "run=" .. c.id, "Run chunk (Shift+Enter)", "run"))
	end
	return with(ui.row(kids), { key = "head", role = "rmd.head" })
end

-- Line numbers for a chunk's editor gutter.
local function line_numbers(text: string): { any }
	local n = textbuf.line_count(text)
	local fmt = "%" .. #tostring(n) .. "d "
	local out = table.create(n)
	for i = 1, n do
		out[i] = { ui.span(string.format(fmt, i), "dim") }
	end
	return out
end

local function editor_node(state: State, c: Cell, lang: string, editing: boolean): Node
	local b = state.buf
	local text = if editing and b then b.text else c.src
	local props: { [string]: any } = {
		key = "ed",
		text = text,
		lang = lang,
		role = "rmd.editor",
		gutter = if c.kind == "code" then line_numbers(text) else nil,
	}
	if editing and b then
		local a, z = textbuf.selection(b)
		props.cursor = textbuf.utf16(b.text, b.cursor)
		props.anchor = if a and z then textbuf.utf16(b.text, if b.cursor == a then z else a) else nil
		local comp = state.completion
		if comp then
			local pick = comp.items[comp.sel] or ""
			local typed = string.sub(b.text, comp.from + 1, comp.to)
			if string.sub(pick, 1, #typed) == typed then
				props.ghost = string.sub(pick, #typed + 1)
			end
		end
	else
		props.readonly = true
		props.placeholder = if c.kind == "code" then "Empty chunk" else ""
	end
	return ui.node("editor", props)
end

local function yaml_view(c: Cell): Node
	local front = rmd.front(c)
	local kids: { Node } = {}
	table.insert(kids, ui.text({ ui.span(front.title or "Untitled", "strong") }))
	local meta = {}
	for _, key in { "author", "date", "output" } do
		if front[key] then
			table.insert(meta, front[key])
		end
	end
	if #meta > 0 then
		table.insert(kids, ui.text({ ui.span(table.concat(meta, " · "), "muted") }))
	end
	return ui.node("col", { key = "ed", role = "rmd.yaml" }, kids)
end

local function cell_node(state: State, c: Cell): Node
	local is_sel = c.id == state.sel
	local editing = state.mode == "edit" and state.edit_id == c.id
	local r = state.runs[c.id]
	local body: { Node } = {}
	local gutter: Node
	if c.kind == "code" then
		gutter = prompt_node(r)
		table.insert(body, code_head(state, c, r))
		table.insert(body, editor_node(state, c, lang_of(c), editing))
		local out = r and outputs_node(state, c, r)
		if out then
			table.insert(body, out)
		end
	else
		gutter = ui.node("text", { key = "pr", role = "rmd.prompt", text = "" })
		if editing then
			table.insert(body, editor_node(state, c, lang_of(c), true))
		elseif c.kind == "yaml" then
			table.insert(body, yaml_view(c))
		elseif c.src == "" then
			table.insert(body, ui.node("text", { key = "ed", spans = { ui.span("Empty Markdown cell · Enter to write", "muted") } }))
		else
			table.insert(body, ui.node("md", { key = "ed", text = c.src, role = "rmd.md" }))
		end
	end
	return ui.node("row", {
		key = "c" .. c.id,
		role = "rmd.cell." .. c.kind,
		mark = if is_sel then "pick" else nil,
		actions = { click = "sel=" .. c.id, dblclick = "edit=" .. c.id },
	}, {
		with(ui.col({ gutter }), { key = "gut", role = "rmd.gutter" }),
		ui.node("col", { key = "body", grow = 1, shrink = 1, role = "rmd.body" }, body),
	})
end

local function status_bar(state: State): Node
	local segs: { Node } = {}
	local mode = if state.mode == "edit" then "EDIT" elseif state.mode == "header" then "OPTIONS" else "COMMAND"
	table.insert(segs, ui.node("seg", { key = "mode", text = mode, tone = if state.mode == "command" then "neutral" else "accent", priority = 9 }))
	table.insert(segs, ui.node("seg", {
		key = "file",
		icon = "file",
		spans = {
			ui.span(state.name, "path"),
			ui.span(if state.dirty then "  ●" else "", "warning"),
		},
		title = "Open the .Rmd source",
		actions = { click = "source" },
		min = { w = "12ch" },
		priority = 8,
	}))
	if state.conflict then
		table.insert(segs, ui.node("seg", { key = "conflict", icon = "warn", tone = "warning", text = "changed on disk", priority = 7 }))
	end
	local k = state.k
	if k then
		local seg: { [string]: any } = { key = "kernel", side = "right", priority = 6, icon = "terminal" }
		if k.status == "idle" then
			seg.text = "R " .. (k.version or "") .. " · idle"
			seg.tone = "success"
		elseif k.status == "busy" then
			local waiting = #state.queue
			seg.text = "R · running" .. (if waiting > 0 then string.format(" (+%d queued)", waiting) else "")
			seg.tone = "pending"
			seg.actions = { click = "interrupt" }
			seg.title = "Click or press i i to interrupt"
		elseif k.status == "starting" then
			seg.text = "R · starting…"
			seg.tone = "pending"
		elseif k.status == "dead" then
			seg.text = "R stopped · click to restart"
			seg.tone = "error"
			seg.title = k.why
			seg.actions = { click = "restart" }
		else
			seg.text = "R · starts with the first chunk"
			seg.tone = "muted"
			seg.title = "Click to start R now"
			seg.actions = { click = "start" }
		end
		table.insert(segs, ui.node("seg", seg))
	end
	local kn = state.knit
	if kn then
		if kn.status == "running" then
			local text = if kn.kind == "export" then "Saving the HTML…" else "Knitting…"
			table.insert(segs, ui.node("seg", { key = "knit", side = "right", icon = "run", tone = "pending", text = text, priority = 5 }))
		elseif kn.status == "done" and kn.out then
			table.insert(segs, ui.node("seg", {
				key = "knit",
				side = "right",
				icon = "open",
				tone = "success",
				text = basename(kn.out),
				title = "Open " .. kn.out,
				actions = { click = "open-knit" },
				priority = 5,
			}))
		elseif kn.status == "failed" then
			local text = if kn.kind == "export" then "HTML failed" else "Knit failed"
			table.insert(segs, ui.node("seg", { key = "knit", side = "right", icon = "x", tone = "error", text = text, actions = { click = "show-knit" }, priority = 5 }))
		end
	end
	table.insert(segs, ui.node("seg", { key = "help", side = "right", icon = "keyboard", text = "?", title = "Keyboard shortcuts", actions = { click = "help" }, priority = 4 }))
	return ui.node("status", { key = "bar" }, segs)
end

local HELP_COMMAND = {
	{ "Enter", "edit the cell" },
	{ "Shift+Enter", "run, then select the next cell" },
	{ "Ctrl+Enter", "run the cell" },
	{ "Alt+Enter", "run, then insert a chunk below" },
	{ "j / k  ↓ / ↑", "select the next / previous cell" },
	{ "a / b  or Ctrl+Alt+I", "insert a chunk above / below (Ctrl+Alt+I: below, and edit it)" },
	{ "m / y", "make the cell Markdown / R" },
	{ "d d", "delete the cell (z brings it back)" },
	{ "x  c  v  V", "cut, copy, paste below, paste above" },
	{ "Alt+↑ / Alt+↓", "move the cell up / down" },
	{ "l", "edit the chunk's label and options" },
	{ "o / O", "hide or show outputs / clear them" },
	{ "R / P  or Ctrl+Alt+R / P", "run all chunks / all chunks above" },
	{ "i i / 0 0", "interrupt / restart R" },
	{ "e", "environment: the objects in R" },
	{ "s or Ctrl+S", "save (also saves on its own); an R Notebook also writes its .nb.html" },
	{ "K or Ctrl+Shift+K", "knit to HTML; an R Notebook writes its .nb.html from what you see" },
}

local HELP_EDIT = {
	{ "Esc", "back to command mode" },
	{ "Shift+Enter", "run the chunk, select the next cell" },
	{ "Ctrl+Enter", "run the current line or the selection" },
	{ "Ctrl+Shift+Enter", "run the whole chunk" },
	{ "Tab", "complete a name; ↑ ↓ pick, Tab or Enter accepts" },
	{ "Alt+-  /  Ctrl+Shift+M", "insert <-  /  |>" },
	{ "Ctrl+Shift+C or Ctrl+/", "comment or uncomment lines" },
	{ "Ctrl+Z / Ctrl+Shift+Z", "undo / redo" },
	{ "↑ on the first line, ↓ on the last", "move to the previous / next cell" },
}

local function help_overlay(): Node
	return ui.node("overlay", { key = "help", head = "Keyboard shortcuts", size = "lg", modal = true, role = "rmd.help" }, {
		ui.text({ ui.span("Command mode", "strong") }),
		ui.kv(HELP_COMMAND),
		ui.text({ ui.span("Edit mode", "strong") }),
		ui.kv(HELP_EDIT),
		ui.text({ ui.span("Esc or ? closes this", "muted") }),
	})
end

local function vars_overlay(state: State): Node
	local kids: { Node } = {}
	if not state.vars then
		table.insert(kids, ui.node("spinner", { style = "dots", label = "Asking R…" }))
	elseif #state.vars == 0 then
		table.insert(kids, ui.text({ ui.span(state.vars_note or "The global environment is empty.", "muted") }))
	else
		local rows = {}
		for i, v in state.vars do
			rows[i] = { id = "v" .. i, cells = {
				name = { ui.span(tostring(v.name), "strong") },
				class = { ui.span(tostring(v.class), "accent") },
				summary = { ui.span(tostring(v.summary), "muted") },
			} }
		end
		table.insert(kids, ui.node("table", {
			key = "vars",
			cols = {
				{ id = "name", head = "Name", priority = 3 },
				{ id = "class", head = "Class", priority = 1 },
				{ id = "summary", head = "Value", grow = 1, priority = 2 },
			},
			rows = rows,
		}))
	end
	return ui.node("overlay", { key = "vars", head = "Environment", size = "lg", modal = true, role = "rmd.vars" }, kids)
end

local function knit_overlay(state: State): Node
	local log = if state.knit then state.knit.log or "" else ""
	local head = if state.knit and state.knit.kind == "export" then "Saving the notebook's HTML failed" else "Knit failed"
	return ui.node("overlay", { key = "knit", head = head, size = "lg", modal = true, role = "rmd.knit" }, {
		ui.node("ansi", { key = "log", text = log, max = { h = "24lines" }, follow = true }),
		ui.text({ ui.span("Esc closes this", "muted") }),
	})
end

local function completion_overlay(state: State): Node?
	local comp = state.completion
	if not comp or state.mode ~= "edit" or not state.edit_id then
		return nil
	end
	local b = state.buf
	local typed = if b then string.sub(b.text, comp.from + 1, comp.to) else ""
	local items = {}
	for i, label in comp.items do
		table.insert(items, ui.node("item", { key = "i" .. i, label = label }))
	end
	return ui.node("overlay", { key = "comp", anchor = { caret = editor_id(state.edit_id) } }, {
		ui.node("list", {
			key = "items",
			selected = "layer.comp.items.i" .. comp.sel,
			filter = typed,
			max = { lines = 10 },
		}, items),
	})
end

local function picker_view(state: State): BlockView
	local p = state.picker
	local items = {}
	if p then
		for i, f in p.files do
			table.insert(items, ui.node("item", { key = "f" .. i, label = f, icon = "file-code", actions = { click = "pick=" .. i } }))
		end
	end
	return {
		main = ui.col({
			ui.text({ ui.span("Open an R Markdown notebook", "strong") }),
			ui.text({ ui.span(state.dir, "path") }),
			ui.node("list", {
				key = "files",
				selected = if p and p.files[p.sel] then "main.files.f" .. p.sel else nil,
				empty = { ui.span("No .Rmd files here.", "muted") },
			}, items),
			ui.text({ ui.span("↑/↓ choose · Enter opens · n creates Untitled.Rmd", "muted") }),
		}),
	}
end

local function view(state: State): BlockView
	if state.picker then
		return picker_view(state)
	end
	if not state.doc then
		return { main = ui.col({ ui.text({ ui.span(state.problem or "Nothing to show", "error") }) }) }
	end
	local nodes = {}
	for _, c in cells(state) do
		if not c.spacer then
			table.insert(nodes, cell_node(state, c))
		end
	end
	if #nodes == 0 then
		table.insert(nodes, ui.text({ ui.span("An empty notebook · b adds a chunk", "muted") }))
	end
	local layer: Node? = nil
	local over: Node? = if state.overlay == "help"
		then help_overlay()
		elseif state.overlay == "vars" then vars_overlay(state)
		elseif state.overlay == "knit" then knit_overlay(state)
		else completion_overlay(state)
	if over then
		layer = ui.col({ over })
	end
	return {
		main = with(ui.col(nodes), { role = "rmd.main" }),
		dock = ui.col({ status_bar(state) }),
		layer = layer,
	}
end

-- Keys ---------------------------------------------------------------------

-- A key as one string: the character it types for plain and shifted
-- printable keys ("j", "V", "?"), else modifiers and name ("ctrl+shift+k",
-- "shift+enter", "alt+up").
local function chord(k: Key): string
	if k.text and #k.text > 0 and k.name ~= "paste" and k.name ~= "space" and not (k.ctrl or k.meta or k.alt) and utf8.len(k.text) == 1 then
		return k.text
	end
	local parts = {}
	if k.ctrl or k.meta then
		table.insert(parts, "ctrl")
	end
	if k.alt then
		table.insert(parts, "alt")
	end
	if k.shift then
		table.insert(parts, "shift")
	end
	table.insert(parts, k.name)
	return table.concat(parts, "+")
end

-- Keys that do the same in both modes.
local function global_key(state: State, ch: string): boolean
	if ch == "ctrl+s" then
		if state.mode == "edit" then
			sync(state)
		end
		save_now(state)
	elseif ch == "ctrl+shift+k" then
		sync(state)
		knit(state)
	elseif ch == "ctrl+alt+r" then
		run_all(state)
	elseif ch == "ctrl+alt+p" then
		run_all(state, state.sel)
	elseif ch == "ctrl+alt+i" then
		-- RStudio's Insert Chunk: a new chunk below, ready to type in.
		if state.mode ~= "command" then
			sync(state)
			leave_edit(state)
		end
		local c = insert_cell(state, true)
		if c then
			enter_edit(state, c)
		end
	else
		return false
	end
	return true
end

local function run_and_advance(state: State, insert: boolean)
	local c = selected(state)
	if not c then
		return
	end
	if state.mode ~= "command" then
		leave_edit(state)
	end
	if c.kind == "code" then
		enqueue(state, { c.id })
	end
	if insert then
		local n = insert_cell(state, true)
		if n then
			enter_edit(state, n)
		end
		return
	end
	local nxt = neighbour(state, 1)
	if nxt and nxt.id ~= c.id then
		select(state, nxt.id)
	else
		local n = insert_cell(state, true)
		if n then
			select(state, n.id)
		end
	end
end

-- Runs the selection, or the caret's line and moves to the next line, as
-- Ctrl+Enter does in RStudio. The output replaces the chunk's.
local function run_line(state: State)
	local b = state.buf
	local c = find(state, state.edit_id)
	if not b or not c or c.kind ~= "code" then
		return
	end
	local a, z = textbuf.selection(b)
	local code: string
	if a and z then
		code = string.sub(b.text, a + 1, z)
	else
		local start = b.cursor
		while start > 0 and string.sub(b.text, start, start) ~= "\n" do
			start -= 1
		end
		local stop = string.find(b.text, "\n", b.cursor + 1, true)
		code = string.sub(b.text, start + 1, (stop or #b.text + 1) - 1)
		if stop then
			b.cursor = stop
			b.anchor = nil
		end
	end
	if string.match(code, "^%s*$") then
		return
	end
	if state.running or #state.queue > 0 then
		state.cx:toast("info", "R is busy", "Wait for the running chunk, or press Esc then i i to interrupt.")
		return
	end
	local k = state.k
	if not k or k.status ~= "idle" then
		if k and (k.status == "off" or k.status == "dead") then
			kernel.start(k)
		end
		state.cx:toast("info", "R is starting", "Try again in a moment.")
		return
	end
	exec(state, c.id, code)
end

local function edit_key(state: State, k: Key, ch: string): boolean
	local b = state.buf
	local c = find(state, state.edit_id)
	if not b or not c then
		leave_edit(state)
		return true
	end
	local comp = state.completion
	if comp then
		if ch == "down" or ch == "ctrl+n" then
			comp.sel = comp.sel % #comp.items + 1
			return true
		elseif ch == "up" or ch == "ctrl+p" then
			comp.sel = (comp.sel - 2) % #comp.items + 1
			return true
		elseif ch == "tab" or ch == "enter" then
			accept_completion(state)
			return true
		elseif ch == "escape" then
			state.completion = nil
			return true
		end
		-- Anything else edits the text; the list narrows after it.
	end
	if ch == "escape" then
		sync(state)
		leave_edit(state)
		return true
	elseif ch == "shift+enter" then
		sync(state)
		run_and_advance(state, false)
		return true
	elseif ch == "alt+enter" then
		sync(state)
		run_and_advance(state, true)
		return true
	elseif ch == "ctrl+shift+enter" then
		sync(state)
		if c.kind == "code" then
			enqueue(state, { c.id })
		end
		return true
	elseif ch == "ctrl+enter" then
		sync(state)
		if c.kind == "code" then
			run_line(state)
		else
			leave_edit(state)
		end
		return true
	elseif ch == "tab" and c.kind == "code" then
		local prefix = textbuf.line_prefix(b)
		if string.match(prefix, "[%w_.$@:]$") and not textbuf.selection(b) then
			complete(state, false)
			return true
		end
	end
	local before = textbuf.line_col(b)
	local res = textbuf.key(b, k, { lang = lang_of(c) })
	if res.copy then
		state.cx:copy(res.copy)
	end
	if res.changed then
		sync(state)
	end
	if state.completion then
		narrow(state)
	elseif res.changed and k.text and c.kind == "code" then
		complete_later(state)
	end
	if res.handled then
		-- Keep a growing chunk on screen as its caret moves down.
		if textbuf.line_col(b) ~= before then
			state.cx:frame({ { "reveal", editor_id(c.id), "nearest" } })
		end
		return true
	end
	if res.edge then
		local nxt = neighbour(state, if res.edge == "up" then -1 else 1)
		if nxt and nxt.id ~= c.id then
			sync(state)
			leave_edit(state)
			enter_edit(state, nxt, res.edge == "up")
		end
		return true
	end
	return false
end

local function header_key(state: State, k: Key, ch: string): boolean
	local b = state.buf
	local c = find(state, state.edit_id)
	if not b or not c then
		state.mode = "command"
		return true
	end
	if ch == "enter" then
		local text = string.gsub(b.text, "^%s*(.-)%s*$", "%1")
		rmd.set_header(c, if text == "" then "r" else text)
		changed(state)
		leave_edit(state)
	elseif ch == "escape" then
		leave_edit(state)
	elseif k.name == "paste" then
		textbuf.insert(b, (string.gsub(k.text or "", "[\r\n]+", " ")))
	else
		local res = textbuf.key(b, k, nil)
		if res.copy then
			state.cx:copy(res.copy)
		end
		return res.handled
	end
	return true
end

local function command_key(state: State, k: Key, ch: string): boolean
	local c = selected(state)
	local pending = state.pending
	state.pending = nil
	if pending and ch == pending then
		if ch == "d" then
			local removed = remove_selected(state)
			if removed then
				reveal(state, state.sel)
			end
		elseif ch == "i" then
			interrupt(state)
		elseif ch == "0" then
			restart(state)
		end
		return true
	end
	if ch == "j" or ch == "down" then
		local n = neighbour(state, 1)
		select(state, n and n.id)
	elseif ch == "k" or ch == "up" then
		local n = neighbour(state, -1)
		select(state, n and n.id)
	elseif ch == "home" then
		local vis = visible(state)
		select(state, vis[1] and vis[1].id)
	elseif ch == "end" then
		local vis = visible(state)
		select(state, vis[#vis] and vis[#vis].id)
	elseif ch == "page_down" or ch == "page_up" then
		if state.sel then
			state.cx:frame({ { "scroll", cell_node_id(state.sel), if ch == "page_down" then "page-down" else "page-up" } })
		end
		return false
	elseif ch == "enter" then
		if c then
			enter_edit(state, c)
		end
	elseif ch == "shift+enter" then
		run_and_advance(state, false)
	elseif ch == "alt+enter" then
		run_and_advance(state, true)
	elseif ch == "ctrl+enter" or ch == "ctrl+shift+enter" then
		if c then
			enqueue(state, { c.id })
		end
	elseif ch == "a" then
		insert_cell(state, false)
	elseif ch == "b" then
		insert_cell(state, true)
	elseif ch == "m" or ch == "y" then
		if c and state.doc then
			rmd.convert(state.doc, c, if ch == "m" then "md" else "code")
			changed(state)
		end
	elseif ch == "d" or ch == "i" or ch == "0" then
		state.pending = ch
	elseif ch == "x" then
		local removed = remove_selected(state)
		if removed then
			state.clip = {}
			for _, r in removed do
				if not r.spacer then
					-- a snapshot: undoing the cut (z) brings the cell itself back
					table.insert(state.clip, table.clone(r))
				end
			end
		end
	elseif ch == "c" then
		if c and c.kind ~= "yaml" then
			-- a snapshot, so editing the cell afterwards doesn't change the copy
			state.clip = { table.clone(c) }
			state.cx:toast("info", "Copied the cell", "v pastes it below, V above")
		end
	elseif ch == "v" then
		paste(state, true)
	elseif ch == "V" then
		paste(state, false)
	elseif ch == "z" then
		local t = table.remove(state.trash)
		if t then
			insert_at(state, t.at, t.cells)
			for _, r in t.cells do
				if not r.spacer then
					state.sel = r.id
				end
			end
			changed(state)
			reveal(state, state.sel)
		end
	elseif ch == "alt+up" or ch == "alt+k" then
		move_selected(state, -1)
	elseif ch == "alt+down" or ch == "alt+j" then
		move_selected(state, 1)
	elseif ch == "l" then
		if c then
			edit_header(state, c)
		end
	elseif ch == "o" then
		if c and state.runs[c.id] then
			local r = state.runs[c.id]
			r.collapsed = not r.collapsed
		end
	elseif ch == "O" then
		if c and state.runs[c.id] then
			local r = state.runs[c.id]
			drop_files(state, r.outputs)
			r.outputs, r.live, r.count, r.ms = {}, nil, nil, nil
			write_cache(state)
		end
	elseif ch == "R" then
		run_all(state)
	elseif ch == "P" then
		run_all(state, state.sel)
	elseif ch == "e" then
		state.overlay = "vars"
		state.vars = nil
		state.vars_note = nil
		local session = state.k
		if session then
			kernel.vars(session, function(vars)
				if state.overlay == "vars" then
					state.vars = vars or {}
					state.vars_note = if vars
						then nil
						elseif session.status == "busy" then "R is busy running a chunk; press e again when it finishes."
						elseif session.status == "idle" then "R didn't answer; press e to try again."
						else "R isn't running yet; it starts with the first chunk you run."
					state.cx:render()
				end
			end)
		end
	elseif ch == "s" then
		save_now(state)
	elseif ch == "K" then
		knit(state)
	elseif ch == "?" or ch == "h" then
		state.overlay = "help"
	elseif ch == "escape" then
		return pending ~= nil
	else
		return pending ~= nil
	end
	return true
end

-- Points the R session at the open document's folder and reattaches to the
-- one a previous run of this block left running. A new session starts with
-- the first chunk that runs, never on open (see kernel.luau).
local function connect(state: State, saved: kernel.Saved?)
	local k = state.k
	if not k or not state.doc then
		return
	end
	k.dir = state.dir
	k.data = data_dir(state)
	kernel.attach(k, saved)
end

local function picker_key(state: State, ch: string): boolean
	local p = state.picker
	if not p then
		return false
	end
	if ch == "down" or ch == "j" then
		p.sel = math.min(p.sel + 1, math.max(1, #p.files))
	elseif ch == "up" or ch == "k" then
		p.sel = math.max(p.sel - 1, 1)
	elseif ch == "enter" and p.files[p.sel] then
		state.picker = nil
		open_path(state, state.dir .. "/" .. p.files[p.sel])
		restore_cache(state)
		connect(state, nil)
	elseif ch == "n" then
		local name = "Untitled.Rmd"
		local n = 1
		while tern.fs.exists(state.dir .. "/" .. name) do
			n += 1
			name = "Untitled-" .. n .. ".Rmd"
		end
		state.picker = nil
		open_path(state, state.dir .. "/" .. name)
		save_file(state)
		connect(state, nil)
	else
		return false
	end
	return true
end

-- Background ---------------------------------------------------------------

local function tick(state: State)
	tern.timer(TICK_MS, function()
		if state.stopped then
			return
		end
		if not running(state.cx.pane) then
			-- The block was closed: stop R with it.
			state.stopped = true
			if state.k then
				kernel.stop(state.k)
			end
			return
		end
		state.ticks += 1
		if state.k and state.ticks % HEARTBEAT_TICKS == 0 then
			kernel.heartbeat(state.k)
		end
		if state.path and state.doc and state.ticks % DISK_TICKS == 0 then
			local text = read_doc(state.path :: string)
			if text and text ~= state.disk then
				if state.dirty then
					if not state.conflict then
						state.conflict = true
						state.cx:render()
					end
				elseif state.mode == "command" then
					reload(state, text)
					state.cx:toast("info", "Reloaded " .. state.name, "The file changed on disk.")
					state.cx:render()
				end
			end
		end
		tick(state)
	end)
end

-- The block ------------------------------------------------------------------

local notebook: BlockDef<State> = {
	init = function(cx, args, saved)
		local state: State = {
			cx = cx,
			path = nil,
			dir = cx.cwd or tern.getenv("HOME") or "/",
			name = "R Notebook",
			doc = nil,
			problem = nil,
			runs = {},
			sel = nil,
			mode = "command",
			buf = nil,
			edit_id = nil,
			disk = "",
			dirty = false,
			changes = 0,
			typing = 0,
			conflict = false,
			queue = {},
			running = nil,
			count = 0,
			k = nil,
			pending = nil,
			clip = {},
			trash = {},
			overlay = nil,
			vars = nil,
			vars_note = nil,
			knit = nil,
			export_again = false,
			completion = nil,
			blobs = {},
			picker = nil,
			stopped = false,
			ticks = 0,
		}
		local path = if saved and saved.path then saved.path elseif args[1] then absolute(args[1], cx.cwd) else nil
		make_docs_private()
		local k = kernel.new(state.dir, tern.plugin.data .. "/docs/untitled", function() end)
		k.notify = function()
			if state.stopped or not running(cx.pane) then
				return
			end
			if k.notice then
				cx:toast("info", k.notice)
				k.notice = nil
			end
			run_next(state)
			cx:render()
		end
		state.k = k
		if path then
			open_path(state, path)
			if saved and type(saved.unsaved) == "string" and state.doc then
				-- Edits the last run hadn't saved yet (a reload mid-edit).
				reload(state, saved.unsaved)
				state.disk = read_doc(path) or ""
				state.dirty = true
			end
			restore_cache(state)
			if state.doc then
				local sel = saved and tonumber(saved.sel)
				if sel then
					local vis = visible(state)
					if vis[sel] then
						state.sel = vis[sel].id
					end
				end
			end
			state.count = if saved then tonumber(saved.count) or 0 else 0
			connect(state, saved and saved.kernel)
			if saved then
				reveal(state, state.sel)
			end
		else
			local files = {}
			local ok, names = pcall(tern.fs.list, state.dir)
			if ok then
				for _, n in names do
					if string.match(string.lower(n), "%.rmd$") then
						table.insert(files, n)
					end
				end
			end
			state.picker = { files = files, sel = 1 }
		end
		tick(state)
		return state
	end,

	title = function(state)
		return state.name .. (if state.dirty then " ●" else "")
	end,

	view = function(state, _cx)
		return view(state)
	end,

	key = function(state, k, _cx)
		local ch = chord(k)
		if state.picker then
			return picker_key(state, ch)
		end
		if not state.doc then
			return false
		end
		if state.overlay then
			if ch == "escape" or ch == "q" or (state.overlay == "help" and ch == "?") then
				state.overlay = nil
				return true
			end
			return false
		end
		if global_key(state, ch) then
			return true
		end
		if state.mode == "edit" then
			return edit_key(state, k, ch)
		elseif state.mode == "header" then
			return header_key(state, k, ch)
		end
		return command_key(state, k, ch)
	end,

	event = function(state, ev, _cx)
		if ev.ev == "focus" then
			-- A click in an editable field: edit that cell.
			local id = tonumber(string.match(tostring(ev.id), "^main%.c(%d+)%."))
			local c = find(state, id)
			if c and not (state.mode == "edit" and state.edit_id == c.id) then
				sync(state)
				enter_edit(state, c)
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		local act, value = ev.act, ev.value
		local id = tonumber(value)
		if act == "sel" and id then
			if state.edit_id ~= id then
				if state.mode ~= "command" then
					sync(state)
					leave_edit(state)
				end
				select(state, id)
			end
		elseif act == "edit" and id then
			local c = find(state, id)
			if c and state.edit_id ~= id then
				sync(state)
				enter_edit(state, c)
			end
		elseif act == "run" and id then
			if state.edit_id == id then
				sync(state)
			end
			state.sel = id
			enqueue(state, { id })
		elseif act == "above" and id then
			state.sel = id
			run_all(state, id)
		elseif act == "stop" or act == "interrupt" then
			interrupt(state)
		elseif act == "restart" then
			restart(state)
		elseif act == "start" then
			if state.k and (state.k.status == "off" or state.k.status == "dead") then
				kernel.start(state.k)
			end
		elseif act == "log" and value then
			local cid, oi = string.match(value, "^(%d+):(%d+)$")
			local r = state.runs[tonumber(cid) or -1]
			local o = r and r.outputs[tonumber(oi) or -1]
			local file = o and data_file(state, o.file)
			if file then
				state.cx:open(file)
			end
		elseif act == "fold" and id then
			run_of(state, id).collapsed = false
		elseif act == "page" and value then
			local cid, oi, delta = string.match(value, "^(%d+):(%d+):(%-?%d+)$")
			local r = state.runs[tonumber(cid) or -1]
			local o = r and r.outputs[tonumber(oi) or -1]
			if r and o and o.rows then
				local i = tonumber(oi) :: number
				local last = math.max(0, math.ceil(#o.rows / TABLE_PAGE) - 1)
				r.pages[i] = math.clamp((r.pages[i] or 0) + (tonumber(delta) or 0), 0, last)
			end
		elseif act == "help" then
			state.overlay = if state.overlay == "help" then nil else "help"
		elseif act == "open-knit" and state.knit and state.knit.out then
			state.cx:open(state.knit.out)
		elseif act == "source" and state.path then
			if state.dirty then
				save_file(state)
			end
			state.cx:open(state.path)
		elseif act == "show-knit" then
			state.overlay = "knit"
		elseif act == "pick" and id and state.picker then
			state.picker.sel = id
			picker_key(state, "enter")
		end
	end,

	save = function(state)
		local vis = visible(state)
		local sel = 1
		for i, c in vis do
			if c.id == state.sel then
				sel = i
			end
		end
		return {
			path = state.path,
			sel = sel,
			unsaved = if state.dirty and state.doc then text_of(state) else nil,
			kernel = if state.k then kernel.saved(state.k) else nil,
			count = state.count,
		}
	end,
}

tern.block.define("notebook", notebook)
