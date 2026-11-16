--[[
	EXCERPT from client/Render.lua (lines 157–324 of 1099) — not a complete module.

	Territories are painted pixel-per-tile into 8 EditableImages (258×258 each) that sit as an extra layer
	inside the SurfaceGuis of the satellite map. Changing a tile repaints it and its 4 neighbours in a CPU
	buffer and marks the dirty row range; once per frame only one chunk's dirty rows are uploaded.
	If the experience doesn't allow EditableImage, the renderer falls back to merged Parts.

	Context provided by the rest of Render.lua: S (client State), R (this module), W/H (map size).
]]

---------------------------------------------------------------- пиксельные территории (EditableImage, как canvas в браузерной Conquerra)
-- Карта делится на две половины по 258×258 клеток; каждая — картинка 516×516 (2×2 пикселя на клетку).
-- Заливка полупрозрачная, граница — только пиксели со стороны соседа (тонкая, в полклетки).
local AssetService = game:GetService("AssetService")
local useEI = false
local EI = {}          -- [0|1] = { Img, Buf, D0, D1 }
local PX = 258         -- сторона картинки территорий = клеток на один кусок спутниковой карты (1 пиксель = 1 клетка)
local colorCache = {}
local FILL_A, BORDER_A, MY_FILL_A = 118, 235, 140

local function rgbOf(o)
	local c = colorCache[o]
	if not c then
		local col = S.ColorOf(o)
		c = { math.floor(col.R * 255), math.floor(col.G * 255), math.floor(col.B * 255) }
		colorCache[o] = c
	end
	return c
end

local function initEI()
	-- территории кладём слоем в те же SurfaceGui, что и спутниковая карта (8 кусков 4×2):
	-- так Roblox не сортирует прозрачные плоскости и карта не перекрывает территории
	local sat = workspace:FindFirstChild("WorldMap") and workspace.WorldMap:FindFirstChild("Satellite")
	if not sat then return false end
	local made = {}
	local ok, err = pcall(function()
		for j = 0, 1 do
			for i = 0, 3 do
				local p = sat:WaitForChild("Sat_" .. j .. "_" .. i, 10)
				local g = p:FindFirstChildOfClass("SurfaceGui")
				local img = AssetService:CreateEditableImage({ Size = Vector2.new(PX, PX) })
				local il = Instance.new("ImageLabel")
				il.Name = "Territory"
				il.Size = UDim2.fromScale(1, 1)
				il.BackgroundTransparency = 1
				il.ZIndex = 2
				il.ResampleMode = Enum.ResamplerMode.Pixelated
				il.ImageContent = Content.fromObject(img)
				il.Parent = g
				table.insert(made, il)
				EI[j * 4 + i] = { Img = img, Buf = buffer.create(PX * PX * 4), D0 = nil, D1 = nil }
				-- пробная запись: без разрешения «Allow Mesh / Image APIs» здесь будет ошибка
				img:WritePixelsBuffer(Vector2.zero, Vector2.new(PX, PX), buffer.create(PX * PX * 4))
			end
		end
	end)
	if not ok then
		warn("[Conquerra] EditableImage недоступен, территории рисуются деталями:", err)
		for _, il in ipairs(made) do il:Destroy() end
		EI = {}
		return false
	end
	R.EIOverlays = made
	return true
end

-- перерисовать одну клетку (блок 2×2) в буфере
-- Вода у берега рисуется по сетке клеток (как в браузере): спутниковая картинка точнее сетки, и без этого
-- на мелководье видны «зелёные пиксели» суши, которую нельзя захватить.
local SHORE -- buffer: 1 = клетка воды рядом с сушей
local SHORE_RGBA = { 76, 128, 174, 235 }
local function buildShore()
	SHORE = buffer.create(W * H)
	for i = 0, W * H - 1 do
		local c = buffer.readu8(S.Terrain, i)
		if c <= 2 then
			local x = i % W
			local near = c == 2
			if not near then
				for _, n in ipairs({ i - W, i + W, x > 0 and i - 1 or -1, x < W - 1 and i + 1 or -1 }) do
					if n >= 0 and n < W * H and buffer.readu8(S.Terrain, n) >= 4 then near = true break end
				end
			end
			if near then buffer.writeu8(SHORE, i, 1) end
		end
	end
