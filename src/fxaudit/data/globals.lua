--- Names available to FiveM scripts without any declaration, and the fields of
-- well-known libraries (used to detect typos such as `string.fromat`).

local function set(words)
  local out = {}
  for word in words:gmatch("%S+") do out[word] = true end
  return out
end

local Globals = {}

Globals.lua = set([[
  _G _VERSION _ENV assert collectgarbage dofile error getmetatable ipairs load loadfile next
  pairs pcall print rawequal rawget rawlen rawset require select setmetatable tonumber
  tostring type warn xpcall coroutine debug io math os package string table utf8
]])

-- Provided by the CitizenFX Lua runtime and scheduler on both sides.
Globals.shared = set([[
  Citizen CreateThread CreateThreadNow Wait SetTimeout ClearTimeout Await
  AddEventHandler RemoveEventHandler RegisterNetEvent RegisterServerEvent TriggerEvent
  exports json msgpack promise Entity Player GlobalState
  vector2 vector3 vector4 vec vec2 vec3 vec4 quat mat mat2 mat3 mat4 glm
  tovector2 tovector3 tovector4 toquat
  dot cross normalize length distance mix clamp
  AddStateBagChangeHandler RemoveStateBagChangeHandler NewStateBag
  GetCurrentResourceName LoadResourceFile IsDuplicityVersion
  FormatStackTrace
  Log
]])

Globals.client = set([[
  LocalPlayer TriggerServerEvent TriggerLatentServerEvent RegisterNUICallback SendNUIMessage
  RegisterCommand
]])

Globals.server = set([[
  source TriggerClientEvent TriggerLatentClientEvent GetPlayers GetPlayerIdentifiers
  GetPlayerTokens PerformHttpRequest PerformHttpRequestAwait RegisterCommand
  GetPlayerIdentifierByType GetAllPeds GetAllVehicles GetAllObjects
]])

--- Globals brought by a `@resource/file` import when that resource is not on disk.
Globals.imports = {
  ["ox_lib/init.lua"] = { "lib", "cache", "locale", "require", "qbx" },
  ["oxmysql/lib/MySQL.lua"] = { "MySQL" },
  ["es_extended/imports.lua"] = { "ESX", "Core" },
  ["es_extended/locale.lua"] = { "Locale", "_U", "_" },
  ["qb-core/shared/locale.lua"] = { "Locale", "Lang" },
  ["qbx_core/modules/lib.lua"] = { "qbx" },
  ["qbx_core/modules/playerdata.lua"] = { "QBX" },
  ["ox_core/lib/init.lua"] = { "Ox" },
}

Globals.libraries = {
  string = set([[byte char dump find format gmatch gsub len lower match pack packsize rep reverse sub
    unpack upper]]),
  table = set("concat insert move pack remove sort unpack"),
  math = set([[abs acos asin atan ceil cos deg exp floor fmod huge log max maxinteger min mininteger
    modf pi rad random randomseed sin sqrt tan tointeger type ult]]),
  coroutine = set("close create isyieldable resume running status wrap yield"),
  utf8 = set("char charpattern codepoint codes len offset"),
  os = set("clock date difftime execute exit getenv remove rename setlocale time tmpname"),
  io = set("close flush input lines open output popen read stderr stdin stdout tmpfile type write"),
  json = set("encode decode null use_lpeg"),
  Citizen = set([[Await CreateThread CreateThreadNow Wait SetTimeout ClearTimeout InvokeNative
    Trace ResultAsInteger ResultAsFloat ResultAsString ResultAsVector ResultAsObject
    ResultAsLong PointerValueInt PointerValueFloat PointerValueVector PointerValueIntInitialized
    PointerValueFloatInitialized ReturnResultAnyway SubmitBoundaryStart SubmitBoundaryEnd
    GetFunctionReference]]),
}

return Globals
