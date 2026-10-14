-- Tests for ../buffer.luau. Run from the plugin directory:
--   /tmp/ternsdk/bin/luau tests/buffer_test.luau
-- Plain asserts: the first failure aborts with a message and a stack trace.

local B = require("../buffer")

local checked = 0
local current = "?"

local function ok(cond: any, msg: string?)
	checked += 1
	if not cond then
		error(("FAIL [%s] %s"):format(current, msg or ""), 2)
	end
end

local function eq(got: any, want: any, msg: string?)
	checked += 1
	if got ~= want then
		error(("FAIL [%s] %s\n  got:  %s\n  want: %s"):format(current, msg or "", tostring(got), tostring(want)), 2)
	end
end

-- A key press as the host delivers it.
local function key(name: string, mods: any?): any
	mods = mods or {}
	return {
		name = name,
		text = mods.text,
		ctrl = mods.ctrl == true,
		alt = mods.alt == true,
		shift = mods.shift == true,
		meta = mods.meta == true,
	}
end

local function press(b: any, name: string, mods: any?, opts: any?): any
	return B.key(b, key(name, mods), opts)
end

-- Type `s` one character at a time, the way the host delivers typing.
local function typ(b: any, s: string, opts: any?)
	for _, c in utf8.codes(s) do
		local ch = utf8.char(c)
		if ch == " " then
			press(b, "space", { text = " " }, opts)
		elseif ch == "\n" then
			press(b, "enter", nil, opts)
		else
			press(b, ch, { text = ch }, opts)
		end
	end
end

local R = { lang = "r" }

-- ---------------------------------------------------------------------------

