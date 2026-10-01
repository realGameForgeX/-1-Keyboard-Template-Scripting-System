local DataServer = {}

-- // Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

-- // External Packages
local Packages = ReplicatedStorage:WaitForChild("Packages")
local InfiniteMath = require(Packages.InfiniteMath)
local DataFolder = Packages:WaitForChild("Data")
local DataService = require(DataFolder.DataService).server

-- Folders & Modules
local Utils = ReplicatedStorage:WaitForChild("Utils")
local Configs = Utils:WaitForChild("Configs")
local LevelConfig = require(Configs:WaitForChild("LevelConfig"))
local TreadmillConfig = require(Configs:WaitForChild("TreadmillConfig"))
local KeyboardConfig = require(Configs:WaitForChild("KeyboardConfig"))

-- // Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ToggleWalking = Remotes:WaitForChild("ToggleWalking")
local TreadmillAction = Remotes:WaitForChild("TreadmillAction")

-- // Variables
local ATTRIBUTE_PUSH_INTERVAL = 0
local TotalCharacters = #KeyboardConfig.Keys
local Randomizer = Random.new()

local WalkingPlayers = {}
local TreadmillPlayers = {}
local GamepassCache = {}
local lastSyncTime = {}
local lastAttributePush = {}

-- // Functions
local function SafeInfiniteMath(value: any): InfiniteMath.Number -- Converts to InfiniteMath
	if value == nil then return InfiniteMath.new(0) end
	if type(value) == "table" and type(value.GetSuffix) == "function" then
		return value
	end

	local ok, result = pcall(InfiniteMath.new, value)
	if ok and result then
		return result
	end

	warn("[DataServer] Invalid number: " .. tostring(value))
	return InfiniteMath.new(0)
end

LevelConfig.SafeInfiniteMath = SafeInfiniteMath

local function HasGamepass(player: Player, gamepassId: number): boolean -- Checks if player owns a gamepass
	if not gamepassId or gamepassId <= 0 then return false end

	GamepassCache[player] = GamepassCache[player] or {}
	if GamepassCache[player][gamepassId] ~= nil then
		return GamepassCache[player][gamepassId]
	end

	local ok, hasPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
	end)

	if not ok then
		warn("[DataServer] Gamepass check failed for " .. player.Name .. ": " .. tostring(hasPass))
		return false
	end

	GamepassCache[player][gamepassId] = hasPass
	return hasPass
end

local function IsPointInZone(point: Vector3, part: BasePart): boolean -- Checks if a point is inside a part
	local localPoint = part.CFrame:PointToObjectSpace(point)
	local halfSize = part.Size * 0.5
	return math.abs(localPoint.X) <= halfSize.X
		and math.abs(localPoint.Y) <= halfSize.Y
		and math.abs(localPoint.Z) <= halfSize.Z
end

function DataServer:GetXP(player: Player) -- Gets player's XP
	if not player then return InfiniteMath.new(0) end
	local profile = DataService:getProfile(player)
	if not profile or not profile.Data or profile.Data.XP == nil then
		return InfiniteMath.new(0)
	end
	return SafeInfiniteMath(profile.Data.XP)
end

function DataServer:UpdateWalkspeed(player: Player) -- Updates player's walkspeed
	if not player then return end
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid")
	if not humanoid then return end

	local ok, currentXP = pcall(function()
		return self:GetXP(player)
	end)
	if not ok then return end

	local level = LevelConfig.GetLevelFromXP(currentXP)
	level = typeof(level) == "number" and level or 1
	humanoid.WalkSpeed = 16 + (2 * (level - 1))
end

function DataServer:CommitXP(player: Player, newXP: InfiniteMath.Number, previousXP: InfiniteMath.Number, forceSync: boolean?)
	if type(newXP.first) ~= "number" or type(newXP.second) ~= "number" or newXP.first ~= newXP.first or newXP.second ~= newXP.second then
		warn("[DataServer] Malformed XP data for " .. player.Name)
		return false
	end

	local profile = DataService:getProfile(player)
	if profile and profile.Data then
		profile.Data.XP = { newXP.first, newXP.second }
	end

	local now = os.clock()
	local levelChanged = LevelConfig.GetLevelFromXP(previousXP) ~= LevelConfig.GetLevelFromXP(newXP)
	local shouldPush = forceSync or levelChanged or ATTRIBUTE_PUSH_INTERVAL <= 0 or (now - (lastAttributePush[player] or 0)) >= ATTRIBUTE_PUSH_INTERVAL

	if shouldPush then
		player:SetAttribute("XPFirst", newXP.first)
		player:SetAttribute("XPSecond", newXP.second)
		lastAttributePush[player] = now
	end

	self:UpdateWalkspeed(player)

	if forceSync or (now - (lastSyncTime[player] or 0)) >= 3 then
		lastSyncTime[player] = now
		DataService:set(player, "XP", { newXP.first, newXP.second })
	end

	return true