end

local function paintTile(i)
	local x, y = i % W, i // W
	local E = EI[(y // PX) * 4 + x // PX]
	if not E then return end
	local lx = x % PX
	local ly = y % PX
	local buf = E.Buf
	local o = buffer.readu16(S.Owner, i * 2)
	local base = (ly * PX + lx) * 4
	if o == 0 then
		if SHORE and buffer.readu8(SHORE, i) == 1 then
			buffer.writeu8(buf, base, SHORE_RGBA[1]); buffer.writeu8(buf, base + 1, SHORE_RGBA[2])
			buffer.writeu8(buf, base + 2, SHORE_RGBA[3]); buffer.writeu8(buf, base + 3, SHORE_RGBA[4])
		else
			buffer.writeu32(buf, base, 0)
		end
	else
		local up = y == 0 or buffer.readu16(S.Owner, (i - W) * 2) ~= o
		local dn = y == H - 1 or buffer.readu16(S.Owner, (i + W) * 2) ~= o
		local lf = x == 0 or buffer.readu16(S.Owner, (i - 1) * 2) ~= o
		local rt = x == W - 1 or buffer.readu16(S.Owner, (i + 1) * 2) ~= o
		local mine = o == S.MyId
		local c = rgbOf(o)
		local fr, fg, fb, fa = c[1], c[2], c[3], mine and MY_FILL_A or FILL_A
		local br, bg, bb = c[1], c[2], c[3]
		if mine then br, bg, bb = 255, 255, 255 end
		local function px(off, border)
			if border then
				buffer.writeu8(buf, off, br); buffer.writeu8(buf, off + 1, bg); buffer.writeu8(buf, off + 2, bb); buffer.writeu8(buf, off + 3, BORDER_A)
			else
				buffer.writeu8(buf, off, fr); buffer.writeu8(buf, off + 1, fg); buffer.writeu8(buf, off + 2, fb); buffer.writeu8(buf, off + 3, fa)
			end
		end
		px(base, up or dn or lf or rt)
	end
	if not E.D0 or ly < E.D0 then E.D0 = ly end
	if not E.D1 or ly > E.D1 then E.D1 = ly end
end

local function paintAround(i)
	paintTile(i)
	local x = i % W
	if i >= W then paintTile(i - W) end
	if i < S.N - W then paintTile(i + W) end
	if x > 0 then paintTile(i - 1) end
	if x < W - 1 then paintTile(i + 1) end
end

local repainting = false
local function repaintAll()
	colorCache = {}
	if repainting then return end
	repainting = true
	task.spawn(function()
		for y = 0, H - 1 do
			for x = 0, W - 1 do paintTile(y * W + x) end
			if y % 32 == 31 then task.wait() end
		end
		repainting = false
	end)
end

-- отправка изменённых строк в картинку (не больше одной половины за кадр)
local flushTurn = 0
local function flushEI()
	for k = 0, 7 do
		local h = (flushTurn + k) % 8
		local E = EI[h]
		if E and E.D0 then
			local r0, r1 = E.D0, E.D1
			E.D0, E.D1 = nil, nil
			local rows = r1 - r0 + 1
			local slice = buffer.create(rows * PX * 4)
			buffer.copy(slice, 0, E.Buf, r0 * PX * 4, rows * PX * 4)
			local ok = pcall(function() E.Img:WritePixelsBuffer(Vector2.new(0, r0), Vector2.new(PX, rows), slice) end)
			if not ok then
				-- EditableImage отказал (выключено в настройках игры): переходим на детали
				useEI = false
				EI = {}
				for _, il in ipairs(R.EIOverlays or {}) do il:Destroy() end
				R.MarkAll()
				return
			end
			flushTurn = h + 1
			return
		end
	end
end