local function test_utf8_helpers()
	current = "utf8 helpers"
	local t = "aé😀b" -- 1 + 2 + 4 + 1 bytes
	eq(#t, 8, "byte length")
	eq(B.utf16(t, 0), 0, "utf16 at the start")
	eq(B.utf16(t, 1), 1, "utf16 after a")
	eq(B.utf16(t, 3), 2, "utf16 after é (one unit)")
	eq(B.utf16(t, 7), 4, "utf16 after 😀 (two units)")
	eq(B.utf16(t, 8), 5, "utf16 at the end")
	eq(B.line_count(""), 1, "empty text is one line")
	eq(B.line_count("a"), 1, "one line")
	eq(B.line_count("a\n"), 2, "a trailing newline opens a line")
	eq(B.line_count("a\nb\nc"), 3, "three lines")
end

local function test_utf8_editing()
	current = "utf8 editing"
	local b = B.new("aé😀b")
	eq(b.cursor, 8, "new() starts at the end")
	press(b, "left")
	eq(b.cursor, 7, "left over b")
	press(b, "left")
	eq(b.cursor, 3, "left over 😀 in one step")
	press(b, "left")
	eq(b.cursor, 1, "left over é in one step")
	press(b, "right")
	eq(b.cursor, 3, "right over é")
	press(b, "right")
	eq(b.cursor, 7, "right over 😀")
	eq(b.text, "aé😀b", "moving never changes the text")

	b = B.new("aé😀b", 7)
	press(b, "backspace")
	eq(b.text, "aéb", "backspace eats all of 😀")
	eq(b.cursor, 3, "caret on the boundary")
	press(b, "backspace")
	eq(b.text, "ab", "backspace eats é")
	eq(b.cursor, 1)

	b = B.new("aé😀b", 1)
	press(b, "delete")
	eq(b.text, "a😀b", "delete eats é")
	eq(b.cursor, 1)
	press(b, "right")
	eq(b.cursor, 5, "right over 😀 after the delete")
	press(b, "delete")
	eq(b.text, "a😀", "delete eats b")

	-- an offset inside a character snaps back to its start
	b = B.new("aé😀b", 2)
	eq(b.cursor, 1, "new() snaps to a character boundary")
	b = B.new("aé😀b", -5)
	eq(b.cursor, 0, "negative cursors clamp")
	b = B.new("aé😀b", 99)
	eq(b.cursor, 8, "cursors past the end clamp")

	-- columns and prefixes count codepoints
	b = B.new("aé😀b", 3)
	local line, col = B.line_col(b)
	eq(line, 1, "line 1")
	eq(col, 2, "é😀| is column 2")
	eq(B.line_prefix(b), "aé", "line_prefix")
	eq(B.line_prefix(B.new("ab\ncd", 3)), "", "prefix at a line start")
	b = B.new("ab\ncdé", 7)
	line, col = B.line_col(b)
	eq(line, 2, "line number")
	eq(col, 3, "column on the second line")
	eq(B.line_prefix(b), "cdé", "prefix on the second line")
end

local function test_enter()
	current = "enter"
	-- the new line keeps the indentation
	local b = B.new("  foo bar", 9)
	press(b, "enter")
	eq(b.text, "  foo bar\n  ", "newline plus the leading whitespace")
	eq(b.cursor, 12, "caret on the new line")

	-- inside a pair: the middle line is indented and the closer keeps its place
	b = B.new("  {}", 3)
	press(b, "enter")
	eq(b.text, "  {\n    \n  }", "brace pair split apart")
	eq(b.cursor, 8, "caret on the indented middle line")

	b = B.new("f()", 2)
	press(b, "enter")
	eq(b.text, "f(\n  \n)", "paren pair split apart")
	eq(b.cursor, 5, "caret on the middle line")

	-- an opener alone only adds the deeper indent
	b = B.new("  {", 3)
	press(b, "enter")
	eq(b.text, "  {\n    ", "opener alone")
	eq(b.cursor, 8)

	-- a closer that does not match the opener stays put
	b = B.new("x[}", 2)
	press(b, "enter")
	eq(b.text, "x[\n  }", "mismatched closer not moved")

	-- a selection is replaced by the newline
	b = B.new("  abcd", 4)
	b.anchor = 2
	press(b, "enter")
	eq(b.text, "  \n  cd", "selection replaced")
	eq(b.cursor, 5)

	-- shift/ctrl+enter belong to the caller
	b = B.new("ab", 1)
	local r = press(b, "enter", { shift = true })
	eq(r.handled, false, "shift+enter is not ours")
	eq(b.text, "ab", "text unchanged")
	r = press(b, "enter", { ctrl = true })
	eq(r.handled, false, "ctrl+enter is not ours")
	r = press(b, "enter", { alt = true })
	eq(r.handled, false, "alt+enter is not ours")
	r = press(b, "enter", { meta = true })
	eq(r.handled, false, "meta+enter is not ours")
end

local function test_autopair()
	current = "autopair"
	local b = B.new("")
	press(b, "(", { text = "(" }, R)
	eq(b.text, "()", "pair inserted")
	eq(b.cursor, 1, "caret between the two")
	press(b, ")", { text = ")" }, R)
	eq(b.text, "()", "closer stepped over")
	eq(b.cursor, 2, "caret past the pair")

	-- typing the closer later still steps over it
	b = B.new("")
	press(b, "[", { text = "[" }, R)
	typ(b, "1, 2]", R)
	eq(b.text, "[1, 2]", "typed through the pair")
	eq(b.cursor, 6)

	-- no pair when something else follows
	b = B.new("ab", 1)
	press(b, "(", { text = "(" }, R)
	eq(b.text, "a(b", "no pair before a word character")
	eq(b.cursor, 2)

	-- pairs before whitespace, a closer, or the end
	b = B.new(" ", 1)
	press(b, "{", { text = "{" }, R)
	eq(b.text, " {}", "pair at the end")
	b = B.new("  x", 0)
	press(b, "(", { text = "(" }, R)
	eq(b.text, "()  x", "pair before whitespace")
	eq(b.cursor, 1, "caret between the two")
	b = B.new("]", 0)
	press(b, "(", { text = "(" }, R)
	eq(b.text, "()]", "pair before a closer")

	-- quotes pair at the start and after whitespace, never after a word
	b = B.new("")
	press(b, '"', { text = '"' }, R)
	eq(b.text, '""', "quote pair")
	eq(b.cursor, 1)
	b = B.new("a ", 2)
	press(b, "'", { text = "'" }, R)
	eq(b.text, "a ''", "quote pair after a space")
	b = B.new("ab", 2)
	press(b, '"', { text = '"' }, R)
	eq(b.text, 'ab"', "no quote pair after a word")
	eq(b.cursor, 3)
	-- a quote after a quote still pairs: only word characters block it
	press(b, '"', { text = '"' }, R)
	eq(b.text, 'ab"""', "quote after quote")
	-- and a quote steps over its twin
	b = B.new('""', 1)
	press(b, '"', { text = '"' }, R)
	eq(b.text, '""', "quote stepped over")
	eq(b.cursor, 2)

	-- backspace takes both halves of an empty pair
	b = B.new("()", 1)
	press(b, "backspace", nil, R)
	eq(b.text, "", "empty pair deleted")
	eq(b.cursor, 0)
	b = B.new("''", 1)
	press(b, "backspace", nil, R)
	eq(b.text, "", "empty quote pair deleted")
	b = B.new("(x)", 2)
	press(b, "backspace", nil, R)
	eq(b.text, "()", "a filled pair loses one character")
	eq(b.cursor, 1)
	press(b, "backspace", nil, R)
	eq(b.text, "", "now it is empty, so both go")

	-- a selection is wrapped
	b = B.new("abc")
	b.anchor = 0
	b.cursor = 3
	press(b, "(", { text = "(" }, R)
	eq(b.text, "(abc)", "selection wrapped")
	eq(b.cursor, 5, "caret after the pair")
	eq(b.anchor, nil, "selection dropped")
	b = B.new("abc")
	b.anchor = 0
	b.cursor = 3
	press(b, '"', { text = '"' }, R)
	eq(b.text, '"abc"', "selection wrapped in quotes")
	b = B.new("abc")
	b.anchor = 0
	b.cursor = 3
	press(b, ")", { text = ")" }, R)
	eq(b.text, ")", "a closer replaces the selection instead")

	-- off unless asked for
	b = B.new("")
	press(b, "(", { text = "(" })
	eq(b.text, "(", "no autopair without opts")
	b = B.new("")
	press(b, "(", { text = "(" }, { lang = "markdown" })
	eq(b.text, "(", "no autopair in a markdown cell")
	b = B.new("")
	press(b, "(", { text = "(" }, { lang = "markdown", autopair = true })
	eq(b.text, "()", "autopair can be switched on")
	b = B.new("")
	press(b, "(", { text = "(" }, { lang = "r", autopair = false })
	eq(b.text, "(", "and off again")
end

local function test_movement()
	current = "movement"
	-- smart home
	local b = B.new("    foo", 7)
	press(b, "home")
	eq(b.cursor, 4, "home goes to the first non-blank")
	press(b, "home")
	eq(b.cursor, 0, "home again goes to column 0")
	press(b, "home")
	eq(b.cursor, 4, "and back again")
	b = B.new("   ", 3)
	press(b, "home")
	eq(b.cursor, 0, "home on a blank line")
	b = B.new("    foo bar", 3)
	press(b, "home")
	eq(b.cursor, 4, "home from inside the indent")

	-- end, and ctrl+home / ctrl+end
	b = B.new("foo\nbar", 1)
	press(b, "end")
	eq(b.cursor, 3, "end of the line")
	press(b, "right")
	eq(b.cursor, 4, "right crosses the newline")
	press(b, "home", { ctrl = true })
	eq(b.cursor, 0, "ctrl+home")
	press(b, "end", { ctrl = true })
	eq(b.cursor, 7, "ctrl+end")

	-- word moves
	b = B.new("foo bar  baz!")
	press(b, "left", { ctrl = true })
	eq(b.cursor, 12, "word left over the punctuation run")
	press(b, "left", { ctrl = true })
	eq(b.cursor, 9, "word left")
	press(b, "left", { ctrl = true })
	eq(b.cursor, 4, "word left again")
	press(b, "left", { alt = true })
	eq(b.cursor, 0, "alt+left works too")
	press(b, "right", { ctrl = true })
	eq(b.cursor, 3, "word right")
	press(b, "right", { ctrl = true })
	eq(b.cursor, 7, "word right across the double space")
	press(b, "right", { ctrl = true })
	eq(b.cursor, 12, "word right again")
	press(b, "right", { ctrl = true })
	eq(b.cursor, 13, "word right at the end")
	press(b, "home", { ctrl = true })
	press(b, "left", { ctrl = true })
	eq(b.cursor, 0, "word left at the start")

	-- shift extends, and the anchor is set once
	b = B.new("abc", 3)
	press(b, "left", { shift = true })
	eq(b.cursor, 2, "shift+left moves")
	eq(b.anchor, 3, "anchor set")
	press(b, "left", { shift = true })
	eq(b.cursor, 1, "shift+left again")
	eq(b.anchor, 3, "anchor kept")
	local s, e = B.selection(b)
	eq(s, 1, "selection start")
	eq(e, 3, "selection end")

	-- a plain move collapses the selection instead of moving further
	press(b, "left")
	eq(b.cursor, 1, "left collapses to the start")
	eq(b.anchor, nil, "selection dropped")
	b = B.new("abcdef", 4)
	b.anchor = 2
	press(b, "right")
	eq(b.cursor, 4, "right collapses to the end")
	eq(b.anchor, nil, "selection dropped")
	press(b, "right")
	eq(b.cursor, 5, "and then it moves")

	-- shift+home / shift+end extend
	b = B.new("  foo", 5)
	press(b, "home", { shift = true })
	eq(b.cursor, 2, "shift+home")
	eq(b.anchor, 5, "anchor kept")
end

local function test_vertical()
	current = "vertical moves"
	local b = B.new("abcdefgh\nab\nabcdefgh", 6)
	press(b, "down")
	eq(b.cursor, 11, "down clamps to the short line")
	press(b, "down")
	eq(b.cursor, 18, "the goal column comes back")
	press(b, "up")
	eq(b.cursor, 11, "up keeps the goal")
	press(b, "up")
	eq(b.cursor, 6, "back where we started")

	-- any other move forgets the goal
	b = B.new("abcdefgh\nab\nabcdefgh", 6)
	press(b, "down")
	press(b, "left")
	press(b, "down")
	eq(b.cursor, 13, "down from column 1, not the old goal")
	press(b, "up")
	eq(b.cursor, 10, "up again")

	-- the caret keeps its column through an empty line
	b = B.new("abcdef\n\nabcdef", 6)
	press(b, "down")
	eq(b.cursor, 7, "down onto the empty line")
	press(b, "down")
	eq(b.cursor, 14, "down from the empty line using the goal")

	-- edges are the caller's problem
	b = B.new("abc", 1)
	local r = press(b, "up")
	eq(r.handled, false, "up on the first line is not ours")
	eq(r.edge, "up", "edge up")
	eq(b.cursor, 1, "caret untouched")
	r = press(b, "down")
	eq(r.handled, false, "down on the last line is not ours")
	eq(r.edge, "down", "edge down")

	-- ...unless shift pulls the selection to the ends of the text
	b = B.new("abc", 1)
	r = press(b, "up", { shift = true })
	eq(r.handled, true, "shift+up is ours")
	eq(r.changed, false, "a pure selection change")
	eq(b.cursor, 0, "to the start of the text")
	eq(b.anchor, 1, "anchor kept")
	b = B.new("abc", 1)
	press(b, "down", { shift = true })
	eq(b.cursor, 3, "to the end of the text")
	eq(b.anchor, 1, "anchor kept")
end

local function test_tab()
	current = "tab"
	-- a multi-line selection indents every line it touches
	local b = B.new("aa\nbb\ncc")
	b.anchor = 0
	b.cursor = 5
	press(b, "tab", nil, R)
	eq(b.text, "  aa\n  bb\ncc", "two lines indented")
	eq(b.anchor, 2, "selection kept over them")
	eq(b.cursor, 9, "selection kept over them")
	press(b, "tab", { shift = true }, R)
	eq(b.text, "aa\nbb\ncc", "outdented again")
	eq(b.anchor, 0, "selection back")
	eq(b.cursor, 5, "selection back")

	-- a selection ending at a line start does not touch that line
	b = B.new("aa\nbb\ncc")
	b.anchor = 0
	b.cursor = 6
	press(b, "tab", nil, R)
	eq(b.text, "  aa\n  bb\ncc", "the line only reached is left alone")
	eq(b.cursor, 10, "selection kept")

	-- no selection: spaces up to the next stop
	b = B.new("ab", 1)
	press(b, "tab", nil, R)
	eq(b.text, "a b", "one space to the stop")
	eq(b.cursor, 2)
	b = B.new("", 0)
	press(b, "tab", nil, R)
	eq(b.text, "  ", "a full indent")
	eq(b.cursor, 2)
	b = B.new("", 0)
	press(b, "tab", nil, { indent = 4 })
	eq(b.text, "    ", "indent width from opts")
	b = B.new("ab", 0)
	press(b, "tab", nil, R)
	eq(b.text, "  ab", "at a line start the caret stays on the text")
	eq(b.cursor, 2)

	-- shift+tab takes up to one level off the leading spaces
	b = B.new("      x", 7)
	press(b, "tab", { shift = true }, R)
	eq(b.text, "    x", "two spaces off")
	eq(b.cursor, 5)
	press(b, "tab", { shift = true }, R)
	eq(b.text, "  x", "and again")
	eq(b.cursor, 3)
	press(b, "tab", { shift = true }, R)
	eq(b.text, "x", "and again")
	eq(b.cursor, 1, "caret still after the text")
	press(b, "tab", { shift = true }, R)
	eq(b.text, "x", "nothing left to take")
	eq(b.cursor, 1)

	-- an indent of several lines is one undo step
	b = B.new("aa\nbb")
	b.anchor = 0
	b.cursor = 5
	press(b, "tab", nil, R)
	eq(b.text, "  aa\n  bb")
	eq(B.undo(b), true, "undo the indent")
	eq(b.text, "aa\nbb", "both lines back in one step")
	eq(B.redo(b), true, "redo it")
	eq(b.text, "  aa\n  bb", "and forward again")

	-- with the caret in the text only its own line is touched
	b = B.new("  a\n  b", 1)
	press(b, "tab", { shift = true }, R)
	eq(b.text, "a\n  b", "only the caret's line")
end

local function test_backspace_delete()
	current = "backspace and delete"
	-- back to the previous indent stop
	local b = B.new("    x", 4)
	press(b, "backspace", nil, R)
	eq(b.text, "  x", "two spaces off in one go")
	eq(b.cursor, 2)
	press(b, "backspace", nil, R)
	eq(b.text, "x", "down to column 0")
	eq(b.cursor, 0)
	b = B.new("    x", 3)
	press(b, "backspace", nil, R)
	eq(b.text, "   x", "from inside the indent it still stops at a multiple")
	eq(b.cursor, 2)

	-- outside the indent: one character
	b = B.new("  ab", 4)
	press(b, "backspace", nil, R)
	eq(b.text, "  a", "one character")
	eq(b.cursor, 3)

	-- indentation is not touched when a tab is in it
	b = B.new("  \tx", 3)
	press(b, "backspace", nil, R)
	eq(b.text, "  x", "a tab in the indent means an ordinary delete")
	eq(b.cursor, 2)

	-- word deletes
	b = B.new("foo bar  baz!")
	press(b, "backspace", { ctrl = true }, R)
	eq(b.text, "foo bar  baz", "the punctuation run goes first")
	eq(b.cursor, 12)
	press(b, "backspace", { ctrl = true }, R)
	eq(b.text, "foo bar  ", "then the word with the whitespace before it")
	press(b, "backspace", { alt = true }, R)
	eq(b.text, "foo ", "alt+backspace")
	press(b, "backspace", { ctrl = true }, R)
	eq(b.text, "", "and the rest")
	press(b, "backspace", { ctrl = true }, R)
	eq(b.text, "", "nothing left")
	b = B.new("foo bar", 0)
	press(b, "delete", { ctrl = true }, R)
	eq(b.text, " bar", "ctrl+delete forward")
	eq(b.cursor, 0)
	press(b, "delete", { ctrl = true }, R)
	eq(b.text, "", "forward over the whitespace and the word")
	b = B.new("foo bar baz", 4)
	press(b, "delete", { alt = true }, R)
	eq(b.text, "foo  baz", "alt+delete forward over a word")
	eq(b.cursor, 4)
	b = B.new("  foo bar", 0)
	press(b, "delete", { ctrl = true }, R)
	eq(b.text, " bar", "forward delete eats the whitespace first")

	-- a selection goes first
	b = B.new("abcdef", 1)
	b.anchor = 4
	press(b, "backspace", nil, R)
	eq(b.text, "aef", "selection deleted")
	eq(b.cursor, 1)
	eq(b.anchor, nil, "selection dropped")
	b = B.new("abcdef", 1)
	b.anchor = 4
	press(b, "delete", nil, R)
	eq(b.text, "aef", "delete takes the selection too")

	-- nothing to delete
	b = B.new("abc", 3)
	local r = press(b, "delete")
	eq(r.handled, true, "handled")
	eq(r.changed, false, "nothing changed")
	b = B.new("abc", 0)
	press(b, "backspace")
	eq(b.text, "abc", "backspace at the start does nothing")
end

local function test_comments()
	current = "comments"
	local b = B.new("x <- 1\ny <- 2")
	b.anchor = 0
	b.cursor = 13
	press(b, "/", { ctrl = true }, R)
	eq(b.text, "# x <- 1\n# y <- 2", "both lines commented")
	eq(b.anchor, 2, "selection kept")
	eq(b.cursor, 17, "selection kept")
	press(b, "/", { ctrl = true }, R)
	eq(b.text, "x <- 1\ny <- 2", "and uncommented")
	eq(b.anchor, 0, "selection back")
	eq(b.cursor, 13, "selection back")

	-- ctrl+shift+c is the same key
	b = B.new("x")
	press(b, "c", { ctrl = true, shift = true }, R)
	eq(b.text, "# x", "ctrl+shift+c comments")
	press(b, "c", { ctrl = true, shift = true }, R)
	eq(b.text, "x", "and uncomments")
	press(b, "c", { ctrl = true, shift = true }, R)
	eq(b.text, "# x", "commenting a commented line adds another #")

	-- blank lines are skipped, the # goes after the shallowest indent
	b = B.new("  a\n\n    b")
	b.anchor = 0
	b.cursor = 10
	press(b, "/", { ctrl = true }, R)
	eq(b.text, "  # a\n\n  #   b", "blank line skipped, shared indent column")
	press(b, "/", { ctrl = true }, R)
	eq(b.text, "  a\n\n    b", "and back")

	-- a caret alone touches its own line
	b = B.new("x\ny", 1)
	press(b, "/", { ctrl = true }, R)
	eq(b.text, "# x\ny", "only the caret's line")

	-- all-blank lines: nothing happens
	b = B.new("   \n")
	press(b, "/", { ctrl = true }, R)
	eq(b.text, "   \n", "blank lines are not commented")

	-- other languages do not get these keys
	b = B.new("x")
	local r = press(b, "/", { ctrl = true }, { lang = "markdown" })
	eq(r.handled, false, "ctrl+/ is the caller's in markdown")
	r = press(b, "c", { ctrl = true, shift = true }, { lang = "markdown" })
	eq(r.handled, false, "ctrl+shift+c is the caller's in markdown")
	r = press(b, "/", { ctrl = true }, { lang = "yaml" })
	eq(r.handled, false, "and in yaml")
	r = press(b, "/", { ctrl = true })
	eq(r.handled, false, "and with no language at all")
	eq(b.text, "x", "nothing changed")

	-- R-only typing helpers
	b = B.new("x", 1)
	press(b, "m", { ctrl = true, shift = true }, R)
	eq(b.text, "x |> ", "ctrl+shift+m")
	b = B.new("x", 1)
	press(b, "-", { alt = true }, R)
	eq(b.text, "x <- ", "alt+-")
	b = B.new("x ", 2)
	press(b, "-", { alt = true }, R)
	eq(b.text, "x <- ", "no doubled space after one that is there")
	b = B.new("x", 1)
	r = press(b, "-", { alt = true }, { lang = "markdown" })
	eq(r.handled, false, "alt+- is not ours outside R")
	eq(b.text, "x", "text unchanged")
	b = B.new("x", 1)
	r = press(b, "m", { ctrl = true, shift = true }, { lang = "markdown" })
	eq(r.handled, false, "ctrl+shift+m is not ours outside R")
	b = B.new("x", 1)
	r = press(b, "-", { alt = true }, R)
	eq(r.changed, true, "alt+- reports a change")
end

local function test_undo()
	current = "undo"
	-- typed characters coalesce into one step
	local b = B.new("")
	typ(b, "abc", R)
	eq(b.text, "abc", "typed")
	eq(B.undo(b), true, "one undo")
	eq(b.text, "", "the whole word goes at once")
	eq(B.undo(b), false, "and then nothing is left")
	eq(B.redo(b), true, "redo")
	eq(b.text, "abc", "the whole word comes back")
	eq(b.cursor, 3, "caret restored")
	eq(B.redo(b), false, "no more redo")

	-- whitespace ends a group (and rides along with the one before it)
	b = B.new("")
	typ(b, "ab c", R)
	eq(b.text, "ab c", "typed")
	eq(B.undo(b), true, "first undo")
	eq(b.text, "ab ", "the space came back with the first word")
	eq(B.undo(b), true, "second undo")
	eq(b.text, "", "empty")

	-- a caret move ends the group
	b = B.new("")
	typ(b, "ab", R)
	press(b, "left", nil, R)
	press(b, "right", nil, R)
	typ(b, "c", R)
	eq(b.text, "abc", "typed after moving")
	eq(B.undo(b), true, "first undo")
	eq(b.text, "ab", "only the character typed after the move")
	eq(B.undo(b), true, "second undo")
	eq(b.text, "", "the word from before the move")

	-- backspaces coalesce too
	b = B.new("abc", 3)
	press(b, "backspace", nil, R)
	press(b, "backspace", nil, R)
	eq(b.text, "a", "deleted")
	eq(B.undo(b), true, "one undo")
	eq(b.text, "abc", "both backspaces come back together")
	eq(b.cursor, 3, "caret restored")
	eq(B.undo(b), false, "a new run of backspaces")

	-- deleting all the backspaced text is its own step
	b = B.new("abc", 3)
	press(b, "backspace", nil, R)
	press(b, "delete", nil, R)
	eq(b.text, "ab", "backspace then delete")
	eq(B.undo(b), true, "undo the delete")
	eq(b.text, "abc", "back again")

	-- a new edit drops the redo history
	b = B.new("")
	typ(b, "ab", R)
	eq(B.undo(b), true, "undo")
	typ(b, "c", R)
	eq(b.text, "c", "typed instead")
	eq(B.redo(b), false, "redo is gone")
	eq(b.text, "c", "and the text stays")

	-- undo restores the caret and the selection
	b = B.new("abc")
	press(b, "a", { ctrl = true }, R)
	eq(b.anchor, 0, "select all")
	eq(b.cursor, 3, "select all")
	typ(b, "X", R)
	eq(b.text, "X", "replaced")
	eq(B.undo(b), true, "undo")
	eq(b.text, "abc", "text back")
	eq(b.cursor, 3, "caret back")
	eq(b.anchor, 0, "selection back")

	-- undo after typing into a selection restores the selection over the text
	b = B.new("hello")
	b.anchor = 0
	b.cursor = 5
	typ(b, "y", R)
	eq(b.text, "y", "replaced a selection")
	eq(B.undo(b), true, "undo")
	eq(b.text, "hello", "text back")

	-- the undo and redo keys drive the same history
	b = B.new("")
	typ(b, "ab", R)
	local r = press(b, "z", { ctrl = true }, R)
	eq(r.handled, true, "ctrl+z is ours")
	eq(r.changed, true, "ctrl+z changed the text")
	eq(b.text, "", "ctrl+z undid")
	press(b, "z", { ctrl = true, shift = true }, R)
	eq(b.text, "ab", "ctrl+shift+z redid")
	press(b, "z", { ctrl = true }, R)
	eq(b.text, "", "ctrl+z again")
	press(b, "y", { ctrl = true }, R)
	eq(b.text, "ab", "ctrl+y redoes too")
	r = press(b, "y", { meta = true }, R)
	eq(r.handled, true, "meta+y is redo as well")
	eq(r.changed, false, "with nothing left to redo")
	eq(b.text, "ab", "text unchanged")
	b = B.new("abc")
	press(b, "a", { ctrl = true }, R)
	r = press(b, "z", { ctrl = true }, R)
	eq(r.handled, true, "ctrl+z with no history is still ours")
	eq(r.changed, false, "but changes nothing")
	eq(b.text, "abc", "text unchanged")

	-- meta works for the editing shortcuts too
	b = B.new("abc")
	b.anchor = 0
	b.cursor = 3
	r = press(b, "c", { meta = true }, R)
	eq(r.copy, "abc", "meta+c copies")

	-- the history is capped at 200 steps
	b = B.new("")
	for _ = 1, 220 do
		typ(b, "a", R)
		press(b, "left", nil, R)
		press(b, "right", nil, R)
	end
	eq(#b.text, 220, "everything typed")
	local steps = 0
	while B.undo(b) do
		steps += 1
	end
	eq(steps, 200, "only the last 200 steps are kept")
end

local function test_copy_cut()
	current = "copy and cut"
	-- copy with a selection
	local b = B.new("abc\ndef")
	b.anchor = 0
	b.cursor = 3
	local r = press(b, "c", { ctrl = true }, R)
	eq(r.handled, true, "handled")
	eq(r.changed, false, "copying changes nothing")
	eq(r.copy, "abc", "copied the selection")
	eq(b.text, "abc\ndef", "text untouched")

	-- copy without a selection takes the whole line and its newline
	b = B.new("abc\ndef", 1)
	r = press(b, "c", { ctrl = true }, R)
	eq(r.copy, "abc\n", "current line plus newline")
	b = B.new("abc\ndef", 5)
	r = press(b, "c", { ctrl = true }, R)
	eq(r.copy, "def\n", "last line gets a newline too")

	-- cut without a selection removes the line
	b = B.new("abc\ndef", 1)
	r = press(b, "x", { ctrl = true }, R)
	eq(r.copy, "abc\n", "copied")
	eq(b.text, "def", "line removed")
	eq(b.cursor, 0, "caret at the line start")
	eq(B.undo(b), true, "undo")
	eq(b.text, "abc\ndef", "line back")

	-- cutting the last line
	b = B.new("a\nb", 3)
	r = press(b, "x", { ctrl = true }, R)
	eq(r.copy, "b\n", "copied")
	eq(b.text, "a\n", "removed")
	eq(b.cursor, 2, "caret at the end")

	-- cut with a selection
	b = B.new("abc\ndef")
	b.anchor = 0
	b.cursor = 3
	r = press(b, "x", { ctrl = true }, R)
	eq(r.copy, "abc", "copied")
	eq(b.text, "\ndef", "removed")
	eq(b.cursor, 0, "caret at the start")
	eq(b.anchor, nil, "selection dropped")
end

local function test_misc()
	current = "misc"
	-- paste normalises line endings and never autopairs
	local b = B.new("")
	local r = B.key(b, key("paste", { text = "a\r\nb\rc((" }), R)
	eq(b.text, "a\nb\nc((", "CRLF and CR become LF, brackets are not paired")
	eq(r.handled, true, "paste handled")
	eq(r.changed, true, "paste changed")
	eq(b.cursor, 7, "caret at the end")
	b = B.new("")
	r = B.key(b, key("paste"), R)
	eq(r.handled, true, "an empty paste is handled")
	eq(r.changed, false, "but changes nothing")

	-- paste replaces a selection
	b = B.new("abcdef")
	b.anchor = 0
	b.cursor = 3
	B.key(b, key("paste", { text = "xy" }), R)
	eq(b.text, "xydef", "selection replaced")

	-- key.text types the character
	b = B.new("")
	B.key(b, key("a", { text = "A", shift = true }), R)
	eq(b.text, "A", "shifted text is inserted as given")
	B.key(b, key("space", { text = " " }), R)
	eq(b.text, "A ", "space")
	b = B.new("")
	B.key(b, key("é", { text = "é" }), R)
	eq(b.text, "é", "multibyte typing")
	b = B.new("")
	B.key(b, key("space"), R) -- a host that leaves `text` off
	eq(b.text, " ", "space without text still types a space")

	-- M.insert replaces the selection and is undoable
	b = B.new("abc", 1)
	B.insert(b, "X")
	eq(b.text, "aXbc", "inserted at the caret")
	eq(b.cursor, 2, "caret after the text")
	eq(B.undo(b), true, "undo")
	eq(b.text, "abc", "back")
	b = B.new("abcdef")
	b.anchor = 1
	b.cursor = 4
	B.insert(b, "Z")
	eq(b.text, "aZef", "selection replaced")
	eq(b.cursor, 2, "caret after the text")
	eq(b.anchor, nil, "selection dropped")
	b = B.new("abc", 1)
	B.insert(b, "")
	eq(b.text, "abc", "an empty insert at the caret does nothing")

	-- M.replace
	b = B.new("abcdef")
	B.replace(b, 2, 4, "XY")
	eq(b.text, "abXYef", "range replaced")
	eq(b.cursor, 4, "caret after the replacement")
	eq(B.undo(b), true, "undoable")
	eq(b.text, "abcdef", "back")
	b = B.new("abcdef")
	B.replace(b, 9, 20, "!")
	eq(b.text, "abcdef!", "out of range clamps")

	-- M.selection
	b = B.new("abc")
	local s, e = B.selection(b)
	eq(s, nil, "no selection")
	eq(e, nil, "no selection")
	b.cursor = 2
	b.anchor = 2
	s, e = B.selection(b)
	eq(s, nil, "anchor == cursor is no selection")
	eq(e, nil, "anchor == cursor is no selection")
	b.cursor = 1
	s, e = B.selection(b)
	eq(s, 1, "ordered start")
	eq(e, 2, "ordered end")
	b.cursor = 3
	b.anchor = 1
	s, e = B.selection(b)
	eq(s, 1, "still ordered when the caret is last")
	eq(e, 3, "still ordered when the caret is last")

	-- ctrl+a selects everything
	b = B.new("abc\ndef")
	press(b, "a", { ctrl = true }, R)
	eq(b.anchor, 0, "anchor at the start")
	eq(b.cursor, 7, "caret at the end")
	-- meta works like ctrl
	b = B.new("abc", 3)
	press(b, "a", { meta = true }, R)
	eq(b.anchor, 0, "meta+a selects all too")

	-- a pure caret move reports handled without a change
	b = B.new("abc", 1)
	r = press(b, "right", nil, R)
	eq(r.handled, true, "handled")
	eq(r.changed, false, "unchanged")
	eq(r.copy, nil, "no copy text")
	eq(r.edge, nil, "no edge")

	-- keys the caller owns
	b = B.new("abc", 1)
	local owned = {
		{ name = "escape" },
		{ name = "page_up" },
		{ name = "page_down" },
		{ name = "f5" },
		{ name = "insert" },
		{ name = "menu" },
		{ name = "enter", shift = true },
		{ name = "enter", ctrl = true },
		{ name = "up", ctrl = true },
		{ name = "down", ctrl = true },
		{ name = "q", alt = true },
		{ name = "p", ctrl = true },
		{ name = "a", ctrl = true, shift = true },
		{ name = "space", ctrl = true },
		{ name = "tab", ctrl = true },
	}
	for _, c in ipairs(owned) do
		local res = press(b, c.name, c, R)
		eq(res.handled, false, "unhandled: " .. c.name)
		eq(res.changed, false, "unchanged: " .. c.name)
		eq(b.text, "abc", "text untouched by " .. c.name)
		eq(b.cursor, 1, "caret untouched by " .. c.name)
	end

	-- a hand-built Buf (a restored cell) works too
	local restored = { text = "abc", cursor = 1 }
	B.key(restored, key("delete"), R)
	eq(restored.text, "ac", "editing a Buf without private fields")
	eq(B.undo(restored), true, "its history works")
	eq(restored.text, "abc", "back")
end

-- ---------------------------------------------------------------------------

-- What every key press must leave behind: caret and anchor inside the text and
-- on character boundaries.
local function check_buf(b: any, what: string)
	ok(b.cursor >= 0 and b.cursor <= #b.text, what .. ": cursor in range")
	ok(b.anchor == nil or (b.anchor >= 0 and b.anchor <= #b.text), what .. ": anchor in range")
	ok(utf8.len(b.text:sub(1, b.cursor)) ~= nil, what .. ": cursor on a character boundary")
	if b.anchor ~= nil then
		ok(utf8.len(b.text:sub(1, b.anchor)) ~= nil, what .. ": anchor on a character boundary")
	end
end

-- Drive every kind of key over awkward buffers and check that nothing raises
-- and that the flags agree with what happened to the text.
local function test_dispatch_smoke()
	current = "dispatch smoke"
	local texts = {
		"",
		"a",
		"aé😀b",
		"  {\n  }\n",
		"x <- 1\r\ny <- 2",
		"foo(bar, baz)\n",
		"\n\n",
		"# c\n\n  x |> f()\n",
		"# a\n  #   b",
		"    indented\nab\n",
	}
	local keys = {
		key("enter"),
		key("tab"),
		key("backspace"),
		key("delete"),
		key("escape"),
		key("space"),
		key("space", { text = " " }),
		key("up"),
		key("down"),
		key("left"),
		key("right"),
		key("home"),
		key("end"),
		key("page_up"),
		key("page_down"),
		key("f5"),
		key("insert"),
		key("paste", { text = "x\r\ny((" }),
		key("paste"),
		key("a", { text = "a" }),
		key("é", { text = "é" }),
		key("😀", { text = "😀" }),
		key("(", { text = "(" }),
		key(")", { text = ")" }),
		key("[", { text = "[" }),
		key("[", { text = "]" }),
		key('"', { text = '"' }),
		key("1", { text = "1" }),
		key("-", { text = "-" }),
		key("a", { text = "A", shift = true }),
		key("enter", { shift = true }),
		key("tab", { shift = true }),
		key("backspace", { ctrl = true }),
		key("delete", { ctrl = true }),
		key("left", { ctrl = true }),
		key("right", { ctrl = true }),
		key("left", { shift = true }),
		key("right", { shift = true }),
		key("up", { shift = true }),
		key("down", { shift = true }),
		key("home", { ctrl = true }),
		key("end", { ctrl = true }),
		key("home", { shift = true }),
		key("end", { shift = true }),
		key("a", { ctrl = true }),
		key("c", { ctrl = true }),
		key("x", { ctrl = true }),
		key("z", { ctrl = true }),
		key("z", { ctrl = true, shift = true }),
		key("y", { ctrl = true }),
		key("/", { ctrl = true }),
		key("c", { ctrl = true, shift = true }),
		key("m", { ctrl = true, shift = true }),
		key("-", { alt = true }),
		key("left", { alt = true }),
		key("backspace", { alt = true }),
		key("q", { alt = true }),
		key("p", { ctrl = true }),
		key("u", { meta = true, alt = true }),
	}
	local opts_list = {
		R,
		{ lang = "markdown" },
		{ lang = "yaml", indent = 4 },
		{ autopair = true, indent = 1 },
		nil,
	}
	-- a fixed sequence, so a failure always reproduces
	local seed = 20261013
	local function rnd(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed
	end
	for _ = 1, 400 do
		local text = texts[rnd() % #texts + 1]
		local b = B.new(text, rnd() % (#text + 1))
		for _ = 1, 10 do
			local k = keys[rnd() % #keys + 1]
			local opts = opts_list[rnd() % #opts_list + 1]
			local before = b.text
			local before_cursor = b.cursor
			local before_anchor = b.anchor
			local where = ("%s at %d/%s of %q with %s"):format(
				k.name,
				before_cursor,
				tostring(before_anchor),
				before,
				tostring((opts or {}).lang)
			)
			local res = B.key(b, k, opts)
			ok(type(res.handled) == "boolean", "handled is a boolean")
			ok(type(res.changed) == "boolean", "changed is a boolean")
			ok(
				not res.changed or b.text ~= before,
				("changed means the text changed: %s\n  after: %q at %d/%s"):format(
					where,
					b.text,
					b.cursor,
					tostring(b.anchor)
				)
			)
			ok(res.changed or b.text == before, "unchanged means the text stayed: " .. where)
			check_buf(b, "after " .. k.name)
			-- the history must survive being driven from anywhere
			B.undo(b)
			check_buf(b, "after undo")
			B.redo(b)
			check_buf(b, "after redo")
		end
	end
end

-- ---------------------------------------------------------------------------

test_utf8_helpers()
test_utf8_editing()
test_enter()
test_autopair()
test_movement()
test_vertical()
test_tab()
test_backspace_delete()
test_comments()
test_undo()
test_copy_cut()
test_misc()
test_dispatch_smoke()

print(("buffer_test: %d checks passed"):format(checked))
