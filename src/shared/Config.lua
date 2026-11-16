--[[
	Config — все числа Conquerra в одном месте (баланс, тайминги, постройки, ИИ, цвета).
	Общий для сервера и клиента.
]]
local C = {}

C.GameName = "Conquerra"
C.Tagline = "CONQUER THE REAL WORLD"

-- карта
C.TileSize = 0.5            -- стадов на клетку (компактный мир: вся карта видна даже на низкой дальности прорисовки)
C.CameraFOV = 70
C.CameraMin, C.CameraMax = 9, 200
C.OverlayY = 0.55         -- высота заливки территорий
C.Chunk = 32              -- размер куска отрисовки (клеток)

-- тайминги матча (секунды)
C.Tick = 0.1              -- шаг симуляции
C.SendTiles = 0.15        -- как часто рассылать изменённые клетки
C.SendPlayers = 0.5
C.SendMe = 0.25
C.SpawnPhase = 25         -- выбор стартовой точки
C.MatchTime = 15 * 60     -- лимит матча: дальше побеждает самый большой
C.WinShare = 0.8          -- цель: 80% мира
C.EndScreen = 14          -- экран итогов перед новым матчем

-- участники
C.NationCount = 44        -- стран с карты (из 70)
C.BotCount = 26           -- «племён» в случайных местах
C.SpawnRadius = 4         -- радиус стартовой территории
C.SpawnClear = 10          -- свободное место вокруг старта
-- Войска считаются как в браузерной Conquerra и показываются так же (браузер делит число на 10).
-- Одна клетка здесь = 4 клетки браузерной карты (2×2, карта map4x), формулы пересчитаны с этим масштабом.
C.StartTroops = { human = 2500, nation = 1875, bot = 1000 }
C.StartGold = 0

-- максимум: 2·(клеток^0.6·1000 + 50000) + 250K за город (в браузерных единицах, /10 для показа)
-- рост за 0.1 с: (10 + войска^0.73 / 4) · 1.15 · (1 − войска / максимум)
C.Troops = { TileScale = 4, PerCity = 25000, Mult = 1.15, NationMax = 0.75, NationRate = 0.95, BotMax = 1 / 3, BotRate = 0.5 }
-- золото: 1300/с всем (как 130 за тик в браузере), остальное — торговые корабли между портами и заводы с городами
C.Gold = { Base = 1300, BotBase = 650, PerFactoryLink = 600, FactoryRange = 55, FactoryMaxLinks = 5 }
-- торговые корабли: порт отправляет корабль в порт другой страны, золото получают оба (как в браузере)
C.Trade = { Chance = 0.1, MaxShips = 90, Speed = 6, ShortRange = 150 }
-- военные корабли (как Warship в браузере): топят десант, бьются с чужими кораблями, захватывают торговые
C.Warship = { Health = 1000, Damage = 250, Reload = 2, Range = 45, ShellSpeed = 40, Patrol = 40, Speed = 7, Capture = 2, PortRange = 70, Heal = 4 }

-- постройки: города, порты и заводы дорожают вдвое, остальное — на шаг (см. BuildCost)
C.Buildings = {
	{ Id = "City", Name = "City", Icon = "🏙️", Cost = 100000, Grow = "double", Max = 800000, Desc = "+25K max troops, powers nearby factories" },
	{ Id = "Factory", Name = "Factory", Icon = "🏭", Cost = 100000, Grow = "double", Max = 800000, Shared = "Port", Desc = "Earns gold from your cities nearby (up to 5)" },
	{ Id = "Port", Name = "Port", Icon = "⚓", Cost = 100000, Grow = "double", Max = 800000, Shared = "Factory", Desc = "Sends trade ships to other ports — gold for both sides", Coastal = true },
	{ Id = "Defense", Name = "Defense Post", Icon = "🛡️", Cost = 40000, Max = 200000, Desc = "Nearby land is much harder and slower to take" },
	{ Id = "SAM", Name = "SAM Launcher", Icon = "🎯", Cost = 1500000, Max = 3000000, Desc = "Shoots down enemy Atom & Hydrogen bombs aimed inside its circle" },
	{ Id = "Warship", Name = "Warship", Icon = "🚢", Cost = 250000, Max = 1000000, Naval = true, Desc = "Sinks enemy boats, fights warships, captures trade ships. Click the sea near your port" },
}
-- ПВО (как SAM в браузерной игре): сбивает бомбу, цель которой в радиусе; боеголовки MIRV не сбивает
C.SAM = { Range = 35, Reload = 10 }
C.DefenseRadius = 15       -- 30 клеток браузерной карты
C.DefenseLoss = 5          -- атакующий теряет в 5 раз больше
C.DefenseSlow = 3          -- и идёт в 3 раза медленнее
C.BuildSpacing = 6        -- минимальное расстояние между постройками

