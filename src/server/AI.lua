--[[
	AI — поведение стран (nation) и «племён» (bot).
	Каждые 1–2.5 с: строить (только страны) → если войск достаточно: сначала ничья земля,
	потом самый слабый сосед, а без соседей по суше — корабль к чужому берегу.
]]
local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Conquerra").Config)

local AI = {}
local rng = Random.new()

local function borderList(P)
	local list = {}
	for t in pairs(P.Border) do list[#list + 1] = t end
	return list
end

-- случайная своя клетка недалеко от центра страны
local function innerTile(G, P)
	local cx, cy = G.LabelPoint(P)
	if not cx then return end
	local spread = math.clamp(math.floor(math.sqrt(P.Tiles) * 0.6), 2, 30)
	for _ = 1, 25 do
		local x, y = cx + rng:NextInteger(-spread, spread), cy + rng:NextInteger(-spread, spread)
		if x >= 0 and x < G.W and y >= 0 and y < G.H then
			local i = y * G.W + x
			if G.Own(i) == P.Id and not P.Border[i] then return i end
		end
	end
end

local function tryBuild(G, P, list)
	local city = Config.Building("City")
	local want
	-- порядок как у стран в браузере: первый город → порт (торговля) → заводы и ещё города → флот и оборона
	if P.Built.City < 1 then want = "City"
	elseif P.Built.Port < 1 and rng:NextNumber() < 0.7 then want = "Port"
	elseif P.Built.City < 1 + P.Tiles // 2500 and P.Built.City <= P.Built.Port + P.Built.Factory + 1 then want = "City"
	-- большие богатые страны ставят ПВО (одна на ~2500 клеток)
	elseif P.Tiles > 2500 and (P.Built.SAM or 0) < P.Tiles // 2500 and P.Gold > 2000000 then want = "SAM"
	-- порты — главный доход (торговля), военные корабли стерегут море
	elseif P.Built.Port < 1 + P.Tiles // 1500 and P.Built.Port <= P.Built.City and rng:NextNumber() < 0.5 then want = "Port"
	elseif P.Built.Port > 0 and P.Tiles > 300 and (P.Built.Warship or 0) < math.min(3, P.Tiles // 700) and rng:NextNumber() < 0.35 then want = "Warship"
	elseif P.Built.Factory < P.Built.City then want = "Factory"
	elseif rng:NextNumber() < 0.3 then want = "Defense"
	elseif rng:NextNumber() < 0.3 then want = "Port"
	else want = "City" end
	local def = Config.Building(want) or city
	if P.Gold < Config.BuildCost(def, P.Built) then return end
	local tile
	if want == "Warship" then
		tile = G.SeaNearPort(P)
	elseif want == "Defense" or want == "Port" then
		for _ = 1, 30 do
			local b = list[rng:NextInteger(1, #list)]
			if want == "Defense" or G.IsCoast(b) then tile = b break end
		end
	else
		tile = innerTile(G, P)
	end
	if tile then G.Build(P, want, tile) end
end

-- цель для десанта: прибрежная клетка случайной живой страны (или ничьего берега)
local function boatTarget(G, P)
	local others = {}
	for _, Q in pairs(G.Players) do
		if Q ~= P and Q.Alive and Q.Tiles > 0 then table.insert(others, Q) end
	end
	for _ = 1, 6 do
		if #others == 0 then break end
		local Q = others[rng:NextInteger(1, #others)]
		local list = borderList(Q)
		for _ = 1, math.min(40, #list) do
			local t = list[rng:NextInteger(1, #list)]
			if G.IsCoast(t) then return t end
		end
	end
	-- ничьи острова
	for _ = 1, 60 do
		local i = rng:NextInteger(0, G.N - 1)
		if G.IsCoast(i) and G.Own(i) == 0 then return i end
	end
end

function AI.Think(G, P)
	local cfg = Config.AI[P.Kind] or Config.AI.bot
	local list = borderList(P)
	if #list == 0 then return end
	if cfg.Builds and P.Tiles > 25 then tryBuild(G, P, list) end
	if #P.Attacks >= 2 then return end
	if P.Troops < P.Max * cfg.AttackAt then return end

	-- смотрим, с кем граничим
	local neutral = false
	local enemies = {}
	for _ = 1, math.min(#list, 220) do
		local b = list[rng:NextInteger(1, #list)]
		for k = 0, 3 do
			local n = G.Nb(b, k)
			if n >= 0 and G.IsLand(n) then
				local o = G.Own(n)
				if o == 0 then neutral = true
				elseif o ~= P.Id then enemies[o] = (enemies[o] or 0) + 1 end
			end
		end
	end
	if neutral and rng:NextNumber() < 0.85 then
		G.StartAttack(P, 0, math.floor(P.Troops * cfg.NeutralRatio))
		return
	end
	-- мирное время в начале матча: страны только заселяют ничью землю
	if G.Elapsed < Config.AI.PeaceTime then return end
	local best, bestScore
	for id, cnt in pairs(enemies) do
		local D = G.Players[id]
		-- пока рядом есть ничья земля, нападаем только при большом перевесе
		if D and neutral and P.Troops < D.Troops * 2.5 then D = nil end
		if D and D.Alive then
			local score = D.Troops / math.max(1, P.Troops) - cnt * 0.002 + rng:NextNumber(0, 0.35)
			if not bestScore or score < bestScore then best, bestScore = D, score end
		end
	end
	-- иногда десант даже при соседях по суше (флот делает карту живой)
	if P.BoatCount == 0 and P.Troops > P.Max * 0.6 and rng:NextNumber() < cfg.BoatChance * 0.25 then
		local t = boatTarget(G, P)
		if t then G.LaunchBoat(P, t, math.floor(P.Troops * 0.3)) return end
	end
	if best then
		local send = math.floor(P.Troops * cfg.EnemyRatio)
		if send > best.Troops * 0.35 or rng:NextNumber() < 0.2 then
			G.StartAttack(P, best.Id, send)
		end
		return
	end
	-- соседей по суше нет: десант к чужому берегу (можно несколько кораблей)
	if P.BoatCount < Config.Boat.Max and rng:NextNumber() < cfg.BoatChance * 2 then
		local t = boatTarget(G, P)
		if t then G.LaunchBoat(P, t, math.floor(P.Troops * 0.4)) end
	end
end

return AI
