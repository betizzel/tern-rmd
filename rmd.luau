--!strict
-- rmd.luau: splits an R Markdown document into notebook cells and joins them
-- back byte for byte.
--
-- An .Rmd file is YAML front matter, then Markdown with code chunks:
--
--     ```{r label, fig.width=8}
--     code
--     ```
--
-- Chunks are found the way knitr finds them (a fence line of three or more
-- backticks followed by `{engine ...}`, closed by the next bare fence line),
-- so a file round-trips through parse and serialize unchanged, and what the
-- notebook calls a chunk is what knitr will run when the file is knitted.
--
-- Markdown has no cell boundaries of its own: the text between two chunks is
-- one Markdown cell. Text that is only blank lines becomes a *spacer*, kept so
-- the file keeps its spacing, but never shown or selected.

export type Kind = "yaml" | "md" | "code"

export type Cell = {
	id: number,
	kind: Kind,
	-- The editable text: the YAML between its fences, the Markdown without
	-- its surrounding blank lines, or the chunk's code without its fences.
	src: string,
	-- Markdown: the blank lines before and the whitespace after `src`.
	lead: string,
	trail: string,
	spacer: boolean,
	-- Code: the fence line is `prefix .. fence .. "{" .. header .. "}"`,
	-- unless `open` (the line exactly as read) is still set.
	prefix: string,
	fence: string,
	header: string,
	open: string?,
	-- Code and YAML: the closing fence line as read; YAML: its opening line.
	close: string,
	-- Code: the chunk had no lines at all between its fences.
	bare: boolean,
}

export type Doc = {
	cells: { Cell },
	seq: number,
	crlf: boolean,
	final_newline: boolean,
}

local M = {}

local function cell(doc: Doc, kind: Kind): Cell
	doc.seq += 1
	return {
		id = doc.seq,
		kind = kind,
		src = "",
		lead = "",
		trail = "",
		spacer = false,
		prefix = "",
		fence = "```",
		header = "r",
		open = nil,
		close = "```",
		bare = false,
	}
end

-- Splits raw Markdown into blank lead, body and trailing whitespace.
local function split_md(c: Cell, raw: string)
	local lead = ""
	local rest = raw
	while true do
		local line = string.match(rest, "^[ \t]*\n")
		if not line then
			break
		end
		lead ..= line
		rest = string.sub(rest, #line + 1)
	end
	local body, trail = string.match(rest, "^(.-)(%s*)$")
	c.lead, c.src, c.trail = lead, body or "", trail or ""
	c.spacer = c.src == ""
end

local function chunk_begin(line: string): (string?, string?, string?)
	-- knitr: ^[\t >]*```+\s*\{((([a-zA-Z0-9_]+)(.*)))\}\s*$
	local prefix, fence, braces = string.match(line, "^([\t >]*)(```+)%s*(%b{})%s*$")
	if not prefix or not braces then
		return nil, nil, nil
	end
	local header = string.sub(braces, 2, -2)
	if not string.match(header, "^[%w_]") then
		return nil, nil, nil
	end
	return prefix, fence, header
end

local function chunk_end(line: string): boolean
	return string.match(line, "^[\t >]*```+%s*$") ~= nil
end

function M.parse(text: string, seq: number?): Doc
	local doc: Doc = {
		cells = {},
		seq = seq or 0,
		crlf = string.find(text, "\r\n", 1, true) ~= nil,
		final_newline = text == "" or string.sub(text, -1) == "\n",
	}
	if doc.crlf then
		text = string.gsub(text, "\r\n", "\n")
	end
	if not doc.final_newline then
		text ..= "\n"
	end
	local lines: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n") do
		table.insert(lines, line)
	end

	local i = 1
	-- Front matter: a first line of `---` closed by `---` or `...`.
	if lines[1] and string.match(lines[1], "^%-%-%-%s*$") then
		for j = 2, #lines do
			if string.match(lines[j], "^%-%-%-%s*$") or string.match(lines[j], "^%.%.%.%s*$") then
				local c = cell(doc, "yaml")
				c.open = lines[1]
				c.close = lines[j]
				c.src = table.concat(lines, "\n", 2, j - 1)
				c.bare = j == 2
				table.insert(doc.cells, c)
				i = j + 1
				break
			end
		end
	end

	local md: { string } = {}
	local function flush_md()
		if #md > 0 then
			local c = cell(doc, "md")
			split_md(c, table.concat(md, "\n") .. "\n")
			table.insert(doc.cells, c)
			md = {}
		end
	end

	while i <= #lines do
		local line = lines[i]
		local prefix, fence, header = chunk_begin(line)
		local stop: number? = nil
		if prefix and fence and header then
			for j = i + 1, #lines do
				if chunk_end(lines[j]) then
					stop = j
					break
				end
			end
		end
		if prefix and fence and header and stop then
			flush_md()
			local c = cell(doc, "code")
			c.prefix, c.fence, c.header, c.open = prefix, fence, header, line
			c.close = lines[stop]
			c.src = table.concat(lines, "\n", i + 1, stop - 1)
			c.bare = stop == i + 1
			table.insert(doc.cells, c)
			i = stop + 1
		else
			table.insert(md, line)
			i += 1
		end
	end
	flush_md()
	return doc