end

function DataServer:AddXP(player: Player, amount: any, forceSync: boolean?) -- Adds XP to player
	if not player or not player.Parent then return end
	local currentXP = self:GetXP(player)
	local addAmount = SafeInfiniteMath(amount)

	local ok, newXP = pcall(function()
		return currentXP + addAmount
	end)

	if not ok or not newXP then
		warn("[DataServer] Failed to add XP for " .. player.Name)
		return
	end

	self:CommitXP(player, newXP, currentXP, forceSync)
end

function DataServer:SetXP(player: Player, amount: any) -- Sets player's XP
	if not player or not player.Parent then return end
	local currentXP = self:GetXP(player)
	local newXP = SafeInfiniteMath(amount)
	self:CommitXP(player, newXP, currentXP, true)
end

function DataServer:ResetXP(player: Player) -- Resets player's XP
	self:SetXP(player, 0)
end

function DataServer:GetTotalSpeedMultiplier(player: Player): number -- Returns player's total speed multiplier
	if not player or not player.Parent then return 1 end
	local multipliers = DataService:get(player, "SpeedMultipliers") or {}
	local totalMultiplier = 1
	for _, value in pairs(multipliers) do
		if typeof(value) == "number" then
			totalMultiplier *= value
		end
	end
	return totalMultiplier
end

