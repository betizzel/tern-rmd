--!strict
-- kernel.luau: starts one R session (kernel.R) per notebook and talks to it
-- over HTTP on 127.0.0.1.
--
-- tern.process.run only reports a program when it exits, so the session is a
-- small HTTP server: the plugin starts `Rscript kernel.R`, polls /ping until
-- it answers, then sends each chunk to /exec and gets its outputs back. The
-- session exits on its own when nobody pinged it for two minutes, so a
-- closed block never leaves R running.
--
-- R starts when a chunk first runs, never when a notebook merely opens:
-- starting R runs code (the .Rprofile R finds), and opening a file must not.
--
-- Two secrets guard the connection, both fresh for every start: the token
-- proves to R that a request comes from this plugin, and the proof (which R
-- sends back as the X-Proof header) proves to the plugin that the reply comes
-- from this session, not from some other program that took the port. A
-- reply without the right proof is treated like no reply at all.

local M = {}

export type Status = "off" | "starting" | "idle" | "busy" | "dead"

export type Kernel = {
	status: Status,
	-- Bumped by every start and stop: callbacks of an older session check it
	-- and drop their results.
	gen: number,
	port: number,
	token: string,
	proof: string,
	-- R's process, as a reply carrying the proof reported it: safe to signal.
	pid: number?,
	-- A session saved before a reload that could not be reattached. Its pid
	-- is only signalled after `ps` confirms it still runs kernel.R on `port`.
	stale: { pid: number, port: number }?,
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

export type Saved = { port: number, token: string, proof: string?, pid: number? }

local START_TRIES = 5
local PING_EVERY_MS = 150
local START_TIMEOUT_MS = 20000
local EXEC_TIMEOUT_MS = 24 * 60 * 60 * 1000
local IDLE_EXIT_S = 120
-- kernel.R's KERNEL_VERSION; a session reporting another one is replaced.
local KERNEL_VERSION = "2.0.0"

function M.new(dir: string, data: string, notify: () -> ()): Kernel
	return {
		status = "off",
		gen = 0,
		port = 0,
		token = "",
		proof = "",
		pid = nil,
		stale = nil,
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

-- A process id fit for `kill`: a whole number above 1 (`kill -1` would
-- signal every process the person owns, `kill 0` the whole group).
local function valid_pid(x: any): number?
	local n = tonumber(x)
	if n and n > 1 and n < 2 ^ 31 and n % 1 == 0 then
		return n
	end
	return nil
end

-- One request to the session. `cb(data, err)` gets the decoded JSON body, or
-- nil and a reason. Results of an older session are dropped.
local function request(k: Kernel, method: string, path: string, body: any, timeout: number, cb: (any, string?) -> ())
	local gen, proof = k.gen, k.proof
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
		elseif r.headers["x-proof"] ~= proof then
			cb(nil, "another program answered on R's port")
		elseif r.status ~= 200 then
			cb(nil, string.format("HTTP %d", r.status))
		else
			local ok, data = pcall(tern.json.decode, r.body)
			if ok and type(data) == "table" then
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
			k.pid = valid_pid(data.pid)
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

-- Sends `sig` to a pid saved before a reload, but only when `ps` shows it
-- still runs kernel.R on `port`: after a crash or a reboot that pid may
-- belong to an unrelated program. `cb(true)` when the process was ours.
local function signal_stale(pid: number, port: number, sig: string, cb: (boolean) -> ())
	local err = run({ "ps", "-p", tostring(pid), "-o", "args=" }, nil, function(r)
		local args = r.stdout .. " "
		local ours = r.status == 0
			and string.find(args, "kernel.R", 1, true) ~= nil
			and string.find(args, "--port " .. port .. " ", 1, true) ~= nil
		if ours then
			run({ "kill", "-" .. sig, tostring(pid) }, nil, function(_r) end)
		end
		cb(ours)
	end)
	if err then
		cb(false)
	end
end

-- R reads `.Renviron` and sources `.Rprofile` from its working directory;
-- that is how renv and other project setups take effect. In a folder other
-- people can write to (/tmp, someone else's folder) those files could have
-- been planted, so R is pointed at the home directory's instead. The folder
-- counts as the person's own when it, and any of the two files in it, belong
-- to them and are not writable by everyone.
-- `cb(env, skipped)`: variables to add to R's environment, and the dotfiles
-- of the folder that R will not read (for a notice).
local DOTFILE_CHECK = [[
d=$1
me=$(id -u)
mine() { [ -n "$(find -L "$1" -prune -user "$me" ! -perm -0002 -print 2>/dev/null)" ]; }
ok=1
mine "$d" || ok=0
for f in .Rprofile .Renviron; do
  if [ -e "$d/$f" ] || [ -L "$d/$f" ]; then
    mine "$d/$f" || ok=0
    echo "$f"
  fi
done
[ $ok = 1 ] && echo "own folder"
exit 0
]]

function M.dotfile_env(dir: string, cb: (env: { [string]: string }, skipped: { string }) -> ())
	local function home_only(found: { string })
		local home = tern.getenv("HOME") or ""
		cb({
			R_PROFILE_USER = tern.getenv("R_PROFILE_USER") or (home .. "/.Rprofile"),
			R_ENVIRON_USER = tern.getenv("R_ENVIRON_USER") or (home .. "/.Renviron"),
		}, found)
	end
	local err = run({ "sh", "-c", DOTFILE_CHECK, "sh", dir }, nil, function(r)
		local found = {}
		local own = false
		for line in string.gmatch(r.stdout, "[^\n]+") do
			if line == "own folder" then
				own = true
			else
				table.insert(found, line)
			end
		end
		if r.status == 0 and own then
			cb({}, {})
		else
			home_only(found)
		end
	end)
	if err then
		home_only({})
	end
end

-- Where R's own stdout and stderr go: compiler output from
-- install.packages(), system() calls, C-level messages. kernel.R empties it
-- at the start of every chunk and reports what lands in it as `console`
-- outputs; the plugin also tails it while a chunk runs.
function M.console_log(k: Kernel): string
	return k.data .. "/console.log"
end

local spawn: (k: Kernel, tries: number, profile: { [string]: string }) -> ()

-- Before R starts, the shell makes the data folder private and starts a new
-- console log (a fresh file, so nothing that held the old one open keeps
-- reading), then becomes R with its output going to that log.
local LAUNCH = 'mkdir -p -m 700 "$TERN_RMD_DATA" && chmod 700 "$TERN_RMD_DATA" && '
	.. 'rm -f "$TERN_RMD_LOG" && exec "$@" >>"$TERN_RMD_LOG" 2>&1'

local function launch(k: Kernel, tries: number, profile: { [string]: string })
	local gen = k.gen
	k.port = math.random(20000, 60999)
	local argv = {
		"sh",
		"-c",
		LAUNCH,
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
		tostring(IDLE_EXIT_S),
	}
	local log = M.console_log(k)
	-- The secrets go through the environment, which `ps` doesn't show.
	local env: { [string]: string } = {
		TERN_RMD_TOKEN = k.token,
		TERN_RMD_PROOF = k.proof,
		TERN_RMD_LOG = log,
		TERN_RMD_DATA = k.data,
	}
	for name, value in profile do
		env[name] = value
	end
	local err = run(argv, { cwd = k.dir, env = env }, function(r)
		if k.gen ~= gen then
			return
		end
		if r.status == 3 and k.status == "starting" and tries < START_TRIES then
			-- The port was taken: try another one, with fresh secrets.
			spawn(k, tries + 1, profile)
			return
		end
		k.pid = nil
		local ok, text = pcall(tern.fs.read, log)
		local detail = last_lines(if ok and text ~= "" then text else r.stderr, 6)
		if r.status == 127 or string.find(detail, "Rscript: not found", 1, true) then
			detail = "Couldn't find Rscript. Install R (https://cloud.r-project.org) and make sure "
				.. "`Rscript` is on the PATH Tern starts programs with."
		elseif r.status == 4 then
			detail = "R is missing packages the notebook needs (evaluate 1.0.4 or newer, jsonlite). "
				.. "Install them with:\n"
				.. string.format("  Rscript '%s/deps.R' --install\n", tern.plugin.dir)
				.. 'or, in R: install.packages(c("evaluate", "jsonlite"))'
		end
		set(k, "dead", if detail ~= "" then detail else string.format("R exited with status %d", r.status))
	end)
	if err then
		set(k, "dead", "Couldn't start R: " .. err)
		return
	end
	poll_ready(k, tern.now() + START_TIMEOUT_MS)
end

-- One attempt to start R: fresh secrets from the OS (32 random bytes: the
-- token and the proof), then the process.
function spawn(k: Kernel, tries: number, profile: { [string]: string })
	local gen = k.gen
	local err = run({ "od", "-An", "-tx1", "-N32", "/dev/urandom" }, nil, function(r)
		if k.gen ~= gen then
			return
		end
		local hex = string.gsub(r.stdout, "%s", "")
		if r.status ~= 0 or #hex ~= 64 then
			set(k, "dead", "Couldn't read random bytes for the session's secrets")
			return
		end
		k.token = string.sub(hex, 1, 32)
		k.proof = string.sub(hex, 33, 64)
		launch(k, tries, profile)
	end)
	if err then
		set(k, "dead", "Couldn't start od: " .. err)
	end
end

-- Starts a fresh session (stopping any current one).
function M.start(k: Kernel)
	M.stop(k)
	k.gen += 1
	local gen = k.gen
	k.version = nil
	if tern.runtime.os == "windows" then
		set(k, "dead", "Running chunks needs Linux or macOS; on Windows, use Tern in WSL.")
		return
	end
	set(k, "starting")
	M.dotfile_env(k.dir, function(profile, skipped)
		if k.gen ~= gen then
			return
		end
		if #skipped > 0 then
			k.notice = string.format(
				"R didn't read this folder's %s (another user owns it or can change it); it used the one in your home folder.",
				table.concat(skipped, " and ")
			)
		end
		spawn(k, 1, profile)
	end)
end

-- Reattaches to the session a previous run of the block left (after a plugin
-- reload or a daemon restart). Without one, nothing starts: R starts with the
-- first chunk that runs.
function M.attach(k: Kernel, saved: Saved?)
	if not saved then
		return
	end
	local pid = valid_pid(saved.pid)
	if pid and saved.port then
		k.stale = { pid = pid, port = saved.port }
	end
	if not saved.port or not saved.token or not saved.proof then
		-- A session from a plugin version that predates the proof.
		M.stop(k)
		set(k, "off")
		return
	end
	k.gen += 1
	local gen = k.gen
	k.port, k.token, k.proof, k.pid = saved.port, saved.token, saved.proof, nil
	set(k, "starting")
	request(k, "GET", "/ping", nil, 1500, function(data, _err)
		if k.gen ~= gen then
			return
		end
		if data and data.ok and data.kernel == KERNEL_VERSION then
			k.pid = valid_pid(data.pid)
			k.stale = nil
			k.version = data.version
			set(k, "idle")
		else
			-- Gone, busy past the timeout, or an older kernel.R: stop what is
			-- left of it, and start afresh with the next chunk.
			M.stop(k)
			set(k, "off")
		end
	end)
end

function M.saved(k: Kernel): Saved?
	if k.status == "idle" or k.status == "busy" then
		return { port = k.port, token = k.token, proof = k.proof, pid = k.pid }
	end
	return nil
end

-- Stops the session (SIGTERM) and drops its pending callbacks.
function M.stop(k: Kernel)
	if k.pid and (k.status == "idle" or k.status == "busy" or k.status == "starting") then
		run({ "kill", "-TERM", tostring(k.pid) }, nil, function(_r) end)
	end
	local stale = k.stale
	if stale then
		k.stale = nil
		signal_stale(stale.pid, stale.port, "TERM", function(ours)
			if ours then
				k.notice = "The R session from before the reload was stopped; run your chunks again."
				k.notify()
			end
		end)
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
		if data and data.ok and type(data.matches) == "table" then
			local matches = {}
			for _, m in data.matches do
				if type(m) == "string" then
					table.insert(matches, m)
				end
			end
			cb(if type(data.token) == "string" then data.token else "", matches)
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
		cb(if data and data.ok and type(data.vars) == "table" then data.vars else nil)
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
