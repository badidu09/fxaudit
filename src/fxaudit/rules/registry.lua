--- Catalog of every diagnostic fxaudit can emit.
-- Ranges: FX1 syntax, FX2 variables, FX3 correctness, FX4 security,
-- FX5 performance, FX6 leaks, FX7 manifest, FX8 events.

local Registry = { rules = {}, order = {} }

Registry.SEVERITIES = { "critical", "high", "medium", "low", "info" }
Registry.SEVERITY_RANK = { critical = 5, high = 4, medium = 3, low = 2, info = 1 }

local function rule(id, name, severity, category, description)
  Registry.rules[id] = { id = id, name = name, severity = severity, category = category, description = description }
  Registry.order[#Registry.order + 1] = id
end

-- Syntax
rule("FX100", "syntax-error", "critical", "syntax", "The file does not compile: the whole script fails to load.")
rule("FX101", "invalid-break", "critical", "syntax", "'break' outside a loop does not compile.")
rule("FX102", "invalid-vararg", "critical", "syntax", "'...' outside a vararg function does not compile.")
rule("FX103", "invalid-goto", "critical", "syntax", "A goto targets a label that is not visible, or a label is defined twice.")
rule("FX104", "const-assign", "critical", "syntax", "Assigning to a <const> or <close> variable does not compile.")
rule("FX105", "else-if", "medium", "syntax", "'else if' opens a nested 'if' needing its own 'end'; 'elseif' was probably meant.")

-- Variables
rule("FX200", "undefined-global", "high", "variables", "A global is read but never defined by this resource, Lua, the runtime or the natives: it is nil at runtime.")
rule("FX201", "global-leak", "medium", "variables", "A function assigns a global without 'local': the value leaks into the shared environment of the resource and can collide with other files.")
rule("FX202", "needless-global", "low", "variables", "A top-level global is only used in its own file: it should be local (locals are also faster).")
rule("FX203", "unused-local", "low", "variables", "A local variable is declared and never used.")
rule("FX204", "unused-param", "info", "variables", "A trailing function parameter is never used.")
rule("FX205", "unused-function", "low", "variables", "A local function is never called.")
rule("FX206", "assigned-never-read", "low", "variables", "A local is assigned but its value is never read.")
rule("FX207", "shadowed-variable", "info", "variables", "A local hides a variable of an outer scope with the same name.")
rule("FX208", "redefined-local", "low", "variables", "A local is declared twice in the same scope.")
rule("FX209", "never-assigned", "medium", "variables", "A local is read but never receives a value: it is always nil.")
rule("FX210", "used-before-assignment", "medium", "variables", "A local is read before its first assignment.")
rule("FX211", "used-before-declaration", "high", "variables", "A name is used before its 'local' declaration: at this point it refers to a nil global.")
rule("FX212", "loop-variable-mutated", "low", "variables", "Assigning to a loop variable does not change the iteration and is rejected by newer Lua versions.")
rule("FX213", "builtin-overwritten", "medium", "variables", "A global overwrites a Lua, runtime or native function for the entire resource.")
rule("FX214", "unused-loop-variable", "info", "variables", "A loop variable is never used; name it '_'.")
rule("FX215", "wrong-side", "high", "variables", "This function only exists on the other side (client/server): calling it raises 'attempt to call a nil value'.")
rule("FX216", "unknown-library-field", "high", "variables", "A library field looks like a typo: it is nil at runtime.")

-- Correctness
rule("FX300", "self-comparison", "medium", "correctness", "An expression is compared with itself.")
rule("FX301", "duplicate-key", "medium", "correctness", "A table constructor sets the same key twice: the first value is lost.")
rule("FX302", "unreachable-code", "medium", "correctness", "This code can never run.")
rule("FX303", "empty-block", "low", "correctness", "A block is empty.")
rule("FX304", "assignment-mismatch", "medium", "correctness", "The number of values does not match the number of variables.")
rule("FX305", "constant-condition", "medium", "correctness", "A condition is always true or always false.")
rule("FX306", "too-many-arguments", "medium", "correctness", "A local function is called with more arguments than it declares.")
rule("FX307", "duplicate-condition", "medium", "correctness", "An 'elseif' repeats an earlier condition and can never run.")
rule("FX308", "self-assignment", "low", "correctness", "A variable is assigned to itself.")
rule("FX309", "zero-for-step", "high", "correctness", "A numeric 'for' with a step of 0 raises an error.")
rule("FX310", "invalid-literal-operation", "high", "correctness", "An operator is applied to a literal that cannot support it, which raises an error.")
rule("FX311", "not-precedence", "high", "correctness", "'not a == b' compares (not a) with b; 'a ~= b' or 'not (a == b)' was probably meant.")
rule("FX312", "remove-in-forward-loop", "medium", "correctness", "Removing elements while iterating forward skips the next element.")
rule("FX313", "or-literal-condition", "high", "correctness", "'x == a or \"b\"' is always truthy; 'x == a or x == \"b\"' was probably meant.")
rule("FX314", "format-arguments", "high", "correctness", "string.format receives fewer arguments than its format string requires.")

-- Security
rule("FX400", "unvalidated-net-input", "critical", "security", "A value sent by the client reaches a sensitive operation without validation: any cheater can call this event with arbitrary values.")
rule("FX401", "unguarded-reward", "high", "security", "A client-callable event changes the economy with no condition at all.")
rule("FX402", "source-after-yield", "high", "security", "'source' is read after a yield or inside a callback, when it may already refer to another player.")
rule("FX403", "dynamic-code", "high", "security", "Code is compiled from a non-constant string.")
rule("FX404", "remote-code-execution", "critical", "security", "Code downloaded from the network or sent by a client is executed: the classic FiveM backdoor.")
rule("FX405", "obfuscated-code", "high", "security", "The code is deliberately unreadable, a common way of hiding backdoors.")
rule("FX406", "known-malware", "critical", "security", "The code references an infrastructure known for FiveM backdoors.")
rule("FX407", "system-command", "high", "security", "The script tries to run operating system commands.")
rule("FX408", "exposed-secret", "critical", "security", "A webhook or key is hardcoded in a file downloaded by every player.")
rule("FX409", "hardcoded-secret", "medium", "security", "A secret is hardcoded in server code; a convar is safer.")
rule("FX410", "sql-injection", "critical", "security", "A SQL query is built by string concatenation; use parameters.")
rule("FX411", "client-supplied-identity", "high", "security", "A player id received from the client is used to act on a player without validation.")
rule("FX412", "client-supplied-value", "low", "security", "The client sends a price or amount to the server, which must recompute it on its side.")

-- Performance
rule("FX500", "loop-without-wait", "critical", "performance", "A 'while true' loop never yields: it freezes the game or the server.")
rule("FX501", "permanent-tick", "low", "performance", "A loop runs every frame permanently, at a cost for all players.")
rule("FX502", "get-player-ped-self", "info", "performance", "GetPlayerPed(-1) should be PlayerPedId().")
rule("FX503", "runtime-hash", "info", "performance", "GetHashKey on a constant string can be a compile-time `hash`.")
rule("FX504", "slow-distance-native", "low", "performance", "GetDistanceBetweenCoords and Vdist are slower than #(a - b).")
rule("FX505", "string-concat-in-loop", "low", "performance", "Repeated concatenation in a loop is quadratic; use table.concat.")
rule("FX506", "broadcast-in-tick", "medium", "performance", "An event is sent to every player in a fast loop, which floods the network.")
rule("FX507", "query-in-loop", "medium", "performance", "A SQL query runs at each iteration of a loop.")

-- Leaks
rule("FX600", "handler-in-loop", "high", "leaks", "An event handler is registered in a loop: handlers pile up and are never removed.")
rule("FX601", "handler-in-handler", "medium", "leaks", "A handler is registered each time an event fires, so it runs more and more often.")
rule("FX602", "thread-in-loop", "medium", "leaks", "A thread is created at each iteration of a 'while' loop.")
rule("FX603", "player-table-not-cleaned", "medium", "leaks", "A table is indexed by player and never cleaned: it grows with every connection.")
rule("FX604", "streaming-not-released", "low", "leaks", "A streaming asset is requested and never released by this resource.")
rule("FX605", "dui-not-destroyed", "medium", "leaks", "A DUI browser is created and never destroyed: each one is a browser instance kept in memory.")
rule("FX606", "no-stop-cleanup", "low", "leaks", "Blips or entities are created without an 'onResourceStop' cleanup: they stay behind after a restart.")
rule("FX607", "nui-focus-not-released", "medium", "leaks", "NUI focus is enabled and never disabled, which can leave the player stuck with a cursor.")

-- Manifest
rule("FX700", "missing-manifest", "high", "manifest", "The resource uses the abandoned __resource.lua, or has no manifest.")
rule("FX701", "missing-fx-version", "high", "manifest", "fx_version is missing or invalid.")
rule("FX702", "missing-game", "high", "manifest", "game or games is missing or invalid.")
rule("FX703", "file-not-found", "high", "manifest", "A file declared in the manifest does not exist.")
rule("FX704", "glob-no-match", "medium", "manifest", "A glob pattern of the manifest matches no file.")
rule("FX705", "ui-file-not-declared", "high", "manifest", "A NUI page or loading screen is not listed in 'files': clients will not receive it.")
rule("FX706", "missing-dependency", "medium", "manifest", "A declared dependency was not found in the scanned folders.")
rule("FX707", "orphan-script", "info", "manifest", "A Lua file is not referenced by the manifest: it never runs.")
rule("FX708", "deprecated-directive", "info", "manifest", "A manifest directive is deprecated.")
rule("FX709", "import-not-found", "high", "manifest", "A @resource/file import points to a file that does not exist in that resource.")
rule("FX710", "protected-file", "info", "manifest", "This file is escrow-protected or precompiled and was NOT analyzed: fxaudit says nothing about its safety.")
rule("FX711", "manifest-error", "high", "manifest", "The manifest has syntax errors or could not be read statically.")

-- Events
rule("FX800", "event-not-safe-for-net", "high", "events", "This event is triggered over the network but never registered with RegisterNetEvent on the receiving side.")
rule("FX801", "event-without-handler", "medium", "events", "This resource triggers one of its own events, but nothing handles it.")
rule("FX802", "deprecated-register", "info", "events", "RegisterServerEvent is an old alias of RegisterNetEvent.")
rule("FX803", "client-event-without-target", "high", "events", "TriggerClientEvent requires a target player as its second argument.")
rule("FX804", "exports-dot-call", "medium", "events", "An export is called with '.' instead of ':'.")
rule("FX805", "export-not-found", "high", "events", "The target resource does not define this export.")

function Registry.get(id) return Registry.rules[id] end

return Registry
