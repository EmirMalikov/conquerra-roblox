--[[
	EXCERPT from client/UI.lua (two parts, ~70 of 1323 lines) — not a complete module.

	The attacks panel in the top-left corner: every running front and troop boat, outgoing in green and
	incoming in red, with a recall button (↩) on your own ones. Rows are pooled and updated from the
	"Me" payload the server sends 4 times a second.

	Context provided by the rest of UI.lua: mk/panel/text/button/stroke/corner/pad (UI helpers), refs,
	hud, board, topY, S (client State), Config, sfx, colour constants.
]]

-- 1) building the panel (inside buildTop)

	-- левый верхний угол: идущие атаки (мои — зелёные, на меня — красные), как панель атак в браузере
	attackPanel = panel({ Name = "Attacks", Size = UDim2.fromOffset(290, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(12, 68), BackgroundColor3 = BG, BackgroundTransparency = 0.1, Visible = false }, hud)
	pad(attackPanel, 10)
	mk("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, attackPanel)
	refs.AttackTitle = text({ Size = UDim2.new(1, 0, 0, 18), Text = "⚔ ATTACKS", Font = HEAD, TextSize = 15, LayoutOrder = 0, RichText = true }, attackPanel)
	refs.AttackRows = {}
	for k = 1, 9 do
		local row = mk("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, LayoutOrder = k, Visible = false }, attackPanel)
		local label = text({ Size = UDim2.new(1, -30, 1, 0), Text = "", Font = BOLD, TextSize = 14, RichText = true, TextTruncate = Enum.TextTruncate.AtEnd }, row)
		-- иконка отзыва армии (только у своих атак и десантов)
		local btn = button({ Size = UDim2.fromOffset(26, 22), Position = UDim2.new(1, -26, 0, 0), Text = "↩", Font = HEAD, TextSize = 16, TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = Color3.fromRGB(196, 72, 72), Radius = 7, Visible = false }, row)
		stroke(btn, Color3.fromRGB(255, 150, 150), 1, 0.3)
		local tip = text({ Size = UDim2.fromOffset(268, 22), Position = UDim2.new(1, 18, 0, 0), Text = "↩ Recall army — 25% of the troops are lost", TextSize = 13, BackgroundColor3 = BG, BackgroundTransparency = 0.05, TextXAlignment = Enum.TextXAlignment.Center, Visible = false, ZIndex = 5 }, row)
		corner(tip, 6)
		local r = { Row = row, Label = label, Btn = btn, Act = nil, Tip = tip }
		btn.MouseButton1Click:Connect(function()
			if not r.Act then return end
			sfx("click")
			S.Act("Retreat", r.Act)
			btn.Visible = false
		end)
		btn.MouseEnter:Connect(function() tip.Visible = true end)
		btn.MouseLeave:Connect(function() tip.Visible = false end)
		refs.AttackRows[k] = r
	end

-- 2) updating it (inside onMe, called for every "Me" payload)

	-- панель атак: сколько войск и какую страну атакую, сколько атакуют меня
	do
		local rows = {}
		local outSum, inSum = 0, 0
		local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
		-- строка: { текст, что отправить при отзыве (только у своих) }
		for _, a in ipairs(me.Out or {}) do
			outSum += a.T
			table.insert(rows, { '<font color="#6EF07A">⚔ ' .. Config.Fmt(a.T) .. '</font>  <font color="#96A2BE">→</font> ' .. esc(a.N or "?"), { Def = a.Id } })
		end
		for _, a in ipairs(me.BoatsOut or {}) do
			outSum += a.T
			if a.R then
				table.insert(rows, { '<font color="#96A2BE">↩ ⛵ ' .. Config.Fmt(a.T) .. '  sailing home</font>', nil })
			else
				table.insert(rows, { '<font color="#6EF07A">⛵ ' .. Config.Fmt(a.T) .. '</font>  <font color="#96A2BE">→</font> ' .. esc(a.N or "?"), { Boat = a.B } })
			end
		end
		for _, a in ipairs(me.In or {}) do
			inSum += a.T
			table.insert(rows, { '<font color="#FF6868">⚠ ' .. Config.Fmt(a.T) .. '</font>  <font color="#96A2BE">←</font> ' .. esc(a.N or "?"), nil })
		end
		for _, a in ipairs(me.BoatsIn or {}) do
			inSum += a.T
			table.insert(rows, { '<font color="#FF6868">⛵ ' .. Config.Fmt(a.T) .. '</font>  <font color="#96A2BE">←</font> ' .. esc(a.N or "?"), nil })
		end
		local title = "⚔ ATTACKS"
		if outSum > 0 then title ..= '   <font color="#6EF07A">' .. Config.Fmt(outSum) .. "</font>" end
		if inSum > 0 then title ..= '   <font color="#FF6868">⚠ ' .. Config.Fmt(inSum) .. "</font>" end
		refs.AttackTitle.Text = title
		for k, r in ipairs(refs.AttackRows) do
			local e = rows[k]
			r.Row.Visible = e ~= nil
			if e then
				r.Label.Text = e[1]
				r.Act = e[2]
				r.Btn.Visible = e[2] ~= nil
				if not r.Btn.Visible then r.Tip.Visible = false end
			else
				r.Tip.Visible = false
			end
		end
		attackPanel.Visible = me.Alive and #rows > 0 and S.Game.State == "Play"
		attackPanel.Position = UDim2.fromOffset(12, board.Visible and (topY + 390) or (topY + 54))
		-- дверь в меню: только когда ты не в игре (проиграл / смотришь) или матч закончился
		refs.Door.Visible = not me.Alive or S.Game.State == "End"
	end