-- атака
C.Ratios = { 0.10, 0.25, 0.35, 0.50, 0.75 }
C.DefaultRatio = 0.25
-- атака как attackLogic браузерной игры: скорость и потери зависят от отношения
-- (войска защитника / войска атаки) — чем больше перевес, тем быстрее и дешевле захват
C.Attack = {
	MaxPerTick = 200,
	MaxAttacks = 4,
	LossBase = 0.463, LossDensity = 0.0039, CheapestRatio = 0.6,
	SpeedDivisor = 8.55, FastRatio = 0.82,
	RetreatLoss = 0.25,      -- отзыв армии: теряется 25% войск (как retreat в браузере)
}
-- {потери, цена скорости} по типу суши: равнины, нагорья, горы (как в браузере)
C.Terrain = { [4] = { 80, 16.5 }, [5] = { 100, 20 }, [6] = { 120, 25 } }

-- корабли с десантом
C.Boat = { Max = 3, Speed = 9, PortSpeed = 1.4, SearchRadius = 28, MaxSearch = 300000 }

-- ИИ
C.AI = {
	ThinkMin = 1.0, ThinkMax = 2.4,
	PeaceTime = 75,          -- первые секунды матча ИИ не нападает на соседей
	nation = { AttackAt = 0.38, NeutralRatio = 0.3, EnemyRatio = 0.4, Builds = true, BoatChance = 0.35 },
	bot = { AttackAt = 0.5, NeutralRatio = 0.35, EnemyRatio = 0.35, Builds = false, BoatChance = 0.15 },
}

-- цвета игроков (пастельные, как в Conquerra)
C.Colors = {
	{ 231, 76, 92 }, { 246, 152, 56 }, { 104, 196, 92 }, { 155, 96, 214 }, { 64, 170, 220 }, { 240, 200, 60 },
	{ 222, 92, 168 }, { 70, 190, 160 }, { 196, 120, 72 }, { 120, 140, 230 }, { 186, 214, 72 }, { 236, 120, 120 },
	{ 100, 120, 150 }, { 250, 170, 120 }, { 140, 200, 230 }, { 210, 150, 220 }, { 90, 160, 90 }, { 230, 110, 60 },
	{ 170, 80, 120 }, { 60, 130, 190 }, { 200, 180, 110 }, { 130, 90, 170 }, { 80, 200, 200 }, { 220, 70, 70 },
	{ 150, 190, 120 }, { 245, 130, 190 }, { 110, 110, 200 }, { 190, 160, 60 }, { 120, 170, 210 }, { 200, 100, 220 },
}
C.MyColor = { 120, 200, 255 }   -- своя территория (для видящего)

-- имена «племён»-ботов
C.BotFirst = { "British", "Cham", "Arawak", "Viking", "Kiowa", "Balinese", "Napoleonic", "Tupi", "Akkadian", "Taino",
	"Spartan", "Scythian", "Mayan", "Hunnic", "Celtic", "Ottoman", "Mongol", "Persian", "Aztec", "Nordic", "Gothic",
	"Saxon", "Inca", "Zulu", "Frankish", "Phoenician", "Carthage", "Khmer", "Sumerian", "Hittite" }
C.BotSecond = { "Assembly", "Horde", "Caliphate", "Queendom", "Clan", "Fief", "Legion", "Order", "Settlement",
	"Host", "Duchy", "Empire", "Republic", "Union", "Tribe", "Kingdom", "League", "Dominion" }

-- сохранение статистики
C.DataStore = "ConquerraStats_v1"

