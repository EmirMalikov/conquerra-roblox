--[[
	Game — серверная симуляция Conquerra (сервер — единственный источник правды).
	Клетки карты хранятся в buffer: владелец u16 на клетку (0 — ничья).
	Матч: Spawn (выбор старта) → Play → End (итоги) → новый матч.
	Атака: фронт клеток цели, соседних с территорией атакующего; каждый шаг захватывает часть фронта,
	пока хватает войск. Если цель за морем — корабль с десантом.
]]
local RS = game:GetService("ReplicatedStorage")
local Shared = RS:WaitForChild("Conquerra")
local Config = require(Shared.Config)
local MapData = require(Shared.MapData)

local G = {}
local W, H = MapData.W, MapData.H
local N = W * H
G.W, G.H, G.N = W, H, N

local terrain = MapData.Decode()
local owner = buffer.create(N * 2)
local LAND = buffer.create(N)     -- 1 = суша, которой можно владеть
local OCEAN = buffer.create(N)    -- 1 = океан (по нему ходят корабли)
local COAST = buffer.create(N)    -- 1 = суша у океана
local NB = buffer.create(N * 16)  -- 4 соседа (i32, -1 = нет)
G.Owner = owner

local totalLand = 0
for i = 0, N - 1 do
	local c = buffer.readu8(terrain, i)
	if c >= 4 then buffer.writeu8(LAND, i, 1); totalLand += 1 end
	if c == 0 or c == 2 then buffer.writeu8(OCEAN, i, 1) end
	local x = i % W
	buffer.writei32(NB, i * 16, i >= W and i - W or -1)
	buffer.writei32(NB, i * 16 + 4, i < N - W and i + W or -1)
	buffer.writei32(NB, i * 16 + 8, x > 0 and i - 1 or -1)
	buffer.writei32(NB, i * 16 + 12, x < W - 1 and i + 1 or -1)
end
for i = 0, N - 1 do
	if buffer.readu8(LAND, i) == 1 then
		for k = 0, 3 do
			local n = buffer.readi32(NB, i * 16 + k * 4)
			if n >= 0 and buffer.readu8(OCEAN, n) == 1 then buffer.writeu8(COAST, i, 1) break end
		end
	end
end
G.TotalLand = totalLand

local function own(i) return buffer.readu16(owner, i * 2) end
local function isLand(i) return buffer.readu8(LAND, i) == 1 end
local function nb(i, k) return buffer.readi32(NB, i * 16 + k * 4) end
G.Own, G.IsLand, G.Nb = own, isLand, nb
function G.IsCoast(i) return buffer.readu8(COAST, i) == 1 end
function G.IsOcean(i) return buffer.readu8(OCEAN, i) == 1 end
function G.Terrain(i) return buffer.readu8(terrain, i) end

-- состояние
G.Players = {}       -- id -> игрок
G.ByUser = {}        -- Player -> игрок
G.Buildings = {}     -- id -> постройка
G.BuildAt = {}       -- клетка -> постройка
G.Boats = {}         -- id -> корабль
G.Changed = {}       -- клетки, сменившие владельца с прошлой рассылки
G.BuildEvents = {}   -- события построек для рассылки
G.State = "Spawn"
G.Timer = Config.SpawnPhase
G.Elapsed = 0
G.Match = 0
G.Winner = nil
G.OnNote = nil       -- function(target Player|nil, text, kind) — задаётся в Main
G.OnEnd = nil
G.OnEliminated = nil

local nextId = 1
local nextBuild = 1
local nextBoat = 1
local rng = Random.new()

local function note(P, text, kind)
	if G.OnNote then G.OnNote(P, text, kind) end
end

---------------------------------------------------------------- приватное лобби и команда друзей (как приватные лобби браузерной игры)
-- G.Private = nil (публичный сервер) или { Code, Host = UserId хоста, Mode = "team" | "ffa" }.
-- В приватном лобби матч ждёт, пока хост нажмёт START; в режиме team все игроки — одна команда
-- против стран ИИ: не атакуют друг друга, корабли не стреляют по своим, победа общая.
G.Private = nil
function G.IsTeam()
	return G.Private ~= nil and G.Private.Mode == "team"
end
-- союзники по команде (id игроков)
function G.Teammates(a, b)
	if not G.IsTeam() or a == b or a == 0 or b == 0 then return false end
	local A, B = G.Players[a], G.Players[b]
	return A ~= nil and B ~= nil and A.TeamFriend == true and B.TeamFriend == true
end
function G.StartPrivate()
	if G.State ~= "Lobby" then return false end
	G.State = "Spawn"
	G.Timer = Config.SpawnPhase
	for _, P in pairs(G.Players) do
		if P.Kind == "human" then P.TeamFriend = true end
	end
	return true
end

---------------------------------------------------------------- игроки
local colorIdx = 0
local function nextColor()
	colorIdx = colorIdx % #Config.Colors + 1
	local c = Config.Colors[colorIdx]
	return Color3.fromRGB(c[1], c[2], c[3])
end

function G.NewPlayer(name, kind, userPlayer)
	local P = {
		Id = nextId, Name = name, Kind = kind, User = userPlayer, UserId = userPlayer and userPlayer.UserId or 0,
		Color = nextColor(), Troops = 0, Gold = Config.StartGold, Tiles = 0, Border = {}, SumX = 0, SumY = 0,
		Alive = false, Spawned = false, InMatch = kind ~= "human", Ratio = Config.DefaultRatio,
		Attacks = {}, BoatCount = 0, Built = { City = 0, Factory = 0, Port = 0, Defense = 0, SAM = 0, Warship = 0 }, Defenses = {},
		NextThink = os.clock() + rng:NextNumber(0, 2), LabelTile = nil, Max = 1, TRate = 0, GRate = 0,
		SpawnTiles = {}, Kills = 0, PeakTiles = 0,
		VIP = false, BombsUsed = 0, NextBomb = 0, AttackedBy = {},
	}
	nextId += 1
	G.Players[P.Id] = P
	if userPlayer then G.ByUser[userPlayer] = P end
	return P
end

---------------------------------------------------------------- смена владельца клетки
local function refreshBorder(j)
	local o = own(j)
	if o == 0 then return end
	local P = G.Players[o]
	if not P then return end
	local isB = false
	for k = 0, 3 do
		local n = nb(j, k)
		if n < 0 or own(n) ~= o then isB = true break end
	end
	if isB then P.Border[j] = true else P.Border[j] = nil end
end

local function setOwner(i, newId)
	local old = own(i)
	if old == newId then return end
	buffer.writeu16(owner, i * 2, newId)
	local x, y = i % W, i // W
	if old ~= 0 then
		local O = G.Players[old]
		if O then
			O.Tiles -= 1; O.SumX -= x; O.SumY -= y; O.Border[i] = nil
		end
	end
	if newId ~= 0 then
		local P = G.Players[newId]
		P.Tiles += 1; P.SumX += x; P.SumY += y
		if P.Tiles > P.PeakTiles then P.PeakTiles = P.Tiles end
	end
	refreshBorder(i)
	for k = 0, 3 do
		local n = nb(i, k)
		if n >= 0 then refreshBorder(n) end
	end
	-- постройка на клетке переходит захватчику (или разрушается, если земля ничья)
	local b = G.BuildAt[i]
	if b then G.TransferBuilding(b, newId) end
	table.insert(G.Changed, i)
