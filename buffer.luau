--!strict
-- buffer.luau -- the text buffer behind one cell being edited.
--
-- Pure Luau: it never touches the tern API, so it also runs under the plain
-- `luau` CLI (see tests/buffer_test.luau).
--
-- The host keeps one Buf per cell, draws `text` in an `editor` node with
-- `cursor`/`anchor` (turned into the UTF-16 offsets the node wants by `utf16`)
-- and hands every key to `key()`; this module owns the editing itself.
--
-- `cursor` and `anchor` are BYTE offsets into `text` and always sit on a UTF-8
-- character boundary.
--
-- Every function that changes the text goes through `begin_edit`/`end_edit`,
-- which record one undo snapshot per step. Consecutive typed characters (that
-- don't start a new word after whitespace) and consecutive backspaces coalesce
-- into a single step; a caret move, an undo, or any other kind of edit starts a
-- new one.

export type Buf = {
	-- The whole cell text; newlines are "\n".
	text: string,
	-- Caret: byte offset into `text`, always on a character boundary.
	cursor: number,
	-- Selection anchor (byte offset). nil, or == cursor, means no selection.
	anchor: number?,
	-- Column (in codepoints) a run of vertical moves aims at.
	goal: number?,
	-- Private: undo/redo snapshots (oldest first) and the open undo group.
	_undo: { Snap }?,
	_redo: { Snap }?,
	_group: string?,
	_group_pos: number?,
}

-- One point in the edit history.
type Snap = { text: string, cursor: number, anchor: number? }

export type Opts = {
	lang: string?, -- "r" | "markdown" | "yaml" | nil
	indent: number?, -- spaces per indent level (default 2)
	autopair: boolean?, -- default: true for lang "r", false otherwise
}

-- A key press, the same shape as tern's Key type.
export type Key = {
	name: string,
	text: string?,
	ctrl: boolean,
	alt: boolean,
	shift: boolean,
	meta: boolean,
}

export type KeyResult = {
	handled: boolean, -- the buffer took the key (false: the caller must)
	changed: boolean, -- the text is not what it was
	copy: string?, -- text for the host to put on the clipboard
	edge: ("up" | "down")?, -- the key ran off the top/bottom line
}

-- How many undo steps to keep.
local MAX_HISTORY = 200

-- Shared results; callers must not mutate them.
local UNHANDLED: KeyResult = { handled = false, changed = false }
local HANDLED_STILL: KeyResult = { handled = true, changed = false }
local HANDLED_CHANGED: KeyResult = { handled = true, changed = true }
local EDGE_UP: KeyResult = { handled = false, changed = false, edge = "up" }
local EDGE_DOWN: KeyResult = { handled = false, changed = false, edge = "down" }

local BYTE_TAB = 9
local BYTE_SPACE = 32
local BYTE_HASH = 35 -- "#"

-- ---------------------------------------------------------------------------
-- UTF-8
-- ---------------------------------------------------------------------------

-- Bytes in the UTF-8 sequence that starts with byte `b`, clamped to `left`
-- bytes remaining. A stray continuation byte counts as one byte, so text that
-- is not valid UTF-8 can never make us walk off a boundary or raise.
local function seq_len(b: number, left: number): number
	if b < 0xC0 then
		return 1
	end
	local n = 1
	if b < 0xE0 then
		n = 2
	elseif b < 0xF0 then
		n = 3
	else
		n = 4
	end
	if n > left then
		return left
	end
	return n
end

-- Byte offset after the character that starts at `i`.
local function next_char(text: string, i: number): number
	if i >= #text then
		return #text
	end
	local n = seq_len(string.byte(text, i + 1) or 0, #text - i)
	local len = 1
	while len < n do
		local c = string.byte(text, i + 1 + len) or 0
		if c < 0x80 or c >= 0xC0 then
			break -- not a continuation byte: the sequence stops here
		end
		len += 1
	end
	return i + len
end

-- Byte offset where the character ending at `i` starts.
local function prev_char(text: string, i: number): number
	if i > #text then
		i = #text
	end
	local j = i
	while j > 0 do
		local c = string.byte(text, j) or 0
		if c < 0x80 or c >= 0xC0 then
			break -- a lead byte (or ASCII): the character starts here
		end
		j -= 1
	end
	if j <= 0 then
		return 0
	end
	return j - 1
end

-- The character starting at `i` ("" at the end of the text).
local function cp_at(text: string, i: number): string
	if i >= #text then
		return ""
	end
	return text:sub(i + 1, next_char(text, i))
end

-- The character ending at `i` ("" at the start of the text).
local function cp_before(text: string, i: number): string
	local p = prev_char(text, i)
	return text:sub(p + 1, i)
end

local function is_space(cp: string): boolean
	return cp ~= "" and string.match(cp, "^%s") ~= nil
end

-- A word character: ASCII letters, digits and "_". Anything non-ASCII counts as
-- a letter, so words survive accented text and runs of emoji.
local function is_word(cp: string): boolean
	if cp == "" then
		return false
	end
	if #cp > 1 then
		return true
	end
	return string.match(cp, "^[%w_]") ~= nil
end

local function is_indent_cp(cp: string): boolean
	return cp == " " or cp == "\t"
end

-- Is `s` exactly one character?
local function is_single_char(s: string): boolean
	return s ~= "" and next_char(s, 0) == #s
end

-- Move `i` back onto a character boundary (a no-op for a valid offset).
local function snap_down(text: string, i: number): number
	if i > #text then
		i = #text
	end
	while i > 0 do
		local c = string.byte(text, i + 1) or 0
		if c < 0x80 or c >= 0xC0 then
			break
		end
		i -= 1
	end
	return i
end

-- Codepoints between two byte offsets (from <= to).
local function cp_count(text: string, from: number, to: number): number
	local n = 0
	local i = from
	while i < to do
		i = next_char(text, i)
		n += 1
	end
	return n
end

-- ---------------------------------------------------------------------------
-- Lines
-- ---------------------------------------------------------------------------

-- Start of the line holding byte offset `i`: a "\n" at 1-based index p starts
-- the line at offset p.
local function line_start_at(text: string, i: number): number
	local p = 0
	while true do
		local q = string.find(text, "\n", p + 1, true)
		if q == nil or q > i then
			return p
		end
		p = q
	end
end

-- Offset of the line's end: the newline itself, or #text on the last line.
local function line_end_at(text: string, i: number): number
	local q = string.find(text, "\n", i + 1, true)
	if q == nil then
		return #text
	end
	return q - 1
end

-- 1-based line number of byte offset `i`.
local function line_number(text: string, i: number): number
	local n = 1
	local p = 0
	while true do
		local q = string.find(text, "\n", p + 1, true)
		if q == nil or q > i then
			return n
		end
		n += 1
		p = q
	end
end

-- Bytes of leading spaces and tabs on the line that starts at `st`.
local function leading_indent(text: string, st: number): number
	local le = line_end_at(text, st)
	local i = st
	while i < le do
		local c = string.byte(text, i + 1) or 0
		if c ~= BYTE_SPACE and c ~= BYTE_TAB then
			break
		end
		i += 1
	end
	return i - st
end

-- Backwards over the whitespace, then over one run of word characters or one
-- run of punctuation (what ctrl/alt+backspace and ctrl/alt+left want).
local function word_left(text: string, i: number): number
	local j = i
	while j > 0 and is_space(cp_before(text, j)) do
		j = prev_char(text, j)
	end
	if j == 0 then
		return 0
	end
	local word = is_word(cp_before(text, j))
	while j > 0 do
		local cp = cp_before(text, j)
		if is_space(cp) or is_word(cp) ~= word then
			break
		end
		j = prev_char(text, j)
	end
	return j
end

-- Forwards, the same way.
local function word_right(text: string, i: number): number
	local j = i
	while j < #text and is_space(cp_at(text, j)) do
		j = next_char(text, j)
	end
	if j >= #text then
		return #text
	end
	local word = is_word(cp_at(text, j))
	while j < #text do
		local cp = cp_at(text, j)
		if is_space(cp) or is_word(cp) ~= word then
			break
		end
		j = next_char(text, j)
	end
	return j
end

-- Byte offset `col` codepoints into the line starting at `ls`, clamped to that
-- line's end (where a vertical move aims).
local function pos_at_column(text: string, ls: number, col: number): number
	local le = line_end_at(text, ls)
	local i = ls
	local n = 0
	while n < col and i < le do
		i = next_char(text, i)
		n += 1
	end
	return i
end

-- Starts of the lines the range [from, to] touches. A range that ends exactly
-- at the start of a line does not touch that line: selecting whole lines plus
-- the trailing newline leaves the following line alone.
local function touched_lines(text: string, from: number, to: number): { number }
	local stop = to
	if to > from and line_start_at(text, to) == to then
		stop = to - 1
	end
	local last = line_start_at(text, stop)
	local starts: { number } = {}
	local i = line_start_at(text, from)
	while true do
		table.insert(starts, i)
		if i >= last then
			return starts
		end
		local le = line_end_at(text, i)
		if le >= #text then
			return starts
		end
		i = le + 1
	end
end

-- ---------------------------------------------------------------------------
-- Pairs
-- ---------------------------------------------------------------------------

-- The closer for a character that pairs up, or nil.
local function pair_for(cp: string): string?
	if cp == "(" then
		return ")"
	end
	if cp == "[" then
		return "]"
	end
	if cp == "{" then
		return "}"
	end
	if cp == "\"" or cp == "'" or cp == "`" then
		return cp
	end
	return nil
end

-- An empty pair: the caret sits between the two halves.
local function is_pair(open: string, close: string): boolean
	local c = pair_for(open)
	return c ~= nil and c == close
end

local function is_closer(cp: string): boolean
	return #cp == 1 and string.find(")]}", cp, 1, true) ~= nil
end

local function is_quote(cp: string): boolean
	return #cp == 1 and string.find("\"'`", cp, 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

local function snapshot(b: Buf): Snap
	return { text = b.text, cursor = b.cursor, anchor = b.anchor }
end

-- A Buf built by hand (a cell restored from a save) may lack the private
-- tables; both are created on first use.
local function hist(b: Buf): { Snap }
	local u: { Snap } = b._undo or {}
	b._undo = u
	return u
end

local function redo_hist(b: Buf): { Snap }
	local r: { Snap } = b._redo or {}
	b._redo = r
	return r
end

-- Open an undo step for an edit that is about to happen. Naming the group the
-- previous edit opened -- with the caret still where it left it -- coalesces
-- into that step instead (its snapshot stays). Every edit drops the redo stack.
local function begin_edit(b: Buf, group: string?): ()
	if group ~= nil and b._group == group and b._group_pos == b.cursor then
		return
	else
		local u = hist(b)
		table.insert(u, snapshot(b))
		if #u > MAX_HISTORY then
			table.remove(u, 1)
		end
		b._group = group
	end
	local r = b._redo
	if r ~= nil and #r > 0 then
		b._redo = {}
	end
end

-- Remember where the next edit has to happen for the open group to continue.
local function end_edit(b: Buf): ()
	b._group_pos = if b._group ~= nil then b.cursor else nil
end

-- Close the undo group: the next edit opens its own step.
local function close_group(b: Buf): ()
	b._group = nil
	b._group_pos = nil
end

local function apply_snapshot(b: Buf, s: Snap): ()
	b.text = s.text
	b.cursor = s.cursor
	b.anchor = s.anchor
	b.goal = nil
	close_group(b)
end

local function undo_impl(b: Buf): boolean
	local u = b._undo
	if u == nil or #u == 0 then
		return false
	end
	local r = redo_hist(b)
	table.insert(r, snapshot(b))
	if #r > MAX_HISTORY then
		table.remove(r, 1)
	end
	local s = table.remove(u)
	if s ~= nil then
		apply_snapshot(b, s)
	end
	return true
end

local function redo_impl(b: Buf): boolean
	local r = b._redo
	if r == nil or #r == 0 then
		return false
	end
	local u = hist(b)
	table.insert(u, snapshot(b))
	if #u > MAX_HISTORY then
		table.remove(u, 1)
	end
	local s = table.remove(r)
	if s ~= nil then
		apply_snapshot(b, s)
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Editing primitives
-- ---------------------------------------------------------------------------

-- The ordered byte range of the selection, or nil, nil.
local function sel(b: Buf): (number?, number?)
	local a = b.anchor
	local c = b.cursor
	if a == nil or a == c then
		return nil, nil
	end
	if a < c then
		return a, c
	end
	return c, a
end

-- The lines an edit key works on: every line the selection touches, or just the
-- caret's line when there is no selection.
local function edit_lines(b: Buf): { number }
	local s, e = sel(b)
	if s ~= nil and e ~= nil then
		return touched_lines(b.text, s, e)
	end
	return { line_start_at(b.text, b.cursor) }
end

-- Replace the byte range [from, to) with `s`.
local function splice(b: Buf, from: number, to: number, s: string): ()
	b.text = b.text:sub(1, from) .. s .. b.text:sub(to + 1)
end

-- Insert `s` at the caret, replacing the selection; the caret lands after it.
-- `group` is the undo group this may coalesce with (nil: its own step).
-- Returns whether the text itself changed: a selection replaced by the very
-- same text leaves the text as it was (only the selection goes).
local function insert_impl(b: Buf, s: string, group: string?): boolean
	local from = b.cursor
	local to = b.cursor
	local fs, fe = sel(b)
	if fs ~= nil and fe ~= nil then
		from = fs
		to = fe
	end
	local same = to > from and to - from == #s and b.text:sub(from + 1, to) == s
	begin_edit(b, group)
	splice(b, from, to, s)
	b.cursor = from + #s
	b.anchor = nil
	b.goal = nil
	end_edit(b)
	return not same
end

-- Insert `s` and wrap the outcome as a key result.
local function insert_result(b: Buf, s: string, group: string?): KeyResult
	if insert_impl(b, s, group) then
		return HANDLED_CHANGED
	end
	return HANDLED_STILL
end

-- The undo group a typed character joins: one character continues the group the
-- previous one opened unless it starts a new word, i.e. unless the character
-- before the caret is whitespace. A longer insert, and one that replaces a
-- selection, always opens its own step. The start of the text is not whitespace,
-- so the first character typed into a buffer opens exactly one group, which the
-- characters after it join.
local function insert_group(b: Buf, s: string): string?
	if not is_single_char(s) or sel(b) ~= nil then
		return nil
	end
	if b.cursor > 0 and is_space(cp_before(b.text, b.cursor)) then
		return nil
	end
	return "insert"
end

-- Move the caret, dropping the selection unless `extend` (which keeps the
-- anchor, setting it first if there was none).
local function move_caret(b: Buf, target: number, extend: boolean): ()
	if target < 0 then
		target = 0
	elseif target > #b.text then
		target = #b.text
	end
	if extend then
		if b.anchor == nil then
			b.anchor = b.cursor
		end
		b.cursor = target
	else
		b.anchor = nil
		b.cursor = target
	end
	b.goal = nil
	close_group(b)
end

-- Insert `pad` at every offset in `at` (ascending), keeping the caret and the
-- selection over the same text.
local function insert_many(b: Buf, at: { number }, pad: string): ()
	local parts: { string } = {}
	local prev = 0
	for _, p in ipairs(at) do
		table.insert(parts, b.text:sub(prev + 1, p))
		table.insert(parts, pad)
		prev = p
	end
	table.insert(parts, b.text:sub(prev + 1))
	b.text = table.concat(parts)
	local size = #pad
	local function map(p: number): number
		local add = 0
		for _, q in ipairs(at) do
			if q <= p then
				add += size
			else
				break
			end
		end
		return p + add
	end
	b.cursor = map(b.cursor)
	if b.anchor ~= nil then
		b.anchor = map(b.anchor)
	end
end

-- Remove `lens[i]` bytes at `at[i]` (ascending, non-overlapping), keeping the
-- caret and the selection over the same text; an offset inside a removed run
-- clamps to that run's start.
local function remove_many(b: Buf, at: { number }, lens: { number }): ()
	local parts: { string } = {}
	local prev = 0
	for i, p in ipairs(at) do
		local n = lens[i]
		if n > 0 then
			table.insert(parts, b.text:sub(prev + 1, p))
			prev = p + n
		end
	end
	table.insert(parts, b.text:sub(prev + 1))
	b.text = table.concat(parts)
	local function map(p: number): number
		local shift = 0
		for i = 1, #at do
			local q = at[i]
			local n = lens[i]
			if n == 0 then
				continue
			end
			if p >= q + n then
				shift += n
			elseif p > q then
				return q - shift
			else
				break
			end
		end
		return p - shift
	end
	b.cursor = map(b.cursor)
	if b.anchor ~= nil then
		b.anchor = map(b.anchor)
	end
end

-- Leading spaces (up to `indent`) of each line that starts at `starts[i]`.
local function outdent_lens(text: string, starts: { number }, indent: number): { number }
	local lens: { number } = {}
	for i, st in ipairs(starts) do
		local n = 0
		while n < indent and string.byte(text, st + n + 1) == BYTE_SPACE do
			n += 1
		end
		lens[i] = n
	end
	return lens
end

-- What ctrl+c copies: the selection, or the caret's line including its newline.
local function copy_text(b: Buf): string
	local s, e = sel(b)
	if s ~= nil and e ~= nil then
		return b.text:sub(s + 1, e)
	end
	local ls = line_start_at(b.text, b.cursor)
	local le = line_end_at(b.text, b.cursor)
	return b.text:sub(ls + 1, le) .. "\n"
end

-- ---------------------------------------------------------------------------
-- Keys
-- ---------------------------------------------------------------------------

local function enter_key(b: Buf, indent: number): KeyResult
	local before = b.text
	begin_edit(b, nil)
	local c = b.cursor
	local s, e = sel(b)
	if s ~= nil and e ~= nil then
		splice(b, s, e, "")
		c = s
	end
	local text = b.text
	local ls = line_start_at(text, c)
	local le = line_end_at(text, ls)
	local lead_end = ls
	while lead_end < le and is_indent_cp(cp_at(text, lead_end)) do
		lead_end = next_char(text, lead_end)
	end
	local lead = text:sub(ls + 1, lead_end)
	local opener = cp_before(text, c)
	local closer = cp_at(text, c)
	local close = ""
	if opener == "(" then
		close = ")"
	elseif opener == "[" then
		close = "]"
	elseif opener == "{" then
		close = "}"
	end
	local middle = lead
	if close ~= "" then
		middle = lead .. string.rep(" ", indent)
	end
	local tail = ""
	if close ~= "" and closer == close then
		-- the closer moves to its own line, back at the original indent
		tail = "\n" .. lead
	end
	splice(b, c, c, "\n" .. middle .. tail)
	b.cursor = c + 1 + #middle
	b.anchor = nil
	b.goal = nil
	end_edit(b)
	if b.text ~= before then
		return HANDLED_CHANGED
	end
	return HANDLED_STILL
end

local function tab_key(b: Buf, indent: number, shift: boolean): KeyResult
	local text = b.text
	if not shift then
		if sel(b) == nil then
			-- no selection: spaces up to the next indent stop
			local ls = line_start_at(text, b.cursor)
			local step = indent - cp_count(text, ls, b.cursor) % indent
			return insert_result(b, string.rep(" ", step), nil)
		end
		-- a selection indents every line it touches, and stays over them
		local starts = edit_lines(b)
		begin_edit(b, nil)
		insert_many(b, starts, string.rep(" ", indent))
		end_edit(b)
		return HANDLED_CHANGED
	end
	local starts = edit_lines(b)
	local lens = outdent_lens(text, starts, indent)
	local total = 0
	for _, n in ipairs(lens) do
		total += n
	end
	if total == 0 then
		return HANDLED_STILL
	end
	begin_edit(b, nil)
	remove_many(b, starts, lens)
	end_edit(b)
	return HANDLED_CHANGED
end

local function backspace_key(b: Buf, indent: number): KeyResult
	local text = b.text
	local c = b.cursor
	local s, e = sel(b)
	if s ~= nil and e ~= nil then
		begin_edit(b, nil)
		splice(b, s, e, "")
		b.cursor = s
		b.anchor = nil
		b.goal = nil
		end_edit(b)
		return HANDLED_CHANGED
	end
	if c == 0 then
		return HANDLED_STILL
	end
	-- inside the line's leading whitespace (spaces only): back to the previous
	-- indent stop
	local ls = line_start_at(text, c)
	local only_spaces = c > ls
	local i = ls
	while only_spaces and i < c do
		if string.byte(text, i + 1) ~= BYTE_SPACE then
			only_spaces = false
			break
		end
		i += 1
	end
	if only_spaces then
		local col = c - ls
		local stop = ls + (col - 1) // indent * indent
		begin_edit(b, "backspace")
		splice(b, stop, c, "")
		b.cursor = stop
		b.anchor = nil
		b.goal = nil
		end_edit(b)
		return HANDLED_CHANGED
	end
	-- between the two halves of an empty pair: take both
	local before = cp_before(text, c)
	local after = cp_at(text, c)
	if is_pair(before, after) then
		begin_edit(b, "backspace")
		splice(b, c - #before, c + #after, "")
		b.cursor = c - #before
		b.anchor = nil
		b.goal = nil
		end_edit(b)
		return HANDLED_CHANGED
	end
	local p = prev_char(text, c)
	begin_edit(b, "backspace")
	splice(b, p, c, "")
	b.cursor = p
	b.anchor = nil
	b.goal = nil
	end_edit(b)
	return HANDLED_CHANGED
end

local function delete_key(b: Buf): KeyResult
	local s, e = sel(b)
	if s ~= nil and e ~= nil then
		begin_edit(b, nil)
		splice(b, s, e, "")
		b.cursor = s
		b.anchor = nil
		b.goal = nil
		end_edit(b)
		return HANDLED_CHANGED
	end
	if b.cursor >= #b.text then
		return HANDLED_STILL
	end
	local n = next_char(b.text, b.cursor)
	begin_edit(b, nil)
	splice(b, b.cursor, n, "")
	b.anchor = nil
	b.goal = nil
	end_edit(b)
	return HANDLED_CHANGED
end

local function delete_word_key(b: Buf, forward: boolean): KeyResult
	local text = b.text
	local s, e = sel(b)
	if s ~= nil and e ~= nil then
		begin_edit(b, nil)
		splice(b, s, e, "")
		b.cursor = s
		b.anchor = nil
		b.goal = nil
		end_edit(b)
		return HANDLED_CHANGED
	end
	local from = b.cursor
	local to = b.cursor
	if forward then
		to = word_right(text, from)
	else
		from = word_left(text, from)
	end
	if from == to then
		return HANDLED_STILL
	end
	begin_edit(b, nil)
	splice(b, from, to, "")
	b.cursor = from
	b.anchor = nil
	b.goal = nil
	end_edit(b)
	return HANDLED_CHANGED
end

local function move_key(b: Buf, right: boolean, by_word: boolean, extend: boolean): KeyResult
	local text = b.text
	if not extend then
		local cs, ce = sel(b)
		if cs ~= nil and ce ~= nil then
			-- a move with a selection collapses it instead of moving further
			local target = cs
			if right then
				target = ce
			end
			move_caret(b, target, false)
			return HANDLED_STILL
		end
	end
	local target = b.cursor
	if right then
		if by_word then
			target = word_right(text, target)
		else
			target = next_char(text, target)
		end
	elseif by_word then
		target = word_left(text, target)
	else
		target = prev_char(text, target)
	end
	move_caret(b, target, extend)
	return HANDLED_STILL
end

local function line_move(b: Buf, down: boolean, extend: boolean): KeyResult
	local text = b.text
	local ls = line_start_at(text, b.cursor)
	local goal = b.goal or cp_count(text, ls, b.cursor)
	if not down then
		if ls == 0 then
			-- already on the first line: the caller moves to the cell above
			if extend then
				move_caret(b, 0, true)
				return HANDLED_STILL
			end
			b.goal = nil
			return EDGE_UP
		end
		local target = line_start_at(text, ls - 1)
		move_caret(b, pos_at_column(text, target, goal), extend)
		b.goal = goal -- remembered across the run of vertical moves
		return HANDLED_STILL
	end
	local le = line_end_at(text, ls)
	if le >= #text then
		-- already on the last line: the caller moves to the cell below
		if extend then
			move_caret(b, #text, true)
			return HANDLED_STILL
		end
		b.goal = nil
		return EDGE_DOWN
	end
	move_caret(b, pos_at_column(text, le + 1, goal), extend)
	b.goal = goal
	return HANDLED_STILL
end

local function home_key(b: Buf, shift: boolean): KeyResult
	local text = b.text
	local ls = line_start_at(text, b.cursor)
	local le = line_end_at(text, ls)
	local target = ls
	while target < le and is_indent_cp(cp_at(text, target)) do
		target = next_char(text, target)
	end
	if b.cursor == target then
		target = ls -- already at the first non-blank: to column 0
	end
	move_caret(b, target, shift)
	return HANDLED_STILL
end

local function end_key(b: Buf, shift: boolean): KeyResult
	move_caret(b, line_end_at(b.text, b.cursor), shift)
	return HANDLED_STILL
end

-- The typed character `s` when autopair is on. Returns nil for a character
-- that pairs with nothing, so the caller inserts it plainly.
local function autopair_key(b: Buf, s: string): KeyResult?
	local from, to = sel(b)
	if from ~= nil and to ~= nil then
		-- an opener (or quote) wraps the selection
		local close = pair_for(s)
		if close == nil then
			return nil
		end
		begin_edit(b, nil)
		splice(b, from, to, s .. b.text:sub(from + 1, to) .. close)
		b.cursor = to + #s + #close
		b.anchor = nil
		b.goal = nil
		end_edit(b)
		return HANDLED_CHANGED
	end
	if is_closer(s) or is_quote(s) then
		if cp_at(b.text, b.cursor) == s then
			-- the pair is already there: step over the closer instead of
			-- doubling it
			move_caret(b, next_char(b.text, b.cursor), false)
			return HANDLED_STILL
		end
	end
	local close = pair_for(s)
	if close == nil then
		return nil
	end
	local next_cp = cp_at(b.text, b.cursor)
	if next_cp ~= "" and not is_space(next_cp) and not is_closer(next_cp) then
		return nil -- something is in the way
	end
	if is_quote(s) and is_word(cp_before(b.text, b.cursor)) then
		return nil -- a quote right after a word is an apostrophe, not a pair
	end
	local changed = insert_impl(b, s .. close, nil)
	b.cursor -= #close -- leave the caret between the two
	if changed then
		return HANDLED_CHANGED
	end
	return HANDLED_STILL
end

local function comment_key(b: Buf): KeyResult
	local text = b.text
	local starts = edit_lines(b)
	local min_indent: number? = nil
	local any_uncommented = false
	for _, st in ipairs(starts) do
		local le = line_end_at(text, st)
		local ind = leading_indent(text, st)
		if st + ind < le then -- not a blank line
			if string.byte(text, st + ind + 1) ~= BYTE_HASH then
				any_uncommented = true
			end
			if min_indent == nil or ind < min_indent then
				min_indent = ind
			end
		end
	end
	if min_indent == nil then
		return HANDLED_STILL -- nothing but blank lines
	end
	local at: { number } = {}
	local lens: { number } = {}
	if any_uncommented then
		-- comment every non-blank line, after the shallowest indentation
		local column = min_indent
		for _, st in ipairs(starts) do
			local le = line_end_at(text, st)
			local ind = leading_indent(text, st)
			if st + ind < le then
				table.insert(at, st + column)
			end
		end
		begin_edit(b, nil)
		insert_many(b, at, "# ")
	else
		-- every non-blank line is commented: take the "# " (or "#") off each
		for _, st in ipairs(starts) do
			local le = line_end_at(text, st)
			local body = st + leading_indent(text, st)
			if body < le and string.byte(text, body + 1) == BYTE_HASH then
				local n = 1
				if string.byte(text, body + 2) == BYTE_SPACE then
					n = 2
				end
				table.insert(at, body)
				table.insert(lens, n)
			end
		end
		begin_edit(b, nil)
		remove_many(b, at, lens)
	end
	end_edit(b)
	return HANDLED_CHANGED
end

local function cut_key(b: Buf): KeyResult
	local copied = copy_text(b)
	local s, e = sel(b)
	local from = b.cursor
	local to = b.cursor
	if s ~= nil and e ~= nil then
		from = s
		to = e
	else
		local text = b.text
		from = line_start_at(text, b.cursor)
		to = line_end_at(text, b.cursor)
		if to < #text then
			to += 1 -- take the newline with it
		end
	end
	if from >= to then
		-- an empty last line: nothing to take away
		return { handled = true, changed = false, copy = copied }
	end
	begin_edit(b, nil)
	splice(b, from, to, "")
	b.cursor = from
	if b.cursor > #b.text then
		b.cursor = #b.text
	end
	b.anchor = nil
	b.goal = nil
	end_edit(b)
	return { handled = true, changed = true, copy = copied }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local M = {}

-- A buffer over `text`; the caret starts at the end unless told otherwise.
function M.new(text: string, cursor: number?): Buf
	local c = cursor or #text
	if c < 0 then
		c = 0
	elseif c > #text then
		c = #text
	end
	c = snap_down(text, c)
	return { text = text, cursor = c, _undo = {}, _redo = {} }
end

-- Insert `s` at the caret (replacing the selection); undoable.
function M.insert(b: Buf, s: string): ()
	if s == "" and sel(b) == nil then
		return
	end
	insert_impl(b, s, insert_group(b, s))
end

-- Replace the byte range [from, to) with `s`; the caret lands after it, the
-- selection goes, and one undo step covers it (completions use this).
function M.replace(b: Buf, from: number, to: number, s: string): ()
	local text = b.text
	if from > to then
		from, to = to, from
	end
	if from < 0 then
		from = 0
	elseif from > #text then
		from = #text
	end
	if to < 0 then
		to = 0
	elseif to > #text then
		to = #text
	end
	from = snap_down(text, from)
	to = snap_down(text, to)
	if to < from then
		to = from
	end
	begin_edit(b, nil)
	splice(b, from, to, s)
	b.cursor = from + #s
	b.anchor = nil
	b.goal = nil
	end_edit(b)
end

-- The ordered byte range of the selection, or nil, nil when there is none.
function M.selection(b: Buf): (number?, number?)
	return sel(b)
end

-- The caret's line (1-based) and column (0-based, in codepoints).
function M.line_col(b: Buf): (number, number)
	local text = b.text
	local ls = line_start_at(text, b.cursor)
	return line_number(text, b.cursor), cp_count(text, ls, b.cursor)
end

-- The current line's text from its start up to the caret.
function M.line_prefix(b: Buf): string
	local text = b.text
	return text:sub(line_start_at(text, b.cursor) + 1, b.cursor)
end

-- How many lines `text` has; empty text is one line, "a\n" is two.
function M.line_count(text: string): number
	local n = 1
	local p = 0
	while true do
		local q = string.find(text, "\n", p + 1, true)
		if q == nil then
			return n
		end
		n += 1
		p = q
	end
end

-- UTF-16 code units in text:sub(1, byte); a character above U+FFFF counts 2.
function M.utf16(text: string, byte: number): number
	if byte > #text then
		byte = #text
	end
	local n = 0
	local i = 0
	while i < byte do
		local j = next_char(text, i)
		if j - i == 4 then
			n += 2
		else
			n += 1
		end
		i = j
	end
	return n
end

-- Step back through the edit history; false when there is nothing to undo.
-- Caret and selection come back with the text.
function M.undo(b: Buf): boolean
	return undo_impl(b)
end

-- Step forward again through the edit history; false when there is nothing.
function M.redo(b: Buf): boolean
	return redo_impl(b)
end

-- Handle one key press. `opts` says what kind of cell this is: R cells indent
-- by two and pair brackets by default, markdown cells do neither. Every key the
-- buffer doesn't own comes back as `handled = false` with nothing touched.
function M.key(b: Buf, key: Key, opts: Opts?): KeyResult
	local lang: string? = nil
	local indent = 2
	local autopair = false
	if opts ~= nil then
		lang = opts.lang
		if opts.indent ~= nil then
			indent = opts.indent
		end
		if opts.autopair ~= nil then
			autopair = opts.autopair
		else
			autopair = lang == "r"
		end
	end
	if indent < 1 then
		indent = 1
	end
	local name = key.name
	local ctrl = key.ctrl or key.meta -- Cmd on macOS reaches us as meta
	local shift = key.shift
	local alt = key.alt

	-- A paste is one key carrying the text: no autopair, CRLF normalised.
	if name == "paste" then
		local pasted = key.text
		if pasted == nil or pasted == "" then
			return HANDLED_STILL
		end
		local s = pasted:gsub("\r\n", "\n"):gsub("\r", "\n")
		return insert_result(b, s, nil)
	end
	-- Keys the block's caller owns.
	if name == "escape" or name == "page_up" or name == "page_down" or string.match(name, "^f%d+$") ~= nil then
		return UNHANDLED
	end
	if ctrl or alt then
		if ctrl and name == "a" and not shift then
			b.anchor = 0
			b.cursor = #b.text
			b.goal = nil
			close_group(b)
			return HANDLED_STILL
		elseif ctrl and name == "c" and shift and lang == "r" then
			return comment_key(b)
		elseif ctrl and name == "c" and not shift then
			return { handled = true, changed = false, copy = copy_text(b) }
		elseif ctrl and name == "x" and not shift then
			return cut_key(b)
		elseif ctrl and name == "z" and shift then
			if redo_impl(b) then
				return HANDLED_CHANGED
			end
			return HANDLED_STILL
		elseif ctrl and name == "z" then
			if undo_impl(b) then
				return HANDLED_CHANGED
			end
			return HANDLED_STILL
		elseif ctrl and name == "y" then
			if redo_impl(b) then
				return HANDLED_CHANGED
			end
			return HANDLED_STILL
		elseif ctrl and name == "/" and lang == "r" then
			return comment_key(b)
		elseif ctrl and name == "m" and shift and lang == "r" then
			return insert_result(b, " |> ", nil)
		elseif (ctrl or alt) and name == "backspace" then
			return delete_word_key(b, false)
		elseif (ctrl or alt) and name == "delete" then
			return delete_word_key(b, true)
		elseif (ctrl or alt) and name == "left" then
			return move_key(b, false, true, shift)
		elseif (ctrl or alt) and name == "right" then
			return move_key(b, true, true, shift)
		elseif ctrl and name == "home" then
			move_caret(b, 0, shift)
			return HANDLED_STILL
		elseif ctrl and name == "end" then
			move_caret(b, #b.text, shift)
			return HANDLED_STILL
		elseif alt and not ctrl and name == "-" and lang == "r" then
			-- alt+- types "<-", with no extra space after one already there
			local insert = " <- "
			local fs = sel(b)
			if fs == nil and cp_before(b.text, b.cursor) == " " then
				insert = "<- "
			end
			return insert_result(b, insert, nil)
		end
		return UNHANDLED
	end
	-- Plain keys.
	if name == "enter" then
		if shift then
			return UNHANDLED -- shift+enter is the caller's
		end
		return enter_key(b, indent)
	elseif name == "tab" then
		return tab_key(b, indent, shift)
	elseif name == "backspace" then
		return backspace_key(b, indent)
	elseif name == "delete" then
		return delete_key(b)
	elseif name == "left" then
		return move_key(b, false, false, shift)
	elseif name == "right" then
		return move_key(b, true, false, shift)
	elseif name == "up" then
		return line_move(b, false, shift)
	elseif name == "down" then
		return line_move(b, true, shift)
	elseif name == "home" then
		return home_key(b, shift)
	elseif name == "end" then
		return end_key(b, shift)
	end
	local typed = key.text
	if typed == nil and name == "space" then
		typed = " " -- a host that leaves `text` off the space key
	end
	if typed ~= nil and typed ~= "" then
		if autopair then
			local paired = autopair_key(b, typed)
			if paired ~= nil then
				return paired
			end
		end
		return insert_result(b, typed, insert_group(b, typed))
	end
	return UNHANDLED
end

return M
