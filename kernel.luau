--!strict
-- kernel.luau: starts one R session (kernel.R) per notebook and talks to it
-- over HTTP on 127.0.0.1.
--
-- tern.process.run only reports a program when it exits, so the session is a
-- small HTTP server: the plugin starts `Rscript kernel.R`, polls /ping until
-- it answers, then sends each chunk to /exec and gets its outputs back. Every
-- request carries a random token. The session exits on its own when nobody
-- pinged it for two minutes, so a closed block never leaves R running.

local M = {}

export type Status = "off" | "starting" | "idle" | "busy" | "dead"

export type Kernel = {
	status: Status,
	-- Bumped by every start and stop: callbacks of an older session check it
	-- and drop their results.
	gen: number,
	port: number,
	token: string,
	pid: number?,
	version: string?,
	-- R's working directory (the document's folder) and where it writes
	-- plots and stream files.
	dir: string,
	data: string,
	-- Why the session is dead, for the status bar.
	why: string?,
	-- A one-off message for the person, taken and shown by the block.
	notice: string?,
	-- Called after every status change.
	notify: () -> (),
}

export type Saved = { port: number, token: string, pid: number? }

local START_TRIES = 5
local PING_EVERY_MS = 150
local START_TIMEOUT_MS = 20000
local EXEC_TIMEOUT_MS = 24 * 60 * 60 * 1000
-- kernel.R's KERNEL_VERSION; a session reporting another one is restarted.
local KERNEL_VERSION = "1.1.0"

function M.new(dir: string, data: string, notify: () -> ()): Kernel
	return {
		status = "off",
		gen = 0,
		port = 0,
		token = "",
		pid = nil,
		version = nil,
		dir = dir,
		data = data,
		why = nil,
		notice = nil,
		notify = notify,
	}
end

local function set(k: Kernel, status: Status, why: string?)
	k.status = status
	k.why = why
	k.notify()
end