end
G.SetOwner = setOwner

---------------------------------------------------------------- постройки
function G.TransferBuilding(b, newId)
	local old = G.Players[b.Owner]
	if old then
		old.Built[b.Type] = math.max(0, old.Built[b.Type] - 1)
		if b.Type == "Defense" then old.Defenses[b.Id] = nil end
	end
	if newId == 0 or not G.Players[newId] then
		G.Buildings[b.Id] = nil
		G.BuildAt[b.Tile] = nil
		table.insert(G.BuildEvents, { Op = "del", Id = b.Id })
		return
	end
	local P = G.Players[newId]
	b.Owner = newId
	P.Built[b.Type] += 1
	if b.Type == "Defense" then P.Defenses[b.Id] = b end
	table.insert(G.BuildEvents, { Op = "own", Id = b.Id, Owner = newId })
end

-- ближайший порт игрока к точке
local function nearestPort(ownerId, x, y)
	local best, bd
	for _, b in pairs(G.Buildings) do
		if b.Type == "Port" and b.Owner == ownerId then
			local d = (b.Tile % W - x) ^ 2 + (b.Tile // W - y) ^ 2
			if not bd or d < bd then best, bd = b, d end
		end
	end
	return best, bd
end
G.NearestPort = nearestPort

function G.CanBuild(P, typ, tile)
	local def = Config.Building(typ)
	if not def then return false, "Unknown building" end
	if G.State ~= "Play" then return false, "Wait for the match to start" end
	if not P.Alive then return false, "You are not in the match" end
	if not tile or tile < 0 or tile >= N then return false, "Pick a spot on the map" end
	local cost = Config.BuildCost(def, P.Built)
	if def.Naval then
		-- военный корабль: море рядом со своим портом, выходит из порта и патрулирует там
		if buffer.readu8(OCEAN, tile) ~= 1 then return false, "Warships go on the sea" end
		local port, d2 = nearestPort(P.Id, tile % W, tile // W)
		if not port then return false, "Build a port first" end
		if d2 > Config.Warship.PortRange ^ 2 then return false, "Too far from your ports" end
		if P.Gold < cost then return false, "Not enough gold" end
		return true, cost, port
	end
	if own(tile) ~= P.Id then return false, "Build on your own land" end
	if def.Coastal and not G.IsCoast(tile) then return false, "Ports must be on the coast" end
	if P.Gold < cost then return false, "Not enough gold" end
	local tx, ty = tile % W, tile // W
	for _, b in pairs(G.Buildings) do
		local bx, by = b.Tile % W, b.Tile // W
		if math.abs(bx - tx) < Config.BuildSpacing and math.abs(by - ty) < Config.BuildSpacing then return false, "Too close to another building" end
	end
	return true, cost
end

function G.Build(P, typ, tile)
	local ok, cost, port = G.CanBuild(P, typ, tile)
	if not ok then return false, cost end
	if typ == "Warship" then return G.LaunchWarship(P, tile, cost, port) end
	P.Gold -= cost
	local b = { Id = nextBuild, Type = typ, Tile = tile, Owner = P.Id }
	nextBuild += 1
	G.Buildings[b.Id] = b
	G.BuildAt[tile] = b
	P.Built[typ] += 1
	if typ == "Defense" then P.Defenses[b.Id] = b end
	table.insert(G.BuildEvents, { Op = "add", Id = b.Id, Type = typ, Tile = tile, Owner = P.Id })
	return true
end

-- есть ли рядом с клеткой оборонный пост владельца
local function defenseNear(D, t)
	if not D or not next(D.Defenses) then return false end
	local tx, ty = t % W, t // W
	local r = Config.DefenseRadius
	for _, b in pairs(D.Defenses) do
		local bx, by = b.Tile % W, b.Tile // W
		if (bx - tx) ^ 2 + (by - ty) ^ 2 <= r * r then return true end
	end
	return false
end

---------------------------------------------------------------- стоимость захвата (attackLogic браузерной игры)
-- большие страны атакуют и теряют землю дешевле (как largeTerritoryBonus)
local LOG_MID = math.log(300000)
local function bigBonus(tiles, depth)
	local x = math.log(math.max(1, tiles * Config.Troops.TileScale))
	return 1 - depth / (1 + math.exp(-2.5 * (x - LOG_MID)))
end
-- возвращает: потери атакующего, потери защитника, «цена» клетки по скорости (больше — медленнее)
local function attackCost(P, t, DP, attackTroops)
	local tt = Config.Terrain[buffer.readu8(terrain, t)] or Config.Terrain[4]
	local mag, cost = tt[1], tt[2]
	if DP and defenseNear(DP, t) then mag *= Config.DefenseLoss; cost *= Config.DefenseSlow end
	local A = Config.Attack
	if not DP then
		-- потери на клетку браузера × 4 клетки / 10 (показываемые единицы) = × 0.4
		local loss = mag / (P.Kind == "bot" and 10 or 5) * 0.4
		return loss, 0, math.clamp(2000 * cost / math.max(1, attackTroops * 10), 5, 100) / 2
	end
	-- перевес: вся армия защитника против отряда атаки
	local ratio = DP.Troops / math.max(1, attackTroops)
	local dens = DP.Troops * 10 / math.max(1, DP.Tiles * Config.Troops.TileScale)
	local bD = bigBonus(DP.Tiles, 0.3)
	local loss = mag * math.clamp(ratio, A.CheapestRatio, 2) * (A.LossBase * bigBonus(P.Tiles, 0.7) * bD + A.LossDensity * dens) * 0.4
	if P.Kind ~= "bot" and DP.Kind == "bot" then loss *= 0.7 end
	local speed = math.clamp(ratio, A.FastRatio, 7.5) * math.clamp(ratio / 20, 1, 50) / A.SpeedDivisor
	return loss, DP.Troops / math.max(1, DP.Tiles), speed * cost * bigBonus(P.Tiles, 0.73) * bD
end
G.AttackCost = attackCost

---------------------------------------------------------------- атаки
local function buildFront(A, P)
	A.Front, A.In = {}, {}
	local D = A.Def
	for b in pairs(P.Border) do
		for k = 0, 3 do
			local n = nb(b, k)
			if n >= 0 and not A.In[n] and own(n) == D and isLand(n) then
				A.In[n] = true
				table.insert(A.Front, n)
			end
		end
	end
end

local function endAttack(P, A)
	P.Troops += math.max(0, A.Troops)
	A.Troops = 0
	for k, a in ipairs(P.Attacks) do
		if a == A then table.remove(P.Attacks, k) break end
	end
end

-- отзыв армии с войны (как retreat в браузере): войска возвращаются, 25% теряется
function G.Retreat(P, defId)
	for k, A in ipairs(P.Attacks) do
		if A.Def == defId then
			table.remove(P.Attacks, k)
			local back = math.floor(math.max(0, A.Troops) * (1 - Config.Attack.RetreatLoss))
			P.Troops += back
			A.Troops = 0
			return true, back
		end
	end
	return false, "That attack is already over"
end

local warned = {}
function G.StartAttack(P, D, troops, fromTile)
	-- D: id защитника (0 = ничья земля)
	for _, a in ipairs(P.Attacks) do
		if a.Def == D then
			a.Troops += troops
			P.Troops -= troops
			buildFront(a, P)
			return true
		end
	end
	if #P.Attacks >= Config.Attack.MaxAttacks then return false, "Too many attacks at once" end
	local A = { Def = D, Troops = troops }
	if fromTile then
		A.Front, A.In = {}, {}
		for k = 0, 3 do
			local n = nb(fromTile, k)
			if n >= 0 and own(n) == D and isLand(n) and not A.In[n] then A.In[n] = true; table.insert(A.Front, n) end
		end
	else
		buildFront(A, P)
	end
	if #A.Front == 0 then return false, "No border with that territory" end
	P.Troops -= troops
	table.insert(P.Attacks, A)
	local DP = D ~= 0 and G.Players[D]
	if DP then DP.AttackedBy[P.Id] = os.clock() end
	if DP and DP.User then
		local key = P.Id .. ":" .. D
		if not warned[key] or os.clock() - warned[key] > 8 then
			warned[key] = os.clock()
			note(DP.User, P.Name .. " is attacking you!" .. G.RevengeHint(DP), "bad")
		end
	end
	return true
end

local function stepAttack(P, A)
	local D = A.Def
	local DP = D ~= 0 and G.Players[D] or nil
	if DP and not DP.Alive then DP = nil end
	local front = A.Front
	-- за шаг фронт продвигается на «бюджет» = длина фронта / 2 (клетка тут = 2 ряда браузерной карты);
	-- каждая захваченная клетка стоит свою цену по скорости (перевес в разы — дешевле и быстрее)
	A.Budget = math.min((A.Budget or 0) + #front / 2, #front * 5 + 250)
	local taken, tries = 0, 0
	local take = Config.Attack.MaxPerTick
	while taken < take and #front > 0 and tries < take * 6 do
		tries += 1
		-- аккуратный фронт: из нескольких случайных клеток берём ту, у которой больше своих соседей
		-- (дыры и заусенцы закрываются первыми, граница ровная, как в браузерной Conquerra)
		local r, bestAdj = rng:NextInteger(1, #front), -1
		for _ = 1, math.min(4, #front) do
			local q = rng:NextInteger(1, #front)
			local tq = front[q]
			local a = 0
			for k = 0, 3 do
				local n = nb(tq, k)
				if n >= 0 and own(n) == P.Id then a += 1 end
			end
			if a > bestAdj then r, bestAdj = q, a end
		end
		local t = front[r]
		local adj = 0
		if own(t) == D and isLand(t) then
			for k = 0, 3 do
				local n = nb(t, k)
				if n >= 0 and own(n) == P.Id then adj += 1 end
			end
		end
		local loss, dloss, rc
		if adj > 0 then
			loss, dloss, rc = attackCost(P, t, DP, A.Troops)
			if A.Budget < rc then break end   -- на этом шаге дальше не продвинулись
		end
		front[r] = front[#front]
		front[#front] = nil
		A.In[t] = nil
		if adj > 0 then
			do
				if A.Troops < loss then
					endAttack(P, A)
					return
				end
				A.Budget -= rc
				A.Troops -= loss
				if DP then DP.Troops = math.max(0, DP.Troops - dloss) end
				setOwner(t, P.Id)
				taken += 1
				for k = 0, 3 do
					local n = nb(t, k)
					if n >= 0 and not A.In[n] and own(n) == D and isLand(n) then
						A.In[n] = true
						table.insert(front, n)
					end
				end
			end
		end
	end
	if #front == 0 then endAttack(P, A) end
end

---------------------------------------------------------------- корабли
-- поиск пути по океану (BFS) от любой клетки воды у старта до воды у цели
local parent = buffer.create(N * 4)
local stamp = buffer.create(N * 4)
local stampId = 0
local function waterPath(startTiles, goalSet, limit)
	limit = limit or Config.Boat.MaxSearch
	stampId += 1
	local q = {}
	local head = 1
	for _, s in ipairs(startTiles) do
		if buffer.readi32(stamp, s * 4) ~= stampId then
			buffer.writei32(stamp, s * 4, stampId)
			buffer.writei32(parent, s * 4, -1)
			table.insert(q, s)
		end
	end
	while head <= #q and head < limit do
		local c = q[head]; head += 1
		if goalSet[c] then
			local path = {}
			local p = c
			while p >= 0 do table.insert(path, 1, p); p = buffer.readi32(parent, p * 4) end
			return path, c
		end
		for k = 0, 3 do
			local n = nb(c, k)
			if n >= 0 and buffer.readu8(OCEAN, n) == 1 and buffer.readi32(stamp, n * 4) ~= stampId then
				buffer.writei32(stamp, n * 4, stampId)
				buffer.writei32(parent, n * 4, c)
				table.insert(q, n)
			end
		end
	end
	return nil
end

-- ближайшая прибрежная клетка цели (не своя)
local function landingNear(P, tile)
	local tx, ty = tile % W, tile // W
	local R = Config.Boat.SearchRadius
	local best, bd
	for dy = -R, R do
		for dx = -R, R do
			local x, y = tx + dx, ty + dy
			if x >= 0 and x < W and y >= 0 and y < H then
				local i = y * W + x
				if buffer.readu8(COAST, i) == 1 and own(i) ~= P.Id then
					local d = dx * dx + dy * dy
					if not bd or d < bd then best, bd = i, d end
				end
			end
		end
	end
	return best
end

function G.LaunchBoat(P, tile, troops)
	if P.BoatCount >= Config.Boat.Max then return false, "All your boats are at sea" end
	local land = landingNear(P, tile)
	if not land then return false, "No coast to land on" end
	if G.Teammates(P.Id, own(land)) then return false, "That's your teammate's coast" end
	-- вода у своих берегов
	local starts = {}
	for b in pairs(P.Border) do
		if buffer.readu8(COAST, b) == 1 then
			for k = 0, 3 do
				local n = nb(b, k)
				if n >= 0 and buffer.readu8(OCEAN, n) == 1 then table.insert(starts, n) end
			end
		end
	end
	if #starts == 0 then return false, "You have no coast" end
	-- цели: вода возле места высадки
	local goals = {}
	local any = false
	for k = 0, 3 do
		local n = nb(land, k)
		if n >= 0 and buffer.readu8(OCEAN, n) == 1 then goals[n] = true; any = true end
	end
	if not any then return false, "No coast to land on" end
	local path = waterPath(starts, goals)
	if not path then return false, "No sea route" end
	table.insert(path, land)
	P.Troops -= troops
	P.BoatCount += 1
	local speed = Config.Boat.Speed * (P.Built.Port > 0 and Config.Boat.PortSpeed or 1)
	local B = { Id = nextBoat, Kind = "T", Owner = P.Id, Path = path, Pos = 1, Troops = troops, Speed = speed, Target = own(land) }
	nextBoat += 1
	G.Boats[B.Id] = B
	local DP = G.Players[B.Target]
	if DP then DP.AttackedBy[P.Id] = os.clock() end
	if DP and DP.User then note(DP.User, P.Name .. " is sending a boat to your coast!" .. G.RevengeHint(DP), "bad") end
	return true
end

-- отзыв десанта: корабль разворачивается домой, на своём берегу высаживается 75% войск
function G.BoatRetreat(P, id)
	local B = G.Boats[id]
	if not B or B.Kind ~= "T" or B.Owner ~= P.Id then return false, "That boat is gone" end
	if B.Retreat then return false, "The boat is already sailing home" end
	local k = math.clamp(math.floor(B.Pos), 1, math.max(1, #B.Path - 1))   -- последняя клетка пути — берег врага
	local path = {}
	for i = k, 1, -1 do table.insert(path, B.Path[i]) end
	if #path < 2 then table.insert(path, path[1]) end
	B.Path, B.Pos, B.Retreat = path, 1, true
	return true
end

local function stepBoats(dt)
	for id, B in pairs(G.Boats) do
		local P = G.Players[B.Owner]
		if B.Kind ~= "T" then
			-- торговые и военные корабли — в stepShips
		elseif not P or not P.Alive then
			G.Boats[id] = nil
		else
			B.Pos += B.Speed * dt
			if B.Pos >= #B.Path then
				G.Boats[id] = nil
				P.BoatCount = math.max(0, P.BoatCount - 1)
				if B.Retreat then
					P.Troops += math.floor(B.Troops * (1 - Config.Attack.RetreatLoss))
					continue
				end
				local land = B.Path[#B.Path]
				local D = own(land)
				if D == P.Id or G.Teammates(P.Id, D) then
					P.Troops += B.Troops
				else
					local DP = D ~= 0 and G.Players[D] or nil
					if DP and not DP.Alive then DP = nil end
					local cost, loss = attackCost(P, land, DP, B.Troops)
					if B.Troops >= cost then
						if DP then DP.Troops = math.max(0, DP.Troops - loss) end
						setOwner(land, P.Id)
						local rest = B.Troops - cost
						if rest > 1 then
							P.Troops += rest
							if not G.StartAttack(P, D, rest, land) then end
						end
					end
				end
			end
		end
	end
end

---------------------------------------------------------------- торговые и военные корабли (как TradeShip и Warship в браузерной игре)
-- Все корабли лежат в G.Boats: Kind "T" — десант, "S" — торговый, "W" — военный.
G.Shells = {}
G.OnShell = nil   -- function(info) выстрел военного корабля
G.OnSink = nil    -- function(info) корабль потоплен
local tradeCache = {}
local tradeClock, pathBudget = 0, 0
local noteAt = {}
-- уведомление не чаще раза в secs секунд (чтобы морские бои не спамили)
local function noteOnce(Q, key, text, kind, secs)
	if not Q or not Q.User then return end
	local k = Q.Id .. key
	if noteAt[k] and os.clock() - noteAt[k] < (secs or 6) then return end
	noteAt[k] = os.clock()
	note(Q.User, text, kind)
end

local function shipXY(B)
	local n = #B.Path
	local k = math.clamp(math.floor(B.Pos), 1, n)
	local a = B.Path[k]
	local b = B.Path[math.min(k + 1, n)]
	local f = math.clamp(B.Pos - k, 0, 1)
	local ax, ay, bx, by = a % W, a // W, b % W, b // W
	return ax + (bx - ax) * f, ay + (by - ay) * f
end
G.ShipXY = shipXY
local function shipTile(B) return B.Path[math.clamp(math.floor(B.Pos + 0.5), 1, #B.Path)] end

-- клетки океана вокруг клетки (у порта)
local function waterNear(tile, r)
	local out = {}
	local tx, ty = tile % W, tile // W
	for dy = -r, r do
		for dx = -r, r do
			local x, y = tx + dx, ty + dy
			if x >= 0 and x < W and y >= 0 and y < H then
				local i = y * W + x
				if buffer.readu8(OCEAN, i) == 1 then table.insert(out, i) end
			end
		end
	end
	return out
end
local function setOf(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end

-- случайная клетка моря возле своего порта (для ИИ)
function G.SeaNearPort(P)
	local ports = {}
	for _, b in pairs(G.Buildings) do if b.Type == "Port" and b.Owner == P.Id then table.insert(ports, b) end end
	if #ports == 0 then return end
	local port = ports[rng:NextInteger(1, #ports)]
	local list = waterNear(port.Tile, 6)
	if #list == 0 then return end
	return list[rng:NextInteger(1, #list)]
end

local function removeShip(B)
	G.Boats[B.Id] = nil
	local P = G.Players[B.Owner]
	if not P then return end
	if B.Kind == "T" then P.BoatCount = math.max(0, P.BoatCount - 1) end
	if B.Kind == "W" then P.Built.Warship = math.max(0, (P.Built.Warship or 0) - 1) end
end

local function pay(Q, g)
	if not Q or not Q.Alive then return end
	if Q.VIP then g *= 1 + Config.VIP.GoldBonus end
	Q.Gold += g
	Q.TradeIn = (Q.TradeIn or 0) + g
end

-- каждую секунду каждый порт с шансом отправляет торговый корабль в порт другой страны
local function spawnTrade()
	local ports = {}
	for _, b in pairs(G.Buildings) do
		local Q = b.Type == "Port" and G.Players[b.Owner]
		if Q and Q.Alive then table.insert(ports, b) end
	end
	if #ports < 2 then return end
	local n = 0
	for _, B in pairs(G.Boats) do if B.Kind == "S" then n += 1 end end
	for _, a in ipairs(ports) do
		if n >= Config.Trade.MaxShips then return end
		if rng:NextNumber() < Config.Trade.Chance then
			local b
			for _ = 1, 8 do
				local c = ports[rng:NextInteger(1, #ports)]
				if c.Owner ~= a.Owner then b = c break end
			end
			if b then
				local key = a.Id .. ":" .. b.Id
				local path = tradeCache[key]
				if path == nil and pathBudget > 0 then
					-- новый маршрут считаем один раз (не больше двух в секунду), дальше берём из кэша
					pathBudget -= 1
					local starts = waterNear(a.Tile, 1)
					local goals = setOf(waterNear(b.Tile, 1))
					path = (#starts > 0 and next(goals) ~= nil) and waterPath(starts, goals) or false
					tradeCache[key] = path
				end
				if path and #path > 1 then
					local B = { Id = nextBoat, Kind = "S", Owner = a.Owner, Path = path, Pos = 1, Speed = Config.Trade.Speed, Src = a.Id, Dst = b.Id, Dist = #path }
					nextBoat += 1
					G.Boats[B.Id] = B
					n += 1
				end
			end
		end
	end
end

-- торговый корабль дошёл: золото владельцу корабля и владельцу порта (захваченный — только захватчику)
local function tradeArrive(B)
	local dst = G.Buildings[B.Dst]
	if not dst or dst.Type ~= "Port" then return end
	local gold = Config.TradeGold(B.Dist)
	pay(G.Players[B.Owner], gold)
	if not B.Captured and dst.Owner ~= B.Owner then pay(G.Players[dst.Owner], gold) end
end

-- военный корабль строится в порту и идёт патрулировать к выбранной клетке
function G.LaunchWarship(P, tile, cost, port)
	local starts = waterNear(port.Tile, 1)
	local path = #starts > 0 and waterPath(starts, { [tile] = true }, 60000)
	if not path then return false, "No sea route from your port" end
	if #path < 2 then table.insert(path, path[1]) end
	P.Gold -= cost
	P.Built.Warship = (P.Built.Warship or 0) + 1
	local B = { Id = nextBoat, Kind = "W", Owner = P.Id, Path = path, Pos = 1, Speed = Config.Warship.Speed, HP = Config.Warship.Health,
		Home = tile, NextShot = 0, NextThink = 0, Kills = 0 }
	nextBoat += 1
	G.Boats[B.Id] = B
	return true
end

local function pathTo(B, goal, limit)
	local path = waterPath({ shipTile(B) }, { [goal] = true }, limit or 8000)
	if path and #path > 1 then
		B.Path, B.Pos, B.Goal = path, 1, goal
		return true
	end
	return false
end

local function patrolTile(B)
	local hx, hy = B.Home % W, B.Home // W
	local r = Config.Warship.Patrol
	for _ = 1, 20 do
		local x, y = hx + rng:NextInteger(-r, r), hy + rng:NextInteger(-r, r)
		if x >= 0 and x < W and y >= 0 and y < H then
			local i = y * W + x
			if buffer.readu8(OCEAN, i) == 1 then return i end
		end
	end
end

-- захват торгового корабля: теперь он идёт в ближайший порт захватчика и приносит золото ему
local function captureTrade(ws, T)
	local old = G.Players[T.Owner]
	local P = G.Players[ws.Owner]
	T.Owner = ws.Owner
	T.Captured = true
	local x, y = shipXY(T)
	local port = nearestPort(ws.Owner, x, y)
	local ok = false
	if port then
		local goals = setOf(waterNear(port.Tile, 1))
		local path = next(goals) ~= nil and waterPath({ shipTile(T) }, goals, 60000)
		if path and #path > 1 then
			T.Path, T.Pos, T.Dst, T.Dist = path, 1, port.Id, math.max(T.Dist, #path)
			ok = true
		end
	end
	if not ok then
		G.Boats[T.Id] = nil
		pay(P, Config.TradeGold(T.Dist) * 0.5)
	end
	noteOnce(P, "cap", "\u{1F6A2} Your warship captured " .. (old and old.Name or "a") .. "'s trade ship!", "good", 8)
	noteOnce(old, "lostcap", "\u{1F3F4}\u{200D}\u{2620}\u{FE0F} " .. (P and P.Name or "Someone") .. "'s warship captured your trade ship", "bad", 8)
end

local function shoot(ws, T)
	local x1, y1 = shipXY(ws)
	local x2, y2 = shipXY(T)
	local fl = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) / Config.Warship.ShellSpeed
	table.insert(G.Shells, { At = G.Elapsed + fl, Target = T.Id, From = ws.Owner, Ship = ws.Id, Damage = Config.Warship.Damage })
	if G.OnShell then G.OnShell({ X1 = x1, Y1 = y1, X2 = x2, Y2 = y2, T = fl, Owner = ws.Owner }) end
end

local function stepWarship(ws, dt)
	local cfg = Config.Warship
	-- ремонт: быстро у своего порта, медленно в море
	if ws.HP < cfg.Health then
		if G.Elapsed >= (ws.HealCheck or 0) then
			ws.HealCheck = G.Elapsed + 1
			local x, y = shipXY(ws)
			local _, d2 = nearestPort(ws.Owner, x, y)
			ws.NearPort = d2 ~= nil and d2 <= 100
		end
		ws.HP = math.min(cfg.Health, ws.HP + cfg.Heal * dt * (ws.NearPort and 3 or 0.3))
	end
	if G.Elapsed >= ws.NextThink then
		ws.NextThink = G.Elapsed + 0.5
		local x, y = shipXY(ws)
		local R2 = cfg.Range * cfg.Range
		-- цели: сначала десант, потом военные корабли, потом торговые (как в браузере)
		local best, bestPri, bestD
		-- цели только в своём районе патруля (иначе корабль уходит за торговцами через полкарты)
		local hx, hy = ws.Home % W, ws.Home // W
		local leash = (cfg.Patrol + cfg.Range * 0.5) ^ 2
		for _, B in pairs(G.Boats) do
			if B.Owner ~= ws.Owner and not G.Teammates(B.Owner, ws.Owner) then
				local bx, by = shipXY(B)
				local d = (bx - x) ^ 2 + (by - y) ^ 2
				if d <= R2 and (bx - hx) ^ 2 + (by - hy) ^ 2 <= leash then
					local pri = B.Kind == "T" and 1 or B.Kind == "W" and 2 or 3
					if not best or pri < bestPri or (pri == bestPri and d < bestD) then best, bestPri, bestD = B, pri, d end
				end
			end
		end
		ws.Target = best and best.Id or nil
		if best then
			local tt = shipTile(best)
			local gx, gy = ws.Goal and ws.Goal % W or -999, ws.Goal and ws.Goal // W or -999
			local moved = (gx - tt % W) ^ 2 + (gy - tt // W) ^ 2 > 4
			if best.Kind == "S" then
				if moved or ws.Pos >= #ws.Path then pathTo(ws, tt) end
			elseif bestD > 100 and moved then
				pathTo(ws, tt)
			end
		elseif ws.Pos >= #ws.Path or (ws.Goal and ((ws.Goal % W - hx) ^ 2 + (ws.Goal // W - hy) ^ 2 > leash)) then
			local p = patrolTile(ws)
			if p then pathTo(ws, p, 12000) end
		end
	end
	local T = ws.Target and G.Boats[ws.Target]
	if T and T.Owner ~= ws.Owner then
		local x, y = shipXY(ws)
		local bx, by = shipXY(T)
		local d2 = (bx - x) ^ 2 + (by - y) ^ 2
		if T.Kind == "S" then
			if d2 <= cfg.Capture * cfg.Capture then
				captureTrade(ws, T)
				ws.Target = nil
			end
		elseif G.Elapsed >= ws.NextShot and d2 <= cfg.Range * cfg.Range then
			ws.NextShot = G.Elapsed + cfg.Reload
			shoot(ws, T)
		end
	end
	if ws.Pos < #ws.Path then ws.Pos = math.min(#ws.Path, ws.Pos + ws.Speed * dt) end
end

-- попадания снарядов: десант тонет с одного, военный корабль теряет прочность
local function stepShells()
	for i = #G.Shells, 1, -1 do
		local s = G.Shells[i]
		if G.Elapsed >= s.At then
			table.remove(G.Shells, i)
			local T = G.Boats[s.Target]
			if T and T.Owner ~= s.From then
				local sink = true
				if T.Kind == "W" then
					T.HP -= s.Damage
					sink = T.HP <= 0
				end
				if sink then
					local x, y = shipXY(T)
					removeShip(T)
					local A, V = G.Players[s.From], G.Players[T.Owner]
					local ws = G.Boats[s.Ship]
					if ws then ws.Kills = (ws.Kills or 0) + 1 end
					if G.OnSink then G.OnSink({ X = x, Y = y, Kind = T.Kind, Owner = T.Owner }) end
					local what = T.Kind == "W" and "warship" or "boat"
					noteOnce(A, "sank", "\u{1F4A5} Your warship sank " .. (V and V.Name or "an enemy") .. "'s " .. what .. "!", "good", 4)
					noteOnce(V, "sunk", "\u{1F30A} " .. (A and A.Name or "An enemy") .. "'s warship sank your " .. what .. (T.Troops and (" (" .. Config.Fmt(T.Troops) .. " troops)") or ""), "bad", 4)
				end
			end
		end
	end
end

local function stepShips(dt)
	tradeClock += dt
	if tradeClock >= 1 then
		tradeClock = 0
		pathBudget = 2
		spawnTrade()
	end
	for id, B in pairs(G.Boats) do
		if B.Kind == "S" or B.Kind == "W" then
			local P = G.Players[B.Owner]
			if not P or not P.Alive then
				G.Boats[id] = nil
			elseif B.Kind == "S" then
				B.Pos += B.Speed * dt
				if B.Pos >= #B.Path then
					G.Boats[id] = nil
					tradeArrive(B)
				end
			else
				stepWarship(B, dt)
			end
		end
	end
	stepShells()
end

-- связана ли ничья клетка с территорией игрока через ничью сушу (ограниченный поиск)
local stamp2 = buffer.create(N * 4)
local stamp2Id = 0
function G.NeutralConnected(P, tile)
	stamp2Id += 1
	local q, head = { tile }, 1
	buffer.writei32(stamp2, tile * 4, stamp2Id)
	while head <= #q and head < 20000 do
		local c = q[head]; head += 1
		for k = 0, 3 do
			local n = nb(c, k)
			if n >= 0 then
				local o = own(n)
				if o == P.Id then return true end
				if o == 0 and isLand(n) and buffer.readi32(stamp2, n * 4) ~= stamp2Id then
					buffer.writei32(stamp2, n * 4, stamp2Id)
					table.insert(q, n)
				end
			end
		end
	end
	return head >= 20000
end

---------------------------------------------------------------- команда «атаковать клетку» (для людей и ИИ)
function G.AttackTile(P, tile, ratio)
	if G.State ~= "Play" or not P.Alive then return false, "Not now" end
	if not tile or tile < 0 or tile >= N then return false end
	if not isLand(tile) then return false, "Click on land" end
	local D = own(tile)
	if D == P.Id then return false, "That's your land" end
	if G.Teammates(P.Id, D) then return false, "That's your teammate!" end
	local troops = math.floor(P.Troops * (ratio or P.Ratio))
	if troops < 1 then return false, "Not enough troops" end
	-- есть ли общая граница по суше?
	local adjacent = false
	for b in pairs(P.Border) do
		for k = 0, 3 do
			local n = nb(b, k)
			if n >= 0 and own(n) == D and isLand(n) then adjacent = true break end
		end
		if adjacent then break end
	end
	-- ничья земля должна быть связана с нашей границей по суше, иначе клик на дальний остров — корабль
	if adjacent and D == 0 and not G.NeutralConnected(P, tile) then adjacent = false end
	if adjacent then return G.StartAttack(P, D, troops) end
	return G.LaunchBoat(P, tile, troops)
end

---------------------------------------------------------------- стартовые позиции
local function areaFree(tile, r)
	local tx, ty = tile % W, tile // W
	for dy = -r, r do
		for dx = -r, r do
			local x, y = tx + dx, ty + dy
			if x >= 0 and x < W and y >= 0 and y < H then
				if own(y * W + x) ~= 0 then return false end
			end
		end
	end
	return true
end

function G.FindFreeSpawn(clear)
	for _ = 1, 400 do
		local i = rng:NextInteger(0, N - 1)
		if isLand(i) and areaFree(i, clear or Config.SpawnClear) then return i end
	end
	for _ = 1, 400 do
		local i = rng:NextInteger(0, N - 1)
		if isLand(i) and areaFree(i, 2) then return i end
	end
end

-- ближайшая свободная суша около точки (для стран с карты)
function G.NearestFreeLand(x, y, clear)
	for r = 0, 50 do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local xx, yy = x + dx, y + dy
					if xx >= 0 and xx < W and yy >= 0 and yy < H then
						local i = yy * W + xx
						if isLand(i) and areaFree(i, clear) then return i end
					end
				end
			end
		end
	end
end

local function clearPlayerLand(P)
	for _, t in ipairs(P.SpawnTiles) do
		if own(t) == P.Id then setOwner(t, 0) end
	end
	P.SpawnTiles = {}
end

function G.SpawnAt(P, tile)
	if not tile or not isLand(tile) then return false, "Pick land" end
	if own(tile) ~= 0 and own(tile) ~= P.Id then return false, "That spot is taken" end
	if P.Spawned then clearPlayerLand(P) end
	local tx, ty = tile % W, tile // W
	local R = Config.SpawnRadius
	local got = {}
	for dy = -R, R do
		for dx = -R, R do
			if dx * dx + dy * dy <= R * R + R then   -- ровный круг
				local x, y = tx + dx, ty + dy
				if x >= 0 and x < W and y >= 0 and y < H then
					local i = y * W + x
					if isLand(i) and own(i) == 0 then setOwner(i, P.Id); table.insert(got, i) end
				end
			end
		end
	end
	if #got == 0 then return false, "That spot is taken" end
	P.SpawnTiles = got
	P.Spawned = true
	P.Alive = true
	P.Troops = Config.StartTroops[P.Kind] or 3000
	P.SpawnTile = tile
	return true
end

---------------------------------------------------------------- матч
local function resetPlayer(P)
	P.Troops, P.Gold, P.Tiles, P.Border, P.SumX, P.SumY = 0, Config.StartGold, 0, {}, 0, 0
	P.Alive, P.Spawned, P.Attacks, P.BoatCount = false, false, {}, 0
	P.Built = { City = 0, Factory = 0, Port = 0, Defense = 0, SAM = 0, Warship = 0 }
	P.Defenses, P.SpawnTiles, P.LabelTile, P.Kills, P.PeakTiles = {}, {}, nil, 0, 0
	P.BombsUsed, P.NextBomb, P.AttackedBy = 0, 0, {}
end

function G.NewMatch()
	G.Match += 1
	buffer.fill(owner, 0, 0)
	G.Buildings, G.BuildAt, G.Boats, G.Bombs, G.Shells = {}, {}, {}, {}, {}
	tradeCache = {}
	G.MirvLaunched = 0
	G.Changed = {}
	G.BuildEvents = { { Op = "reset" } }
	G.Winner = nil
	-- ИИ создаём заново, люди остаются
	for id, P in pairs(G.Players) do
		if P.Kind == "human" and P.User and P.User.Parent then
			resetPlayer(P)
		else
			G.Players[id] = nil
		end
	end
	colorIdx = rng:NextInteger(0, #Config.Colors - 1)
	-- страны с карты (случайный набор)
	local list = table.clone(MapData.Nations)
	for i = #list, 2, -1 do local j = rng:NextInteger(1, i); list[i], list[j] = list[j], list[i] end
	for k = 1, math.min(Config.NationCount, #list) do
		local n = list[k]
		local tile = G.NearestFreeLand(n[2], n[3], 6)
		if tile then
			local P = G.NewPlayer(n[1], "nation")
			G.SpawnAt(P, tile)
		end
	end
	for _ = 1, Config.BotCount do
		local tile = G.FindFreeSpawn()
		if tile then
			local name = Config.BotFirst[rng:NextInteger(1, #Config.BotFirst)] .. " " .. Config.BotSecond[rng:NextInteger(1, #Config.BotSecond)]
			local P = G.NewPlayer(name, "bot")
			G.SpawnAt(P, tile)
		end
	end
	-- людям — новые цвета
	for _, P in pairs(G.Players) do
		if P.Kind == "human" then P.Color = nextColor(); P.TeamFriend = false end
	end
	G.State = G.Private and "Lobby" or "Spawn"   -- приватное лобби ждёт кнопку START хоста
	G.Timer = Config.SpawnPhase
	G.Elapsed = 0
end

local function startPlay()
	G.State = "Play"
	G.Elapsed = 0
	for _, P in pairs(G.Players) do
		if P.Kind == "human" and P.InMatch and not P.Spawned then
			local t = G.FindFreeSpawn()
			if t then G.SpawnAt(P, t) end
		end
	end
end

-- человек жмёт PLAY
function G.JoinMatch(P)
	P.InMatch = true
	if G.State == "Play" and not P.Alive then
		-- поздний вход: свободное место на карте
		resetPlayer(P)
		P.InMatch = true
		if G.Private then P.TeamFriend = true end   -- друг, зашедший по коду во время матча, тоже в команде
		local t = G.FindFreeSpawn(3)
		if t then
			G.SpawnAt(P, t)
			return true, "late"
		end
		return false, "The map is full — you'll join the next match"
	end
	return true
end

function G.RemoveHuman(P)
	-- ушедший игрок: его страну ведёт ИИ
	if P.User then G.ByUser[P.User] = nil end
	if P.Alive then
		P.Kind = "bot"
		P.User = nil
	else
		G.Players[P.Id] = nil
	end
end

local function eliminate(P)
	P.Alive = false
	for _, A in ipairs(P.Attacks) do A.Troops = 0 end
	P.Attacks = {}
	P.Troops = 0
	if G.OnEliminated then G.OnEliminated(P) end
end

local function finish(winner, reason)
	G.State = "End"
	G.Timer = Config.EndScreen
	G.Winner = winner
	if G.OnEnd then G.OnEnd(winner, reason) end
end

---------------------------------------------------------------- бомбы (атомная, водородная, MIRV) и ПВО
G.Bombs = {}
G.OnBomb = nil    -- function(info) — запуск (для рассылки клиентам)
G.OnBoom = nil    -- function(info) — взрыв

-- цена бомбы с учётом мести (скидка по тому, кто недавно на тебя напал)
function G.IsRevenge(P, targetId)
	local t = targetId and targetId ~= 0 and P.AttackedBy[targetId]
	return t ~= nil and t ~= false and os.clock() - t <= Config.Bomb.RevengeWindow
end
function G.BombPrice(P, kind, targetId)
	local c = Config.BombCost(kind, kind == "MIRV" and G.MirvLaunched or 0)
	if P.VIP and G.IsRevenge(P, targetId) then c = math.floor(c * (1 - Config.Bomb.RevengeDiscount)) end
	return c
end
-- подсказка к уведомлению об атаке: VIP — напоминание о мести, остальным — о VIP
function G.RevengeHint(DP)
	if DP.VIP then return "  \u{2622}\u{FE0F} Revenge bombs \u{2212}50%!" end
	return "  \u{1F451} VIP: \u{2212}50% revenge bombs!"
end
G.MirvLaunched = 0

-- клетки страны (обход от клетки внутри неё, до лимита) — цели боеголовок MIRV
local function countryTiles(id, start, limit)
	stamp2Id += 1
	local q, head = { start }, 1
	buffer.writei32(stamp2, start * 4, stamp2Id)
	while head <= #q and #q < limit do
		local c = q[head]; head += 1
		for k = 0, 3 do
			local n = nb(c, k)
			if n >= 0 and own(n) == id and buffer.readi32(stamp2, n * 4) ~= stamp2Id then
				buffer.writei32(stamp2, n * 4, stamp2Id)
				table.insert(q, n)
			end
		end
	end
	return q
end

function G.LaunchBomb(P, tile, kind)
	kind = kind or "Atom"
	local def = Config.BombDef(kind)
	if not def then return false, "Unknown bomb" end
	if G.State ~= "Play" or not P.Alive then return false, "Not now" end
	if def.VIP and not P.VIP then return false, def.Name .. " is a VIP weapon" end
	if G.Elapsed < Config.Bomb.UnlockAt then return false, "Bombs unlock at " .. (Config.Bomb.UnlockAt // 60) .. ":" .. string.format("%02d", Config.Bomb.UnlockAt % 60) end
	if os.clock() < P.NextBomb then return false, "Bombs are reloading" end
	if not tile or tile < 0 or tile >= N or not isLand(tile) then return false, "Aim at land" end
	local target = own(tile)
	if target == P.Id then return false, "That's your own land" end
	if G.Teammates(P.Id, target) then return false, "You can't bomb your teammate" end
	if kind == "MIRV" and target == 0 then return false, "Aim the MIRV at an enemy country" end
	local price = G.BombPrice(P, kind, target)
	if P.Gold < price then return false, "Not enough gold (" .. Config.Fmt(price) .. ")" end
	P.Gold -= price
	P.BombsUsed += 1
	P.NextBomb = os.clock() + Config.Bomb.Cooldown
	if kind == "MIRV" then G.MirvLaunched += 1 end
	local fx, fy = G.LabelPoint(P)
	local targets = { tile }
	if kind == "MIRV" then
		local list = countryTiles(target, tile, 60000)
		targets = {}
		for k = 1, def.Warheads do targets[k] = list[rng:NextInteger(1, #list)] end
	end
	for k, t in ipairs(targets) do
		table.insert(G.Bombs, { Owner = P.Id, Tile = t, At = G.Elapsed + def.Flight + (k - 1) * 0.07, Kind = kind, Inner = def.Inner, Outer = def.Outer })
	end
	if G.OnBomb then
		G.OnBomb({ Owner = P.Id, FromX = fx, FromY = fy, Tile = tile, Targets = kind == "MIRV" and targets or nil, T = def.Flight, R = def.Outer, Kind = kind, Revenge = P.VIP and G.IsRevenge(P, target) })
	end
	local DP = G.Players[target]
	if DP and DP.User then note(DP.User, def.Icon .. " " .. P.Name .. " launched " .. (def.Name:match("^[AEIOU]") and "an " or "a ") .. def.Name .. " at you!", "bad") end
	return true, price
end

local function stepBombs()
	if #G.Bombs == 0 then return end
	for i = #G.Bombs, 1, -1 do
		local B = G.Bombs[i]
		-- ПВО: незадолго до удара ближайший готовый SAM чужого игрока сбивает бомбу (MIRV не сбивается)
		if not B.Checked and B.Kind ~= "MIRV" and G.Elapsed >= B.At - 0.9 then
			B.Checked = true
			local tx, ty = B.Tile % W, B.Tile // W
			local R2 = Config.SAM.Range * Config.SAM.Range
			for _, b in pairs(G.Buildings) do
				if b.Type == "SAM" and b.Owner ~= 0 and b.Owner ~= B.Owner and not G.Teammates(b.Owner, B.Owner) and (b.ReadyAt or 0) <= G.Elapsed then
					local dx, dy = b.Tile % W - tx, b.Tile // W - ty
					if dx * dx + dy * dy <= R2 then
						b.ReadyAt = G.Elapsed + Config.SAM.Reload
						B.Shot = b
						break
					end
				end
			end
			if B.Shot then
				table.remove(G.Bombs, i)
				local b = B.Shot
				local def = Config.BombDef(B.Kind)
				local SP, AP = G.Players[b.Owner], G.Players[B.Owner]
				if SP and SP.User then note(SP.User, "\u{1F3AF} Your SAM shot down " .. (AP and AP.Name or "an enemy") .. "'s " .. def.Name .. "!", "good") end
				if AP and AP.User then note(AP.User, "\u{1F3AF} Your " .. def.Name .. " was shot down by " .. (SP and SP.Name or "a SAM") .. "'s SAM", "bad") end
				if G.OnShot then G.OnShot({ SamTile = b.Tile, Tile = B.Tile, Owner = B.Owner, SamOwner = b.Owner, Kind = B.Kind }) end
				continue
			end
		end
		if G.Elapsed >= B.At then
			table.remove(G.Bombs, i)
			local tx, ty = B.Tile % W, B.Tile // W
			local R, Ri = B.Outer, B.Inner
			local hit = 0
			for dy = -R, R do
				for dx = -R, R do
					local d2 = dx * dx + dy * dy
					-- внутри — сгорает всё, во внешнем кольце — половина клеток
					if d2 <= R * R and (d2 <= Ri * Ri or rng:NextNumber() < 0.5) then
						local x, y = tx + dx, ty + dy
						if x >= 0 and x < W and y >= 0 and y < H then
							local t = y * W + x
							local o = own(t)
							if o ~= 0 and o ~= B.Owner and not G.Teammates(o, B.Owner) then
								local O = G.Players[o]
								if O and O.Tiles > 0 then O.Troops = math.max(0, O.Troops - O.Troops / O.Tiles * Config.Bomb.TroopLoss) end
								setOwner(t, 0)
								hit += 1
							end
						end
					end
				end
			end
			if G.OnBoom then G.OnBoom({ Owner = B.Owner, Tile = B.Tile, R = R, Kind = B.Kind, Hit = hit }) end
		end
	end
end

---------------------------------------------------------------- заводы и города
-- каждый завод связан со своими городами в радиусе (до FactoryMaxLinks), за каждую связь — золото
function G.UpdateFactoryLinks()
	local byOwner = {}
	for _, b in pairs(G.Buildings) do
		local t = byOwner[b.Owner]
		if not t then t = { F = {}, C = {} }; byOwner[b.Owner] = t end
		if b.Type == "Factory" then table.insert(t.F, b) elseif b.Type == "City" then table.insert(t.C, b) end
	end
	local R = Config.Gold.FactoryRange
	for _, P in pairs(G.Players) do
		local t = byOwner[P.Id]
		local links = 0
		if t then
			for _, f in ipairs(t.F) do
				local fx, fy = f.Tile % W, f.Tile // W
				local n = 0
				for _, c in ipairs(t.C) do
					local cx, cy = c.Tile % W, c.Tile // W
					if (cx - fx) ^ 2 + (cy - fy) ^ 2 <= R * R then n += 1 end
				end
				links += math.min(n, Config.Gold.FactoryMaxLinks)
			end
		end
		P.FactoryLinks = links
	end
end

-- информация об атаке для карты: войска и середина фронта
function G.AttackSpot(A)
	local f = A.Front
	if not f or #f == 0 then return nil end
	local sx, sy, n = 0, 0, 0
	for _ = 1, math.min(40, #f) do
		local t = f[rng:NextInteger(1, #f)]
		sx += t % W; sy += t // W; n += 1
	end
	return sx / n, sy / n
end

---------------------------------------------------------------- шаг симуляции
local winClock = 0
function G.Step(dt, AI)
	if G.State == "Lobby" then
		return
	elseif G.State == "Spawn" then
		G.Timer -= dt
		if G.Timer <= 0 then startPlay() end
		return
	elseif G.State == "End" then
		G.Timer -= dt
		if G.Timer <= 0 then G.NewMatch() end
		return
	end
	G.Elapsed += dt
	for _, P in pairs(G.Players) do
		if P.Alive then
			P.Max = Config.MaxTroops(P.Tiles, P.Built.City, P.Kind)
			P.TRate = Config.TroopRate(P.Troops, P.Max, P.Kind)
			P.Troops = math.max(0, P.Troops + P.TRate * dt)
			P.GRate = Config.GoldRate(P.Tiles, P.Built.Factory, P.Built.Port, P.VIP, P.FactoryLinks or 0, P.Kind)
			P.Gold += P.GRate * dt
			for i = #P.Attacks, 1, -1 do
				local A = P.Attacks[i]
				if A then stepAttack(P, A) end
			end
			if AI and P.Kind ~= "human" and os.clock() >= P.NextThink then
				P.NextThink = os.clock() + rng:NextNumber(Config.AI.ThinkMin, Config.AI.ThinkMax)
				AI.Think(G, P)
			end
		end
	end
	stepBoats(dt)
	stepShips(dt)
	stepBombs()
	-- выбывание и победа
	winClock += dt
	if winClock >= 0.5 then
		winClock = 0
		G.UpdateFactoryLinks()
		local best
		for _, P in pairs(G.Players) do
			-- сглаженный доход от торговли (для «+X/s» в интерфейсе)
			P.TradeRate = (P.TradeRate or 0) * 0.95 + (P.TradeIn or 0) / 0.5 * 0.05
			P.TradeIn = 0
			if P.Alive and P.Spawned and P.Tiles <= 0 then eliminate(P) end
			if P.Alive and (not best or P.Tiles > best.Tiles) then best = P end
		end
		-- команда друзей: считается общая земля
		local teamTiles, teamBest = 0, nil
		if G.IsTeam() then
			for _, P in pairs(G.Players) do
				if P.Alive and P.TeamFriend then
					teamTiles += P.Tiles
					if not teamBest or P.Tiles > teamBest.Tiles then teamBest = P end
				end
			end
		end
		G.TeamTiles = teamTiles
		if teamBest and teamTiles >= totalLand * Config.WinShare then
			finish(teamBest, "team")
		elseif best and best.Tiles >= totalLand * Config.WinShare then
			finish(best, "conquest")
		elseif G.Elapsed >= Config.MatchTime then
			finish(best, "time")
		end
	end
end

-- точка для подписи страны: своя клетка рядом с центром масс
function G.LabelPoint(P)
	if P.Tiles <= 0 then return nil end
	local cx, cy = math.floor(P.SumX / P.Tiles + 0.5), math.floor(P.SumY / P.Tiles + 0.5)
	local c = cy * W + cx
	if c >= 0 and c < N and own(c) == P.Id then return cx, cy end
	if P.LabelTile and own(P.LabelTile) == P.Id then
		local lx, ly = P.LabelTile % W, P.LabelTile // W
		if (lx - cx) ^ 2 + (ly - cy) ^ 2 < 144 then return lx, ly end
	end
	for r = 1, 28 do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local x, y = cx + dx, cy + dy
					if x >= 0 and x < W and y >= 0 and y < H and own(y * W + x) == P.Id then
						P.LabelTile = y * W + x
						return x, y
					end
				end
			end
		end
	end
	return cx, cy
end

-- сжатый снимок владельцев (RLE: u16 владелец, u16 длина)
function G.OwnerRLE()
	local runs = {}
	local i = 0
	while i < N do
		local o = own(i)
		local s = i
		while i + 1 < N and own(i + 1) == o and i + 1 - s < 65535 do i += 1 end
		table.insert(runs, o)
		table.insert(runs, i - s + 1)
		i += 1
	end
	local b = buffer.create(#runs * 2)
	for k, v in ipairs(runs) do buffer.writeu16(b, (k - 1) * 2, v) end
	return b
end

return G
