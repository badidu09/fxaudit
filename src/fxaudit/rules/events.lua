--- FX8xx: events and exports that cannot work as written.
local Ast = require("fxaudit.ast")
local Events = require("fxaudit.events")
local Text = require("fxaudit.text")

local EventRules = {}

-- Events fired by the runtime or by frameworks, which no resource needs to define.
local function isExternalEvent(name)
  return name:find("^__cfx") or name:find("^on[A-Z]") or name:find("^player[A-Z]")
    or name:find("^esx:") or name:find("^QBCore:") or name:find("^qbx_core:") or name:find("^ox:")
end

local function prefixOf(name)
  return name:match("^([^:]+):")
end

local function checkExportsCalls(ctx, project)
  Ast.walk(ctx.chunk, function(node)
    if node.type == "Call" then
      local f = Ast.unparen(node.func)
      -- exports.res.fn(...) or exports['res'].fn(...)
      if f.type == "Index" and f.dotted then
        local holder = Ast.unparen(f.object)
        if holder.type == "Index" and holder.object.type == "Name" and holder.object.name == "exports"
          and not holder.object.var then
          local resourceName = holder.key.type == "String" and holder.key.value or "resource"
          ctx.report("FX804", node, "this export is called with '.', so its first argument is lost", {
            hint = "write exports." .. resourceName .. ":" .. f.name .. "(...)",
            confidence = "medium",
          })
        end
      end
    elseif node.type == "MethodCall" and project then
      local holder = Ast.unparen(node.object)
      if holder.type == "Index" and holder.object.type == "Name" and holder.object.name == "exports"
        and not holder.object.var and holder.key.type == "String" then
        local exported = project.exportsOf and project.exportsOf(holder.key.value)
        if exported and not exported[node.method] then
          local finder = Text.suggester(node.method)
          for name in pairs(exported) do finder.offer(name) end
          ctx.report("FX805", node, "resource '" .. holder.key.value .. "' has no export '" .. node.method .. "'", {
            hint = finder.best and ("did you mean '" .. finder.best .. "'?") or nil,
            confidence = "medium",
          })
        end
      end
    end
  end)
end

--- Collects what the resource's own exports are, for cross-resource checks.
function EventRules.collectExports(chunk, into)
  Ast.walk(chunk, function(node)
    if node.type == "Call" then
      local f = Ast.unparen(node.func)
      if f.type == "Name" and f.name == "exports" and not f.var then
        local name = node.args[1] and Ast.unparen(node.args[1])
        if name and name.type == "String" then into[name.value] = true end
      elseif f.type == "Name" and f.name == "AddEventHandler" then
        local name = node.args[1] and Ast.unparen(node.args[1])
        if name and name.type == "String" then
          local exported = name.value:match("^__cfx_export_[^_]+_(.+)$")
          if exported then into[exported] = true end
        end
      end
    end
  end)
end

function EventRules.checkResource(resource)
  local registered = { client = {}, server = {} }
  local handled = { client = {}, server = {} }
  local firstHandler = { client = {}, server = {} }
  local triggers = {}
  local dynamicHandlers = false
  local localTriggered = {}

  local function sidesOf(ctx)
    if ctx.side == "client" then return { "client" } end
    if ctx.side == "server" then return { "server" } end
    return { "client", "server" }
  end

  for _, ctx in ipairs(resource.files) do
    ctx.eventScan = ctx.eventScan or Events.scan(ctx.chunk)
    local scan = ctx.eventScan
    for _, side in ipairs(sidesOf(ctx)) do
      for event in pairs(scan.netRegistered) do registered[side][event] = true end
      for _, handler in ipairs(scan.handlers) do
        handled[side][handler.event] = true
        firstHandler[side][handler.event] = firstHandler[side][handler.event] or { ctx = ctx, node = handler.node }
      end
    end
    for _, trigger in ipairs(scan.triggers) do
      trigger.ctx = ctx
      triggers[#triggers + 1] = trigger
      if trigger.side == "local" then localTriggered[trigger.event] = true end
    end

    -- Handlers registered with a computed name make the "no handler" check unreliable.
    Ast.walk(ctx.chunk, function(node)
      if node.type == "Call" then
        local path = Ast.path(node.func)
        if (path == "RegisterNetEvent" or path == "AddEventHandler" or path == "RegisterServerEvent") and node.args[1]
          and Ast.unparen(node.args[1]).type ~= "String" then
          dynamicHandlers = true
        elseif path == "RegisterServerEvent" then
          ctx.report("FX802", node, "RegisterServerEvent is an old alias", { hint = "use RegisterNetEvent" })
        elseif path == "TriggerClientEvent" and #node.args < 2 then
          ctx.report("FX803", node, "TriggerClientEvent needs a target player as second argument", {
            hint = "pass a player id, or -1 for everyone",
          })
        end
      end
    end)

    checkExportsCalls(ctx, resource.project)
  end

  -- Prefixes this resource owns: triggers using them are expected to be handled here.
  local ownPrefixes = { [resource.name] = true }
  for _, side in ipairs({ "client", "server" }) do
    for event in pairs(handled[side]) do
      local prefix = prefixOf(event)
      if prefix then ownPrefixes[prefix] = true end
    end
  end

  local reported = {}
  for _, trigger in ipairs(triggers) do
    if trigger.side ~= "local" and not isExternalEvent(trigger.event) then
      local receiving = trigger.side
      local key = receiving .. ":" .. trigger.event
      local onReceiver = handled[receiving][trigger.event]
      if onReceiver and not registered[receiving][trigger.event] and not reported[key] then
        reported[key] = true
        local at = firstHandler[receiving][trigger.event]
        at.ctx.report("FX800", at.node, "'" .. trigger.event .. "' is triggered over the network (line " .. trigger.node.line .. " of " .. trigger.ctx.path .. ") but is not registered with RegisterNetEvent: the runtime will drop it", {
          hint = "add RegisterNetEvent('" .. trigger.event .. "') on the " .. receiving .. " side",
        })
      elseif not onReceiver and not registered[receiving][trigger.event] and not reported[key] and not dynamicHandlers then
        local prefix = prefixOf(trigger.event)
        if prefix and ownPrefixes[prefix] then
          reported[key] = true
          local finder = Text.suggester(trigger.event)
          for event in pairs(handled[receiving]) do finder.offer(event) end
          trigger.ctx.report("FX801", trigger.node, "nothing handles '" .. trigger.event .. "' on the " .. receiving .. " side of this resource", {
            hint = finder.best and ("did you mean '" .. finder.best .. "'?") or nil,
            confidence = finder.best and "high" or "medium",
          })
        end
      end
    end
  end
end

return EventRules
