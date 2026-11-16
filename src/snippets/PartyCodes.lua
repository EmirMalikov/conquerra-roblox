--[[
	EXCERPT from server/Main.lua (lines 35–127 of 724) — not a complete module.

	"Play with friends": a 6-character code points to a reserved (private) server. The code → access code
	mapping lives in a MemoryStore hash map for 12 hours. The host and friends teleport there with the code
	in TeleportData; the reserved server starts in a Lobby state and waits for the host to press START.
	A Roblox invite carries the code as LaunchData, so an invited friend is forwarded straight to the lobby.

	Context provided by the rest of Main.lua: G (Game), send(), RunService, TeleportService, MemoryStoreService.
]]

---------------------------------------------------------------- игра с друзьями: коды лобби (как «Your code» / «Friend's code» в браузере)
-- Код → зарезервированный (приватный) сервер в MemoryStore. Хост и друзья телепортируются
-- туда, там матч ждёт кнопку START хоста. Телепорты работают только в опубликованной игре.
local parties
pcall(function() parties = MemoryStoreService:GetHashMap("ConquerraParties_v1") end)
local PARTY_TTL = 12 * 3600
local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local myCodes = {}     -- [UserId] = код лобби игрока, созданный на этом сервере
local function newCode()
	local s = ""
	for _ = 1, 6 do
		local k = math.random(1, #CODE_CHARS)
		s ..= CODE_CHARS:sub(k, k)
	end
	return s
end
local function cleanCode(c)
	if type(c) ~= "string" then return nil end
	c = c:upper():gsub("[^%w]", "")
	if #c ~= 6 then return nil end
	return c
end
-- сервер сам приватное лобби? (зарезервированный сервер: есть PrivateServerId, нет владельца)
if game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then
	G.Private = { Code = "", Host = 0, Mode = "team" }
end

local function partyCreate(plr)
	if G.Private and G.Private.Host == plr.UserId and G.Private.Code ~= "" then return G.Private.Code end
	if myCodes[plr.UserId] then return myCodes[plr.UserId] end
	if RunService:IsStudio() then
		-- в Studio телепортов нет: этот сервер сам становится приватным лобби (для проверки)
		local code = newCode()
		G.Private = { Code = code, Host = plr.UserId, Mode = "team", Studio = true }
		myCodes[plr.UserId] = code
		return code
	end
	if not parties then return nil, "Friends lobbies are unavailable right now" end
	local ok, access = pcall(TeleportService.ReserveServer, TeleportService, game.PlaceId)
	if not ok or not access then return nil, "Couldn't make a code. Try again." end
	for _ = 1, 6 do
		local code = newCode()
		local okGet, existing = pcall(function() return parties:GetAsync(code) end)
		if okGet and existing == nil then
			local okSet = pcall(function() parties:SetAsync(code, { A = access, H = plr.UserId }, PARTY_TTL) end)
			if okSet then
				myCodes[plr.UserId] = code
				return code
			end
		end
	end
	return nil, "Couldn't make a code. Try again."
end

local function partyTeleport(plr, code)
	if G.Private and G.Private.Code == code then return false, "You're already in this lobby" end
	if RunService:IsStudio() then return false, "Joining by code works in the published game (not in Studio)" end
	if not parties then return false, "Friends lobbies are unavailable right now" end
	local ok, data = pcall(function() return parties:GetAsync(code) end)
	if not ok then return false, "Couldn't reach the lobby. Try again." end
	if type(data) ~= "table" or not data.A then return false, "No lobby with code " .. code end
	local opts = Instance.new("TeleportOptions")
	opts.ReservedServerAccessCode = data.A
	opts:SetTeleportData({ Party = code, Host = data.H })
	local okT, err = pcall(function() TeleportService:TeleportAsync(game.PlaceId, { plr }, opts) end)
	if not okT then return false, "Teleport failed: " .. tostring(err) end
	return true
end

-- данные входа: код лобби из телепорта или из приглашения друга (LaunchData)
local function applyJoinData(plr, jd)
	if type(jd) ~= "table" then return end
	local td = jd.TeleportData
	if G.Private and type(td) == "table" and cleanCode(td.Party) then
		if G.Private.Code == "" then G.Private.Code = cleanCode(td.Party) end
		if G.Private.Host == 0 and tonumber(td.Host) then G.Private.Host = tonumber(td.Host) end
	end
	-- пришёл по приглашению с кодом: сразу в лобби друга
	local launch = cleanCode(jd.LaunchData)
	if launch and not (G.Private and G.Private.Code == launch) then
		task.delay(2, function()
			if not plr.Parent then return end
			send(plr, "Note", { Text = "\u{1F465} Joining your friend's lobby " .. launch .. "…", Kind = "good" })
			local okT, msg = partyTeleport(plr, launch)
			if not okT then send(plr, "Note", { Text = msg, Kind = "warn" }) end
		end)
	end
end
local function onJoinData(plr)
	local ok, jd = pcall(function() return plr:GetJoinData() end)
	if ok then applyJoinData(plr, jd) end
end
