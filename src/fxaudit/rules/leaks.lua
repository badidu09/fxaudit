--- FX6xx: resources that pile up in memory or stay behind after a restart.
local Ast = require("fxaudit.ast")

local Leaks = {}

local HANDLER_REGISTRARS = {
  AddEventHandler = true, RegisterNetEvent = true, RegisterCommand = true,
  RegisterNUICallback = true, AddStateBagChangeHandler = true,
}

local STREAMING_PAIRS = {
  RequestModel = { "SetModelAsNoLongerNeeded" },
  RequestAnimDict = { "RemoveAnimDict" },
  RequestAnimSet = { "RemoveAnimSet" },
  RequestNamedPtfxAsset = { "RemoveNamedPtfxAsset" },
  RequestStreamedTextureDict = { "SetStreamedTextureDictAsNoLongerNeeded" },
  RequestScaleformMovie = { "SetScaleformMovieAsNoLongerNeeded" },
  RequestWeaponAsset = { "RemoveWeaponAsset" },
}

local CREATES_WORLD_OBJECT = {
  AddBlipForCoord = true, AddBlipForEntity = true, AddBlipForRadius = true, AddBlipForArea = true,
  CreateObject = true, CreateObjectNoOffset = true, CreatePed = true, CreateVehicle = true,
}

local PLAYER_KEY_NAMES = { source = true, src = true, _source = true, playerId = true, playerSrc = true, playerid = true }

