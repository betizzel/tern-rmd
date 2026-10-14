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

print(string.format("rmd: %d checks passed", passed))
