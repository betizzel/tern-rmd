--!strict
-- window.luau: opens .Rmd files as notebooks.
--
-- Opens a person asks for (the Files pane, the palette, `tern open`, a drop,
-- the system) become an `rmd.notebook` block. Links are left alone, so a
-- path clicked in a terminal, or the notebook's own "open the source" click,
-- still opens the plain text in a file block.

local claimed = { files = true, palette = true, cli = true, drop = true, system = true }

tern.route.open(function(req, _cx)
	if not string.match(string.lower(req.path), "%.rmd$") then
		return nil
	end
	if not claimed[req.origin] or req.how == "replace" then
		return nil
	end
	return { block = "rmd.notebook", args = { req.path } }
end)