function DataServer:CreateZone(ZoneNumber: number) -- Creates a zone
	local zone = workspace.Zones:FindFirstChild(ZoneNumber)
	local zoneData = KeyboardConfig.Zones[ZoneNumber]
	if not zone or not zoneData then return end

	for _, key in zone:GetChildren() do
		if not key:IsA("BasePart") then continue end
		key:FindFirstChildOfClass("SurfaceGui"):FindFirstChildOfClass("TextLabel").Text = KeyboardConfig.Keys[Randomizer:NextInteger(1, TotalCharacters)]
		key.Color = zoneData.Colors[Randomizer:NextInteger(1, #zoneData.Colors)]
	end
end

function DataServer:SetupTreadmills() -- Sets up treadmills
	local treadmillsFolder = workspace:WaitForChild("Treadmills")
	for _, treadmill in treadmillsFolder:GetChildren() do
		local treadmillData = TreadmillConfig.Treadmills[tonumber(treadmill.Name)]
		if not treadmillData then continue end

		local billboard = treadmill:WaitForChild("Billboard"):WaitForChild("Title")
		local xpText = tostring(treadmillData.XPMultiplier) .. "x XP"
		billboard.Main.Title.Text = xpText
		billboard.Main.Title.Color.Text = xpText

		local reqText
		if treadmillData.RequiresGamepass then
			reqText = "Req: GAMEPASS"
		else
			reqText = treadmillData.Requirement > 0 and "Req: " .. InfiniteMath.new(treadmillData.Requirement):GetSuffix() .. " XP" or "Req: FREE"
		end

		billboard.Requirement.Title.Text = reqText
		billboard.Requirement.Title.Color.Text = reqText
	end
end

function DataServer:OnPlayerAdded(player: Player) -- Handles player joining
	DataService:waitForData(player)
	if not player.Parent then return end

	local currentXP = self:GetXP(player)
	player:SetAttribute("XPFirst", currentXP.first)
	player:SetAttribute("XPSecond", currentXP.second)
	lastAttributePush[player] = os.clock()

	player.CharacterAdded:Connect(function()
		self:UpdateWalkspeed(player)
	end)

	if player.Character then
		self:UpdateWalkspeed(player)
	end
end

function DataServer:OnPlayerRemoving(player: Player) -- Cleanup on leave
	WalkingPlayers[player] = nil
	TreadmillPlayers[player] = nil
	GamepassCache[player] = nil
	lastSyncTime[player] = nil
	lastAttributePush[player] = nil
end

function DataServer:SetupRemotes() -- Setup remote events
	ToggleWalking.OnServerInvoke = function(player: Player, toggle: boolean)
		local character = player.Character
		local humanoid = character and character:FindFirstChild("Humanoid")
		if not humanoid or humanoid.MoveDirection.Magnitude == 0 then
			WalkingPlayers[player] = nil
			return false
		end
		WalkingPlayers[player] = toggle or nil
		return toggle
	end

	TreadmillAction.OnServerInvoke = function(player: Player, action: boolean, treadmillName: string)
		if not action then
			TreadmillPlayers[player] = nil
			return true
		end

		DataService:waitForData(player)
		local currentXP = self:GetXP(player)
		local treadmillData = TreadmillConfig.Treadmills[tonumber(treadmillName)]
		if not treadmillData then return false end

		local reqXP = InfiniteMath.new(treadmillData.Requirement or 0)
		if reqXP > InfiniteMath.new(0) and currentXP < reqXP then
			return false
		end

		if treadmillData.RequiresGamepass and not HasGamepass(player, treadmillData.GamepassId) then
			if treadmillData.GamepassId > 0 then
				MarketplaceService:PromptGamePassPurchase(player, treadmillData.GamepassId)
			end
			return false
		end

		TreadmillPlayers[player] = tonumber(treadmillName)
		return true
	end
end

function DataServer:StartWalkingLoop() -- Handles XP gain
	task.spawn(function()
		while true do
			task.wait(LevelConfig.Cooldown)
			for player, _ in WalkingPlayers do
				if TreadmillPlayers[player] then continue end

				local currentXP = self:GetXP(player)
				local level = LevelConfig.GetLevelFromXP(currentXP)
				local speedMultiplier = self:GetTotalSpeedMultiplier(player)
				local xpGained = InfiniteMath.new(level) * LevelConfig.XPIncrement * speedMultiplier

				self:AddXP(player, xpGained)
			end
		end
	end)
end

function DataServer:StartTreadmillLoop() -- Handles XP gain from treadmills
	local treadmillsFolder = workspace:WaitForChild("Treadmills")
	task.spawn(function()
		while true do
			task.wait(TreadmillConfig.Cooldown)
			for player, treadmillIndex in TreadmillPlayers do
				local treadmill = TreadmillConfig.Treadmills[treadmillIndex]
				if not treadmill then
					TreadmillPlayers[player] = nil
					continue
				end

				local character = player.Character
				local hrp = character and character:FindFirstChild("HumanoidRootPart")
				local treadmillModel = treadmillsFolder:FindFirstChild(tostring(treadmillIndex))
				local hitbox = treadmillModel and treadmillModel:FindFirstChild("Hitbox")

				if not hrp or not hitbox or not IsPointInZone(hrp.Position, hitbox) then
					TreadmillPlayers[player] = nil
					continue
				end

				local currentXP = self:GetXP(player)
				local level = LevelConfig.GetLevelFromXP(currentXP)
				local speedMultiplier = self:GetTotalSpeedMultiplier(player)
				local baseXP = InfiniteMath.new(level) * LevelConfig.XPIncrement
				local totalXPGained = baseXP * treadmill.XPMultiplier * speedMultiplier

				self:AddXP(player, totalXPGained)
			end
		end
	end)
end

-- // Initialize
function DataServer:Init()
	DataService:init({
		template = {
			XP = {0, 0},
			Rebirths = 0,
			SpeedMultipliers = {
				RebirthMultiplier = 1,
				GamepassMultiplier = 1,
			},
		},
		useMock = false
	})

	Players.PlayerAdded:Connect(function(player)
		self:OnPlayerAdded(player)
	end)

	for _, existingPlayer in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:OnPlayerAdded(existingPlayer)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		self:OnPlayerRemoving(player)
	end)

	self:SetupRemotes()
	self:SetupTreadmills()

	for i, _ in KeyboardConfig.Zones do
		self:CreateZone(i)
	end

	self:StartWalkingLoop()
	self:StartTreadmillLoop()
end

return DataServer
