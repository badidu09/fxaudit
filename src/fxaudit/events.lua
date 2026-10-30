--- Finds event registrations and triggers, shared by the security and event rules.
local Ast = require("fxaudit.ast")

local Events = {}

--- Callback registrars: the number of leading parameters filled in by the server.
local CALLBACK_REGISTRARS = {
  ["lib.callback.register"] = 1,
  ["ESX.RegisterServerCallback"] = 2,
  ["QBCore.Functions.CreateCallback"] = 2,
}

--- Resolves a handler argument: an inline function or a local holding one.
local function resolveHandler(arg)
  if not arg then return nil end
  arg = Ast.unparen(arg)
  if arg.type == "Function" then return arg end
  if arg.type == "Name" and arg.var and arg.var.funcValue then return arg.var.funcValue end
  return nil
end

--- Scans a file.
-- @return table `{ netRegistered, handlers, triggers }`: `netRegistered` maps event names
--   to their registering node; `handlers` lists `{ event, func, node, kind, skip }` with
--   kind "net", "local" or "callback" and `skip` the count of trusted parameters;
--   `triggers` lists `{ event, node, side }`, side being the direction: "server" or "client".
function Events.scan(chunk)
  local result = { netRegistered = {}, handlers = {}, triggers = {} }

  Ast.walk(chunk, function(node)
    if node.type ~= "Call" then return end
    local name = Ast.path(node.func)
    if not name then return end
    local first = node.args[1] and Ast.unparen(node.args[1])
    local event = first and first.type == "String" and first.value or nil

    if name == "RegisterNetEvent" or name == "RegisterServerEvent" then
      if event then
        result.netRegistered[event] = result.netRegistered[event] or node
        local func = resolveHandler(node.args[2])
        if func then
          result.handlers[#result.handlers + 1] = { event = event, func = func, node = node, kind = "net", skip = 0 }
        end
      end
    elseif name == "AddEventHandler" then
      local func = resolveHandler(node.args[2])
      if event then
        result.handlers[#result.handlers + 1] = { event = event, func = func, node = node, kind = "local", skip = 0 }
      end
    elseif CALLBACK_REGISTRARS[name] then
      local func = resolveHandler(node.args[2])
      if func then
        result.handlers[#result.handlers + 1] = {
          event = event or "<dynamic>", func = func, node = node, kind = "callback", skip = CALLBACK_REGISTRARS[name],
        }
      end
    elseif name == "TriggerServerEvent" or name == "TriggerLatentServerEvent" then
      if event then result.triggers[#result.triggers + 1] = { event = event, node = node, side = "server" } end
    elseif name == "TriggerClientEvent" or name == "TriggerLatentClientEvent" then
      if event then result.triggers[#result.triggers + 1] = { event = event, node = node, side = "client" } end
    elseif name == "TriggerEvent" then
      if event then result.triggers[#result.triggers + 1] = { event = event, node = node, side = "local" } end
    end
  end)

  -- A local handler becomes client-callable if the event is also registered for the network.
  for _, handler in ipairs(result.handlers) do
    if handler.kind == "local" and result.netRegistered[handler.event] then
      handler.kind = "net"
    end
  end

  return result
end

return Events
