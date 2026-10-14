--!strict
-- Run: luau tests/rmd_test.luau (from the package directory)
local rmd = require("../rmd")

local passed = 0
local function check(name: string, ok: boolean, detail: string?)
	if not ok then
		error(name .. " failed" .. (if detail then ": " .. detail else ""), 2)
	end
	passed += 1
end

local function roundtrip(name: string, text: string)
	local out = rmd.serialize(rmd.parse(text))
	check(name .. " round-trips", out == text, string.format("%q", out))
end

local function kinds(doc: rmd.Doc): string
	local out = {}
	for _, c in doc.cells do
		table.insert(out, if c.spacer then "_" else c.kind)
	end
	return table.concat(out, " ")
end

local homework = [[
---
title: "CSE4334 HW5 Linear Regression"
author: "Student Name"
output: html_notebook
---

This is an [R Markdown](http://rmarkdown.rstudio.com) Notebook.

Good luck!
```{r}
library(car)
```

```{r}
#your code goes here:

```
## Step 2
```{r}
```
]]

roundtrip("homework", homework)
roundtrip("no final newline", "Text\n```{r}\n1\n```")
roundtrip("crlf", "---\r\ntitle: x\r\n---\r\n\r\n```{r}\r\n1+1\r\n```\r\n")
roundtrip("unclosed chunk stays markdown", "```{r}\nx <- 1\n")
roundtrip("plain fence stays markdown", "```r\nx\n```\n")
roundtrip("only text", "# Title\n\nSome text.\n")
roundtrip("empty", "")
roundtrip("knitr prefixes", "> ```{r}\n> 1\n> ```\n")
roundtrip("empty front matter", "---\n---\nhi\n")

local doc = rmd.parse(homework)
check("homework cells", kinds(doc) == "yaml md code _ code md code", kinds(doc))
check("front matter", rmd.front(doc.cells[1]).title == "CSE4334 HW5 Linear Regression")
check("md body trimmed", doc.cells[2].src == "This is an [R Markdown](http://rmarkdown.rstudio.com) Notebook.\n\nGood luck!")
check("code body", doc.cells[3].src == "library(car)")
check("code trailing blank line kept", doc.cells[5].src == "#your code goes here:\n")
check("bare chunk", doc.cells[7].bare and doc.cells[7].src == "")

-- Headers
local c = rmd.parse("```{r setup, include=FALSE}\n```\n").cells[1]
local engine, rest = rmd.engine(c)
check("engine", engine == "r" and rest == "setup, include=FALSE", rest)
check("label", rmd.label(c) == "setup")
check("no label", rmd.label(rmd.parse("```{r, echo=FALSE}\n```\n").cells[1]) == nil)
check("python engine", (rmd.engine(rmd.parse("```{python}\n```\n").cells[1])) == "python")
rmd.set_header(c, "r setup")
check("set_header rebuilds the fence", rmd.open_line(c) == "```{r setup}")

-- Edits serialize as RStudio would write them
local edit = rmd.parse("Intro\n")
table.insert(edit.cells, rmd.new_spacer(edit))
local code = rmd.new_code(edit, "x <- 1")
table.insert(edit.cells, code)
check("inserted chunk", rmd.serialize(edit) == "Intro\n\n```{r}\nx <- 1\n```\n", rmd.serialize(edit))
code.src = ""
check("emptied chunk keeps a blank line", rmd.serialize(edit) == "Intro\n\n```{r}\n\n```\n")
edit.cells[1].src = "Intro without newline"
edit.cells[1].trail = ""
edit.cells[2].lead = ""
check("fence starts a line", rmd.serialize(edit) == "Intro without newline\n```{r}\n\n```\n", rmd.serialize(edit))

local conv = rmd.parse("```{r}\nSome *text*\n```\n")
rmd.convert(conv, conv.cells[1], "md")
check("code to markdown", rmd.serialize(conv) == "Some *text*\n")
rmd.convert(conv, conv.cells[1], "code")
check("markdown to code", rmd.serialize(conv) == "```{r}\nSome *text*\n```\n")

-- Chunks as knitr finds them, and their code as knitr runs it
local function code_of(text: string): string
	local out = {}
	for _, cell in rmd.parse(text).cells do
		if cell.kind == "code" then
			table.insert(out, rmd.code(cell))
		end
	end
	return table.concat(out, " | ")
end
local function code_is(name: string, text: string, want: string)
	local got = code_of(text)
	check(name, got == want, string.format("%q", got))
end
code_is("a four-backtick chunk may hold a ``` line", "T\n````{r}\n```\nx\n````\n", "```\nx")
code_is("a chunk closes only at its own fence", "T\n```{r}\n1\n````\n2\n```\n", "1\n````\n2")
code_is("a new opener ends an unclosed chunk", "T\n```{r}\nx\n```{r}\ny\n```\n", "y")
code_is("the engine ends at a space or comma", "T\n```{r-foo}\n1\n```\n", "")
code_is("braces inside the options", "T\n```{r, fig.cap='}'}\n1\n```\n", "1")
code_is("blockquote prefix comes off the code", "> ```{r}\n> x <- 1\n>\n> x\n> ```\n", "x <- 1\n\nx")
code_is("list indent comes off the code", "- a\n\n    ```{r}\n    y <- 1\n    ```\n", "y <- 1")
roundtrip("four-backtick chunk", "T\n````{r}\n```\nx\n````\n")
roundtrip("mixed line endings stay mixed", "a\r\nb\nc\n")

print(string.format("rmd: %d checks passed", passed))
