local price = 100

CreateThread(function()
  while true do
    local ped = GetPlayerPed(-1)
    position = GetEntityCoords(ped)
    if IsControlJustPressed(0, 38) then
      TriggerServerEvent('shop:buy', 'bread', price)
    end
    Citizen.Wiat(0)
    Wait(0)
  end
end)

RegisterCommand('shop', function()
  SetNuiFocus(true, true)
  DropPlayer(PlayerId(), 'bye')
end)