end

local function block(text: string, bare: boolean): string
	if text == "" and bare then
		return ""
	end
	return text .. "\n"
end

function M.serialize(doc: Doc): string
	local out: { string } = {}
	local ends_nl = true
	for _, c in doc.cells do
		local piece: string
		if c.kind == "md" then
			piece = c.lead .. c.src .. c.trail
		elseif c.kind == "yaml" then
			piece = (c.open or "---") .. "\n" .. block(c.src, c.bare) .. c.close .. "\n"
		else
			piece = M.open_line(c) .. "\n" .. block(c.src, c.bare) .. c.close .. "\n"
		end
		-- A fence must start a line, even after Markdown edited to end mid-line.
		if c.kind ~= "md" and not ends_nl then
			table.insert(out, "\n")
		end
		if piece ~= "" then
			table.insert(out, piece)
			ends_nl = string.sub(piece, -1) == "\n"
		end
	end
	local text = table.concat(out)
	if not doc.final_newline and string.sub(text, -1) == "\n" then
		text = string.sub(text, 1, -2)
	end
	if doc.crlf then
		text = string.gsub(text, "\n", "\r\n")
	end
	return text
end

-- The chunk's opening fence line.
function M.open_line(c: Cell): string
	return c.open or (c.prefix .. c.fence .. "{" .. c.header .. "}")
end

-- Sets a chunk's header (the text inside the braces).
function M.set_header(c: Cell, header: string)
	if header ~= c.header then
		c.header = header
		c.open = nil
	end
end

-- The engine (`r`, `python`, …) and the rest of a chunk header: the label
-- and options, as knitr reads them after the engine name.
function M.engine(c: Cell): (string, string)
	local engine, rest = string.match(c.header, "^([%w_]+)%s*,?%s*(.*)$")
	return string.lower(engine or "r"), rest or ""
end

-- The chunk label, when the header names one (`r setup, echo=FALSE`).
function M.label(c: Cell): string?
	local _, rest = M.engine(c)
	local first = string.match(rest, "^([^,]*)")
	if first and first ~= "" and not string.find(first, "=", 1, true) then
		return (string.gsub(first, "^%s*(.-)%s*$", "%1"))
	end
	return nil
end

function M.new_code(doc: Doc, src: string?): Cell
	local c = cell(doc, "code")
	c.src = src or ""
	return c
end

function M.new_md(doc: Doc, src: string?): Cell
	local c = cell(doc, "md")
	c.src = src or ""
	c.lead = ""
	c.trail = "\n"
	return c
end

-- A blank line between two cells.
function M.new_spacer(doc: Doc): Cell
	local c = cell(doc, "md")
	c.lead = "\n"
	c.spacer = true
	return c
end

-- Turns a cell into another kind, keeping its text.
function M.convert(doc: Doc, c: Cell, kind: Kind)
	if c.kind == kind or kind == "yaml" or c.kind == "yaml" then
		return
	end
	c.kind = kind
	c.spacer = false
	if kind == "md" then
		c.lead, c.trail = "", "\n"
	else
		c.lead, c.trail = "", ""
		c.prefix, c.fence, c.header, c.open, c.close, c.bare = "", "```", "r", nil, "```", false
	end
end

-- Simple `key: value` lines of the front matter, for the header card.
function M.front(c: Cell): { [string]: string }
	local out: { [string]: string } = {}
	for line in string.gmatch(c.src .. "\n", "([^\n]*)\n") do
		local key, value = string.match(line, "^([%w_%-]+):%s*(.-)%s*$")
		if key and value and value ~= "" then
			out[key] = (string.gsub(value, "^[\"'](.*)[\"']$", "%1"))
		end
	end
	return out
end

return M