local function last_lines(text: string, n: number): string
	local lines = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(lines, line)
	end
	return table.concat(lines, "\n", math.max(1, #lines - n + 1), #lines)
end

-- One request to the session. `cb(data, err)` gets the decoded JSON body, or
-- nil and a reason. Results of an older session are dropped.
local function request(k: Kernel, method: string, path: string, body: any, timeout: number, cb: (any, string?) -> ())
	local gen = k.gen
	local opts = {
		method = method,
		headers = { ["X-Token"] = k.token, ["Content-Type"] = "application/json" },
		body = if body ~= nil then tern.json.encode(body) else nil,
		timeout_ms = timeout,
	}
	tern.fetch(string.format("http://127.0.0.1:%d%s", k.port, path), opts, function(r)
		if k.gen ~= gen then
			return
		end
		if r.error then
			cb(nil, r.error)
		elseif r.status ~= 200 then
			cb(nil, string.format("HTTP %d", r.status))
		else
			local ok, data = pcall(tern.json.decode, r.body)
			if ok then
				cb(data, nil)
			else
				cb(nil, "bad reply from R")
			end
		end
	end)
end

local function poll_ready(k: Kernel, deadline: number)
	local gen, port = k.gen, k.port
	request(k, "GET", "/ping", nil, 1000, function(data, _err)
		-- A retry on another port runs its own poll.
		if k.gen ~= gen or k.port ~= port or k.status ~= "starting" then
			return
		end
		if data and data.ok then
			k.pid = tonumber(data.pid)
			k.version = data.version
			set(k, "idle")
		elseif tern.now() > deadline then
			M.stop(k)
			set(k, "dead", "R did not start within 20 s")
		else
			tern.timer(PING_EVERY_MS, function()
				if k.gen == gen and k.port == port and k.status == "starting" then
					poll_ready(k, deadline)
				end
			end)
		end
	end)
end

-- tern.process.run, returning the error when the program can't start.
local function run(argv: { string }, opts: ProcessOptions?, cb: (ProcessResult) -> ()): string?
	local ok, err = pcall(function()
		tern.process.run(argv, opts, function(r)
			cb(r)
		end)
	end)
	return if ok then nil else tostring(err)
end

-- Where R's own stdout and stderr go: compiler output from
-- install.packages(), system() calls, C-level messages. kernel.R empties it
-- at the start of every chunk and reports what lands in it as `console`
-- outputs; the plugin also tails it while a chunk runs.
function M.console_log(k: Kernel): string
	return k.data .. "/console.log"
end

local function spawn(k: Kernel, tries: number)
	local gen = k.gen
	k.port = math.random(20000, 60999)
	local argv = {
		"sh",
		"-c",
		'exec "$@" >>"$TERN_RMD_LOG" 2>&1',
		"sh",
		"Rscript",
		tern.plugin.dir .. "/kernel.R",
		"--port",
		tostring(k.port),
		"--dir",
		k.dir,
		"--data",
		k.data,
		"--idle",
		"120",
	}
	local log = M.console_log(k)
	pcall(tern.fs.write, log, "")
	-- The token goes through the environment, which `ps` doesn't show.
	local env = { TERN_RMD_TOKEN = k.token, TERN_RMD_LOG = log }
	local err = run(argv, { cwd = k.dir, env = env }, function(r)
		if k.gen ~= gen then
			return
		end
		if r.status == 3 and k.status == "starting" and tries < START_TRIES then
			-- The port was taken: try another one.
			spawn(k, tries + 1)
			return
		end
		k.pid = nil
		local ok, text = pcall(tern.fs.read, log)
		local detail = last_lines(if ok then text else r.stderr, 6)
		set(k, "dead", if detail ~= "" then detail else string.format("R exited with status %d", r.status))
	end)
	if err then
		set(k, "dead", "Couldn't start Rscript: " .. err)
		return
	end
	poll_ready(k, tern.now() + START_TIMEOUT_MS)
end

-- Starts a fresh session (stopping any current one).
function M.start(k: Kernel)
	M.stop(k)
	k.gen += 1
	local gen = k.gen
	k.version = nil
	set(k, "starting")
	pcall(tern.fs.mkdir, k.data)
	-- 16 random bytes from the OS for the token.
	local err = run({ "od", "-An", "-tx1", "-N16", "/dev/urandom" }, nil, function(r)
		if k.gen ~= gen then
			return
		end
		local token = string.gsub(r.stdout, "%s", "")
		if r.status ~= 0 or #token ~= 32 then
			set(k, "dead", "Couldn't read random bytes for the session token")
			return
		end
		k.token = token
		spawn(k, 1)
	end)
	if err then
		set(k, "dead", "Couldn't start od: " .. err)
	end
end

-- Reattaches to the session a previous run of the block left (after a plugin
-- reload or a daemon restart), else starts a new one.
function M.attach(k: Kernel, saved: Saved?)
	if not saved or not saved.port or not saved.token then
		M.start(k)
		return
	end
	k.gen += 1
	local gen = k.gen
	k.port, k.token, k.pid = saved.port, saved.token, saved.pid
	set(k, "starting")
	request(k, "GET", "/ping", nil, 1500, function(data, _err)
		if k.gen ~= gen then
			return
		end
		if data and data.ok and data.kernel == KERNEL_VERSION then
			k.pid = tonumber(data.pid)
			k.version = data.version
			set(k, "idle")
		else
			if data and data.ok then
				-- A session from an older kernel.R: replace it, so the
				-- plugin and R speak the same protocol.
				k.pid = tonumber(data.pid)
				k.notice = "R restarted after the plugin updated; run your chunks again."
			end
			M.start(k)
		end
	end)
end

function M.saved(k: Kernel): Saved?
	if k.status == "idle" or k.status == "busy" then
		return { port = k.port, token = k.token, pid = k.pid }
	end
	return nil
end

-- Stops the session (SIGTERM) and drops its pending callbacks.
function M.stop(k: Kernel)
	if k.pid and (k.status == "idle" or k.status == "busy" or k.status == "starting") then
		run({ "kill", "-TERM", tostring(k.pid) }, nil, function(_r) end)
	end
	k.gen += 1
	k.pid = nil
	k.status = "off"
end

-- Interrupts the running chunk (SIGINT, like Ctrl+C at an R prompt).
function M.interrupt(k: Kernel)
	if k.pid and k.status == "busy" then
		run({ "kill", "-INT", tostring(k.pid) }, nil, function(_r) end)
	end
end

-- Runs code. `cb(result, err)`: result is kernel.R's /exec reply.
function M.exec(k: Kernel, req: { [string]: any }, cb: (any, string?) -> ())
	local gen = k.gen
	set(k, "busy")
	request(k, "POST", "/exec", req, EXEC_TIMEOUT_MS, function(data, err)
		if k.gen ~= gen then
			return
		end
		if data then
			set(k, "idle")
		else
			-- A session that stops answering mid-run has died: the process
			-- callback usually says so first, with R's own last words.
			set(k, "dead", "Lost the R session: " .. tostring(err))
		end
		cb(data, err)
	end)
end

-- Completions for the current line up to the caret (idle sessions only).
function M.complete(k: Kernel, line: string, cb: (string, { string }) -> ())
	if k.status ~= "idle" then
		return
	end
	request(k, "POST", "/complete", { line = line }, 3000, function(data, _err)
		if data and data.ok then
			cb(data.token or "", data.matches or {})
		end
	end)
end

-- The global environment's objects (idle sessions only).
function M.vars(k: Kernel, cb: ({ any }?) -> ())
	if k.status ~= "idle" then
		cb(nil)
		return
	end
	request(k, "GET", "/vars", nil, 5000, function(data, _err)
		cb(if data and data.ok then data.vars else nil)
	end)
end

-- Keeps an idle session alive and notices one that died while nobody
-- watched its process (after a reload, the exit callback is gone).
function M.heartbeat(k: Kernel)
	if k.status ~= "idle" then
		return
	end
	request(k, "GET", "/ping", nil, 5000, function(data, err)
		if k.status == "idle" and not data then
			k.pid = nil
			set(k, "dead", "The R session stopped answering (" .. tostring(err) .. ")")
		end
	end)
end

return M
