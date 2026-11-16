--[[
	State — клиентская копия игры: владельцы клеток, игроки, состояние матча, события сервера.
	Сигналы — BindableEvent'ы (OnSync, OnTiles, OnPlayers, OnMe, OnGame, OnNote, OnEnd, OnBuild, OnBoats, OnDead, OnJoined, OnAttacked).
]]
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Shared = RS:WaitForChild("Conquerra")
local Config = require(Shared:WaitForChild("Config"))
local MapData = require(Shared:WaitForChild("MapData"))
local remotes = Shared:WaitForChild("Remotes")
local Net = remotes:WaitForChild("Net")
local Act = remotes:WaitForChild("Act")
local Sync = remotes:WaitForChild("Sync")

local S = {}
S.Config = Config
S.Player = Players.LocalPlayer
S.W, S.H = MapData.W, MapData.H
S.N = S.W * S.H
S.TS = Config.TileSize
S.Terrain = MapData.Decode()
S.Owner = buffer.create(S.N * 2)
S.Players = {}      -- id -> данные игрока
S.MyId = 0
S.Match = -1
S.Synced = false
S.Me = nil
S.Game = { State = "Spawn", Timer = 0, Elapsed = 0, Leader = "", LeaderShare = 0, TotalLand = 1 }
S.InMenu = true
S.Buildings = {}

local function signal(name)
	local e = Instance.new("BindableEvent")
	S[name] = e.Event
	S["_" .. name] = e
end
for _, n in ipairs({ "OnSync", "OnTiles", "OnPlayers", "OnMe", "OnGame", "OnNote", "OnEnd", "OnBuild", "OnBoats", "OnDead", "OnJoined", "OnAttacked", "OnNewMatch", "OnNuke", "OnBoom", "OnShot", "OnShell", "OnSink", "OnParty" }) do
	signal(n)
end

function S.Own(i) return buffer.readu16(S.Owner, i * 2) end
function S.IsLand(i) return buffer.readu8(S.Terrain, i) >= 4 end
-- океан или мелководье (по ним ходят корабли)
function S.IsSea(i) local c = buffer.readu8(S.Terrain, i) return c == 0 or c == 2 end

-- клетка ↔ мир
local halfW, halfH = S.W * S.TS / 2, S.H * S.TS / 2
function S.TileCenter(i)
	local x, y = i % S.W, i // S.W
	return Vector3.new((x + 0.5) * S.TS - halfW, 0, (y + 0.5) * S.TS - halfH)
end
function S.TileXY(x, y)
	return Vector3.new((x + 0.5) * S.TS - halfW, 0, (y + 0.5) * S.TS - halfH)
end
function S.TileAt(pos)
	local x = math.floor((pos.X + halfW) / S.TS)
	local y = math.floor((pos.Z + halfH) / S.TS)
	if x < 0 or x >= S.W or y < 0 or y >= S.H then return nil end
	return y * S.W + x
end

function S.Act(kind, data) Act:FireServer(kind, data) end

function S.MyColor()
	local c = Config.MyColor
	return Color3.fromRGB(c[1], c[2], c[3])
end
-- цвет игрока (своя страна всегда голубая, как в Conquerra)
function S.ColorOf(id)
	if id == S.MyId and id ~= 0 then return S.MyColor() end
	local p = S.Players[id]
	return p and p.Color or Color3.fromRGB(200, 200, 200)
end

local function decodeRLE(b)
	local p = 0
	for k = 0, buffer.len(b) - 4, 4 do
		local o = buffer.readu16(b, k)
		local len = buffer.readu16(b, k + 2)
		for i = p, p + len - 1 do buffer.writeu16(S.Owner, i * 2, o) end
		p += len
	end
end

local syncing = false
function S.Resync()
	if syncing then return end
	syncing = true
	S.Synced = false
	local ok, snap = pcall(function() return Sync:InvokeServer() end)
	syncing = false
	if not ok or type(snap) ~= "table" then
		warn("[Conquerra] синхронизация не удалась", snap)
		task.delay(2, S.Resync)
		return
	end
	S.MyId = snap.MyId
	buffer.fill(S.Owner, 0, 0)
	decodeRLE(snap.Owners)
	S.Players = {}
	for _, p in ipairs(snap.Players) do S.Players[p.Id] = p end
	S.Game = snap.State
	S.Match = snap.State.Match
	S.Buildings = {}
	for _, b in ipairs(snap.Buildings) do S.Buildings[b.Id] = b end
	S.Synced = true
	S._OnSync:Fire()
	S._OnGame:Fire(S.Game)
end

function S.Start()
	Net.OnClientEvent:Connect(function(kind, data)
		if kind == "T" then
			if not S.Synced or data.M ~= S.Match then return end
			local b = data.B
			local list = {}
			for k = 0, buffer.len(b) - 8, 8 do
				local s = buffer.readu32(b, k)
				local len = buffer.readu16(b, k + 4)
				local o = buffer.readu16(b, k + 6)
				for i = s, s + len - 1 do
					buffer.writeu16(S.Owner, i * 2, o)
					table.insert(list, i)
				end
			end
			S._OnTiles:Fire(list)
		elseif kind == "Players" then
			local map = {}
			for _, p in ipairs(data) do map[p.Id] = p end
			S.Players = map
			-- таблицу не передаём через BindableEvent: разрежённые числовые ключи там становятся строками
			S._OnPlayers:Fire()
		elseif kind == "Me" then
			S.Me = data
			if data.Id and data.Id ~= S.MyId then S.MyId = data.Id end
			S._OnMe:Fire(data)
		elseif kind == "State" then
			S.Game = data
			if data.Match ~= S.Match and S.Synced then task.spawn(S.Resync) end
			S._OnGame:Fire(data)
		elseif kind == "NewMatch" then
			S._OnNewMatch:Fire()
			task.spawn(S.Resync)
		elseif kind == "B" then
			if not S.Synced or data.M ~= S.Match then return end
			for _, e in ipairs(data.E) do
				if e.Op == "add" then S.Buildings[e.Id] = { Id = e.Id, Type = e.Type, Tile = e.Tile, Owner = e.Owner }
				elseif e.Op == "del" then S.Buildings[e.Id] = nil
				elseif e.Op == "own" and S.Buildings[e.Id] then S.Buildings[e.Id].Owner = e.Owner
				elseif e.Op == "reset" then S.Buildings = {} end
			end
			S._OnBuild:Fire(data.E)
		elseif kind == "Boats" then
			S._OnBoats:Fire(data)
		elseif kind == "Note" then
			S._OnNote:Fire(data)
		elseif kind == "End" then
			S._OnEnd:Fire(data)
		elseif kind == "Dead" then
			S._OnDead:Fire(data)
		elseif kind == "Joined" then
			S._OnJoined:Fire(data)
		elseif kind == "Attacked" then
			S._OnAttacked:Fire(data)
		elseif kind == "Nuke" then
			S._OnNuke:Fire(data)
		elseif kind == "Boom" then
			S._OnBoom:Fire(data)
		elseif kind == "Shot" then
			S._OnShot:Fire(data)
		elseif kind == "Party" then
			S._OnParty:Fire(data)
		elseif kind == "Shell" then
			S._OnShell:Fire(data)
		elseif kind == "Sink" then
			S._OnSink:Fire(data)
		end
	end)
	task.spawn(S.Resync)
end

return S
