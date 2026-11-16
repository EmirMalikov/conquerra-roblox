--[[
	EXCERPT from client/Render.lua (lines 962–1019 of 1099) — not a complete module.

	Factories are linked to up to 5 own cities in range (the same rule the server uses for income).
	Links are drawn like the browser game's railroads: straight segments that only turn at 90°,
	a dark bed with a lighter rail on top, and an overlap at the corner so the joint has no gap.

	Context provided by the rest of Render.lua: part() (anchored Part factory), S, Config, W, linkFolder, buildFolder.
]]

local function lineBetween(a, b, color, transp, parent, width)
	local mid = (a + b) / 2
	local len = (b - a).Magnitude
	if len < 0.05 then return end
	local p = part(Vector3.new(width or 0.22, 0.06, len), CFrame.lookAt(mid, b), color, transp or 0, parent)
	return p
end
-- железная дорога как в браузерной игре: прямые отрезки с поворотом только на 90°
-- (сначала по длинной оси, потом по короткой); тёмное полотно + светлая середина
local function railPath(a, b, color, transp, parent, width)
	width = width or 0.3
	local corner
	if math.abs(b.X - a.X) >= math.abs(b.Z - a.Z) then corner = Vector3.new(b.X, a.Y, a.Z) else corner = Vector3.new(a.X, a.Y, b.Z) end
	local function seg(p, q)
		local d = q - p
		if d.Magnitude < 0.05 then return end
		local u = d.Unit
		p, q = p - u * width / 2, q + u * width / 2   -- стык в углу без дыры
		lineBetween(p, q, color:Lerp(Color3.fromRGB(20, 18, 30), 0.65), transp, parent, width)
		lineBetween(p + Vector3.new(0, 0.02, 0), q + Vector3.new(0, 0.02, 0), color:Lerp(Color3.new(1, 1, 1), 0.15), transp, parent, width * 0.4)
	end
	seg(a, corner)
	seg(corner, b)
end

-- пары (завод, город) по правилу сервера: свои города в радиусе, не больше FactoryMaxLinks на завод
function R.FactoryCities(owner, ftile, extraCity)
	local fx, fy = ftile % W, ftile // W
	local Rr = Config.Gold.FactoryRange
	local list = {}
	local function consider(tile)
		local cx, cy = tile % W, tile // W
		local d = (cx - fx) ^ 2 + (cy - fy) ^ 2
		if d <= Rr * Rr then table.insert(list, { tile, d }) end
	end
	for _, b in pairs(S.Buildings) do
		if b.Owner == owner and b.Type == "City" then consider(b.Tile) end
	end
	if extraCity then consider(extraCity) end
	table.sort(list, function(x, y) return x[2] < y[2] end)
	local out = {}
	for k = 1, math.min(#list, Config.Gold.FactoryMaxLinks) do out[k] = list[k][1] end
	return out
end
function R.RefreshLinks()
	if linkFolder then linkFolder:Destroy() end
	linkFolder = Instance.new("Folder")
	linkFolder.Name = "Links"
	for _, b in pairs(S.Buildings) do
		if b.Type == "Factory" then
			local col = S.ColorOf(b.Owner)
			for _, c in ipairs(R.FactoryCities(b.Owner, b.Tile)) do
				railPath(S.TileCenter(b.Tile) + Vector3.new(0, 0.7, 0), S.TileCenter(c) + Vector3.new(0, 0.7, 0), col, 0, linkFolder, 0.4)
			end
		end
	end
	linkFolder.Parent = buildFolder
end
