-- rex_tail.lua: lets Rex's Tail ask its questions in Rex's command palette.
--
-- Rex shows a prompt (rex.ui.pick) only from an action that the server's
-- init.lua defines. A script sent with `rex do -e` runs inside the rex
-- command and gets "unsupported". So Rex's Tail calls this action instead:
--
--   rex do rex_tail_pick title="Upgrade nucleus?" items='[{"id":"go","title":"Upgrade"}]'
--
-- Install: put this file next to init.lua and add
--
--   pcall(require, "rex_tail")
--
-- It returns {"answer": id} or {"why": reason}, the reasons being those of
-- rex.ui.pick (cancelled, timeout, no_client, unsupported, busy, failed).

local ok, ui = pcall(function() return rex.ui end)
if not ok or ui == nil then return {} end

rex.action{
  name        = "rex_tail_pick",
  title       = "Rex's Tail: Ask",
  description = "Used by Rex's Tail to ask a question in the palette",
  category    = "Rex's Tail",
  args        = { title = "string", items = "string",
                  placeholder = "string?", timeout = "integer?" },
  run = function(ctx, args)
    local items, err = rex.json.decode(args.items)
    if type(items) ~= "table" then
      return { why = "failed", detail = "items is not a JSON list: " .. tostring(err) }
    end
    local answer, why, detail = rex.ui.pick{
      title       = args.title,
      placeholder = args.placeholder,
      timeout     = args.timeout or 300,
      items       = items,
    }
    if answer ~= nil then return { answer = answer } end
    return { why = why, detail = detail }
  end,
}

return {}