--- Finds handlers registered in loops or in other handlers.
local function checkRegistrations(ctx)
  local loopDepth, whileDepth, handlerDepth = 0, 0, 0
  local eventHandlers = {}

  Ast.walk(ctx.chunk, function(node)
    if node.type == "Call" and (Ast.path(node.func) == "AddEventHandler" or Ast.path(node.func) == "RegisterNetEvent") then
      for _, arg in ipairs(node.args) do
        if arg.type == "Function" then eventHandlers[arg] = true end
      end
    end
  end)

  --- Loop depth is per function: a callback in a loop starts its own context.
  local stack = {}
  Ast.walk(ctx.chunk, function(node)
    local kind = node.type
    if kind == "Function" then
      stack[#stack + 1] = { loopDepth, whileDepth }
      loopDepth, whileDepth = 0, 0
      if eventHandlers[node] then handlerDepth = handlerDepth + 1 end
    elseif kind == "While" or kind == "Repeat" then
      loopDepth, whileDepth = loopDepth + 1, whileDepth + 1
    elseif kind == "NumFor" or kind == "GenFor" then
      loopDepth = loopDepth + 1
    elseif kind == "Call" then
      local path = Ast.path(node.func)
      if path and HANDLER_REGISTRARS[path] then
        local first = node.args[1] and Ast.unparen(node.args[1])
        local literal = first and first.type == "String"
        -- A `for` over a list with computed names is a single registration per item;
        -- a fixed name, or a `while`, registers the same thing again and again.
        if loopDepth > 0 and (literal or whileDepth > 0) then
          ctx.report("FX600", node, path .. " is called in a loop: registrations pile up and are never removed", {
            hint = "register once, outside the loop",
          })
        elseif loopDepth == 0 and handlerDepth > 0 and path ~= "RegisterNetEvent" then
          ctx.report("FX601", node, path .. " is called inside an event handler: one more registration each time the event fires", {
            hint = "register once at the top level; or remove it with RemoveEventHandler",
          })
        end
      elseif (path == "CreateThread" or path == "Citizen.CreateThread") and whileDepth > 0 then
        ctx.report("FX602", node, "a thread is created at each iteration", {
          hint = "use one thread handling every item",
          confidence = "medium",
        })
      end
    end
  end, function(node)
    local kind = node.type
    if kind == "Function" then
      local saved = table.remove(stack)
      loopDepth, whileDepth = saved[1], saved[2]
      if eventHandlers[node] then handlerDepth = handlerDepth - 1 end
    elseif kind == "While" or kind == "Repeat" then
      loopDepth, whileDepth = loopDepth - 1, whileDepth - 1
    elseif kind == "NumFor" or kind == "GenFor" then
      loopDepth = loopDepth - 1
    end
  end)
end

--- Names local aliases of `source`: `local src = source`.
local function isPlayerKey(expr)
  expr = Ast.unparen(expr)
  if expr.type == "Name" then return PLAYER_KEY_NAMES[expr.name] or false end
  if expr.type == "Index" and expr.dotted then return expr.name == "source" end
  return false
end

--- A table is a long-lived player table when it outlives the function writing to it.
local function longLivedTableName(target)
  local object = Ast.unparen(target.object)
  if object.type ~= "Name" then return nil end
  if not object.var or object.var.func.depth == 0 then return object.name end
  return nil
end

local function checkPlayerTables(resource)
  for _, ctx in ipairs(resource.files) do
    if ctx.side == "server" then
      local written, cleaned = {}, {}
      Ast.walk(ctx.chunk, function(node)
        if node.type == "Assign" then
          for i, target in ipairs(node.targets) do
            if target.type == "Index" and not target.dotted then
              local name = longLivedTableName(target)
              if name then
                local value = node.values[i] and Ast.unparen(node.values[i])
                -- `count > 0 and count or nil` also clears the entry.
                local mayClear = value and (value.type == "Nil"
                  or (value.type == "Binop" and value.op == "or" and Ast.unparen(value.right).type == "Nil"))
                if mayClear then
                  cleaned[name] = true
                elseif isPlayerKey(target.key) and not written[name] then
                  written[name] = target
                end
              end
            elseif target.type == "Name" then
              -- Replacing the whole table also frees what it held.
              cleaned[target.name] = true
            end
          end
        elseif node.type == "Call" then
          local path = Ast.path(node.func)
          if path == "table.wipe" or path == "table.remove" then
            local arg = node.args[1] and Ast.unparen(node.args[1])
            if arg and arg.type == "Name" then cleaned[arg.name] = true end
          end
        end
      end)
      for name, target in pairs(written) do
        if not cleaned[name] then
          ctx.report("FX603", target, "'" .. name .. "' is indexed by player and never cleaned: it grows with every connection", {
            hint = "clear the entry in AddEventHandler('playerDropped', ...)",
            confidence = "medium",
          })
        end
      end
    end
  end
end

--- Whole-resource request/release balance: the release is often in a helper elsewhere.
local function checkBalance(resource)
  local calls = {}
  local first = {}
  local hasStopHandler = false

  for _, ctx in ipairs(resource.files) do
    Ast.walk(ctx.chunk, function(node)
      if node.type == "Call" then
        local path = Ast.path(node.func)
        if path then
          -- A helper requesting whatever its caller passes leaves the release to that caller.
          local firstArg = node.args[1] and Ast.unparen(node.args[1])
          local isWrapper = STREAMING_PAIRS[path] and firstArg and firstArg.type == "Name"
            and firstArg.var and firstArg.var.kind == "param"
          if not isWrapper then
            calls[path] = true
            if not first[path] then first[path] = { ctx = ctx, node = node } end
          end
          if path == "AddEventHandler" then
            local arg = node.args[1] and Ast.unparen(node.args[1])
            if arg and arg.type == "String" and arg.value == "onResourceStop" then hasStopHandler = true end
          elseif path == "SetNuiFocus" and node.args[1] then
            local arg = Ast.unparen(node.args[1])
            if arg.type == "True" then
              calls["__focusOn"] = true
              first["__focusOn"] = first["__focusOn"] or { ctx = ctx, node = node }
            elseif arg.type == "False" or arg.type == "Name" or arg.type == "Unop" then
              calls["__focusOff"] = true
            end
          end
        end
      end
    end)
  end

  for request, releases in pairs(STREAMING_PAIRS) do
    if calls[request] then
      local released = false
      for _, release in ipairs(releases) do
        if calls[release] then released = true end
      end
      if not released then
        local at = first[request]
        at.ctx.report("FX604", at.node, request .. " is called, but this resource never calls " .. releases[1], {
          hint = "release the asset when it is no longer used, or memory stays reserved",
        })
      end
    end
  end

  if calls.CreateDui and not calls.DestroyDui then
    local at = first.CreateDui
    at.ctx.report("FX605", at.node, "CreateDui is called, but this resource never calls DestroyDui")
  end

  if calls["__focusOn"] and not calls["__focusOff"] then
    local at = first["__focusOn"]
    at.ctx.report("FX607", at.node, "SetNuiFocus(true, ...) is called, but focus is never released", {
      hint = "call SetNuiFocus(false, false) when closing the interface, and in onResourceStop",
    })
  end

  if not hasStopHandler then
    for name in pairs(CREATES_WORLD_OBJECT) do
      local at = first[name]
      if at and at.ctx.side == "client" then
        at.ctx.report("FX606", at.node, name .. " is used without any onResourceStop cleanup in this resource", {
          hint = "delete what you created in AddEventHandler('onResourceStop', ...)",
          confidence = "medium",
        })
        break
      end
    end
  end
end

function Leaks.checkFile(ctx)
  checkRegistrations(ctx)
end

function Leaks.checkResource(resource)
  checkPlayerTables(resource)
  checkBalance(resource)
end

return Leaks
