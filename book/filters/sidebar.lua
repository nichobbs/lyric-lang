-- sidebar.lua
-- Pandoc Lua filter: wraps Div elements with class "sidebar" or "note"
-- so they render as styled blocks in both HTML and LaTeX output.
--
-- In HTML the classes are passed through and styled via style.css.
-- In LaTeX we wrap them in a tcolorbox-like shaded environment.

local function is_latex()
  return FORMAT:match("latex") or FORMAT:match("pdf")
end

function Div(el)
  local cls = el.classes[1] or ""

  if FORMAT:match("html") then
    -- HTML: leave the div as-is; style.css handles .sidebar / .note
    return el
  end

  if is_latex() then
    if cls == "sidebar" then
      local before = pandoc.RawBlock("latex",
        "\\begin{tcolorbox}[colback=blue!4!white,colframe=blue!40!black," ..
        "boxrule=0.4pt,arc=2pt,left=6pt,right=6pt,top=4pt,bottom=4pt," ..
        "fonttitle=\\bfseries\\small,title={Design note}]\\small")
      local after  = pandoc.RawBlock("latex", "\\end{tcolorbox}")
      return {before, el, after}
    elseif cls == "note" then
      local before = pandoc.RawBlock("latex",
        "\\begin{tcolorbox}[colback=orange!6!white,colframe=orange!60!black," ..
        "boxrule=0.4pt,arc=2pt,left=6pt,right=6pt,top=4pt,bottom=4pt," ..
        "fonttitle=\\bfseries\\small,title={Note}]\\small")
      local after  = pandoc.RawBlock("latex", "\\end{tcolorbox}")
      return {before, el, after}
    end
  end

  return el
end