-- VIP (геймпасс): MIRV + «месть», корона над страной, +10% золота
C.VIP = {
	PassId = 2089480879, -- ID геймпасса «👑 VIP — MIRV & Revenge»
	Price = 249,         -- цена в Robux (для показа в меню)
	GoldBonus = 0.10,    -- +10% к доходу золота
	StudioVIP = true,    -- в Studio все игроки VIP (для тестов)
}
-- бомбы как в браузерной Conquerra (радиусы пересчитаны под сетку 1032×516):
-- внутренний радиус — земля полностью сгорает, внешнее кольцо — сгорает половина клеток.
-- Атомная и водородная доступны всем, MIRV (рассыпается на боеголовки по всей стране цели) — только VIP.
C.Bomb = {
	Cooldown = 45,         -- перезарядка после любой бомбы (с)
	UnlockAt = 150,        -- бомбы доступны с 2:30 матча (рано не гриферить)
	TroopLoss = 1.0,       -- жертва теряет плотность войск × коэффициент за каждую клетку
	RevengeDiscount = 0.5, -- VIP: -50% цены по тому, кто напал на тебя
	RevengeWindow = 90,    -- ... за последние 90 с
}
C.Bombs = {
	{ Id = "Atom", Name = "Atom Bomb", Icon = "\u{2622}\u{FE0F}", Cost = 600000, Inner = 6, Outer = 15, Flight = 3, VIP = false,
		Desc = "Burns land in a small blast" },
	{ Id = "Hydrogen", Name = "Hydrogen Bomb", Icon = "\u{1F4A5}", Cost = 5000000, Inner = 40, Outer = 50, Flight = 4, VIP = false,
		Desc = "Huge blast \u{2014} wipes out a region" },
	{ Id = "MIRV", Name = "MIRV", Icon = "\u{1F680}", Cost = 25000000, Growth = 15000000, Flight = 5, VIP = true,
		Warheads = 30, Inner = 6, Outer = 9, Desc = "VIP: splits into 30 warheads over the whole enemy country" },
}
function C.BombDef(id)
	for _, b in ipairs(C.Bombs) do if b.Id == id then return b end end
end
-- цена бомбы (у MIRV растёт с каждым запуском в матче)
function C.BombCost(id, launched)
	local b = C.BombDef(id)
	if not b then return math.huge end
	return b.Cost + (b.Growth or 0) * (launched or 0)
end

-- формат чисел: 4.40K, 1.2M
function C.Fmt(n)
	n = math.floor(n or 0)
	if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
	if n >= 1e3 then return string.format("%.2fK", n / 1e3) end
	return tostring(n)
end

-- цена постройки с учётом уже построенных (built — таблица Built игрока или число):
-- города, порты и заводы дорожают вдвое (порты и заводы считаются вместе), остальное — на шаг
function C.BuildCost(def, built)
	local n = 0
	if type(built) == "table" then
		n = (built[def.Id] or 0) + (def.Shared and built[def.Shared] or 0)
	else
		n = built or 0
	end
	local c
	if def.Grow == "double" then c = def.Cost * 2 ^ math.min(n, 10) else c = def.Cost * (n + 1) end
	return math.floor(math.min(def.Max or math.huge, c))
end

-- золото за рейс торгового корабля (путь в клетках этой карты, как tradeShipGold в браузере)
function C.TradeGold(tiles)
	local d = tiles * 2
	return math.floor(75000 / (1 + math.exp(-0.03 * (d - C.Trade.ShortRange * 2))) + 50 * d)
end

function C.Building(id)
	for _, b in ipairs(C.Buildings) do if b.Id == id then return b end end
end

-- максимум войск и доходы (одинаково считаются на сервере и показываются на клиенте)
function C.MaxTroops(tiles, cities, kind)
	local bt = math.max(0, tiles) * C.Troops.TileScale
	local m = 2 * (bt ^ 0.6 * 1000 + 50000) / 10 + (cities or 0) * C.Troops.PerCity
	if kind == "bot" then m *= C.Troops.BotMax elseif kind == "nation" then m *= C.Troops.NationMax end
	return m
end
-- прирост в секунду (в показываемых единицах это ровно прирост браузера за тик)
function C.TroopRate(troops, max, kind)
	local add = (10 + (math.max(0, troops) * 10) ^ 0.73 / 4) * C.Troops.Mult * (1 - troops / math.max(1, max))
	if kind == "bot" then add *= C.Troops.BotRate elseif kind == "nation" then add *= C.Troops.NationRate end
	return add
end
-- пассивный доход: базовое золото + заводы за каждый связанный город (торговля начисляется отдельно)
function C.GoldRate(tiles, factories, ports, vip, links, kind)
	local g = (kind == "bot" and C.Gold.BotBase or C.Gold.Base) + (links or 0) * C.Gold.PerFactoryLink
	if vip then g *= 1 + C.VIP.GoldBonus end
	return g
end

return C
