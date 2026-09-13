-- Connected Discord-GitHub | Discord: @game_forge_x | Roblox: dodlegend_6

local DataServer = {}
DataServer.__index = DataServer

--------------------------------------------------------------------------------
-- // SERVICES & MODULE DEPENDENCIES
--------------------------------------------------------------------------------
-- Services
local Players = game:GetService("Players") -- Service managing player instances and session lifecycle events
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Shared container accessible by server and client for remote assets/modules
local MarketplaceService = game:GetService("MarketplaceService") -- Handles gamepass checks and product purchases

-- External Open-Source Packages (Require credit & explicit structural logging)
local Packages = ReplicatedStorage:WaitForChild("Packages") -- Directory housing external/third-party framework packages
local InfiniteMath = require(Packages.InfiniteMath) -- Open-source BigNumber library for unlimited numerical scaling beyond 64-bit limits
local DataFolder = Packages:WaitForChild("Data") -- Storage folder for server data management architecture
local DataService = require(DataFolder.DataService).server -- Open-source DataStore wrapper (ProfileService abstraction) for safe persistent storage

-- Game Configuration Modules
local Utils = ReplicatedStorage:WaitForChild("Utils") -- Helper utilities directory
local Configs = Utils:WaitForChild("Configs") -- Central configuration module directory
local LevelConfig = require(Configs:WaitForChild("LevelConfig")) -- Module defining XP thresholds, leveling curves, and cooldowns
local TreadmillConfig = require(Configs:WaitForChild("TreadmillConfig")) -- Config map containing treadmill multipliers, XP limits, and gamepass IDs
local KeyboardConfig = require(Configs:WaitForChild("KeyboardConfig")) -- Configuration defining physical key visual zones and key bindings

-- Networking Interfaces
local Remotes = ReplicatedStorage:WaitForChild("Remotes") -- Replicated container housing RemoteEvent and RemoteFunction signals
local ToggleWalking = Remotes:WaitForChild("ToggleWalking") -- RemoteFunction invoked by client when starting/stopping ambient movement
local TreadmillAction = Remotes:WaitForChild("TreadmillAction") -- RemoteFunction invoked when stepping onto or off a treadmill zone

--------------------------------------------------------------------------------
-- // STATE & CONSTANTS
--------------------------------------------------------------------------------
local ATTRIBUTE_PUSH_INTERVAL = 0 -- Throttle delay (seconds) between syncing player attributes to avoid network bandwidth saturation
local TotalCharacters = #KeyboardConfig.Keys -- Dynamic length lookup of configured character keys for matrix generation
local Randomizer = Random.new() -- Dedicated, performance-optimized pseudo-random number generator instance

-- Internal Server Trackers (Memory Caching)
local WalkingPlayers = {} -- Hash set tracking players currently in active ambient walking state: [Player] = boolean
local TreadmillPlayers = {} -- Hash set tracking players currently on treadmills: [Player] = treadmillIndex
local GamepassCache = {} -- Session cache preventing repeated asynchronous MarketplaceService queries: [Player] = {[GamepassId] = boolean}
local lastSyncTime = {} -- Timestamp map throttling DataStore commit operations: [Player] = os.clock()
local lastAttributePush = {} -- Timestamp map throttling attribute replication calls: [Player] = os.clock()

--------------------------------------------------------------------------------
-- // PRIVATE UTILITY FUNCTIONS
--------------------------------------------------------------------------------

-- Safely casts arbitrary values into valid InfiniteMath BigNumber instances to prevent crash bugs
local function SafeInfiniteMath(value: any): InfiniteMath.Number
	if value == nil then
		return InfiniteMath.new(0) -- Default construct zero if input is nil
	end
	-- Structural check verifying if value is already an InfiniteMath object by testing method presence
	if (typeof(value) == "table" or typeof(value) == "userdata") and typeof(value.GetSuffix) == "function" then
		return value
	end
	-- Protected call guard preventing server runtime failure if string parsing fails
	local ok, result = pcall(function()
		return InfiniteMath.new(value)
	end)
	if ok and result then
		return result
	end
	warn(string.format("[DataServer] SafeInfiniteMath failed conversion for (%s: %s) — fallback to 0.", typeof(value), tostring(value)))
	return InfiniteMath.new(0)
end

LevelConfig.SafeInfiniteMath = SafeInfiniteMath -- Inject conversion utility into LevelConfig module for shared reference

-- Caches and checks gamepass ownership asynchronously using MarketplaceService
local function HasGamepass(player: Player, gamepassId: number): boolean
	if gamepassId == 0 then return false end -- Return false immediately for non-gamepass IDs

	GamepassCache[player] = GamepassCache[player] or {} -- Initialize player cache table if missing
	if GamepassCache[player][gamepassId] ~= nil then
		return GamepassCache[player][gamepassId] -- Return fast cached result if available
	end

	local hasPass = false
	local success, err = pcall(function()
		-- Asynchronous API call to Roblox backend to verify asset ownership
		hasPass = MarketplaceService:UserOwnsGamePassAsync(player.UserId, gamepassId)
	end)

	if not success then
		warn("Failed to check gamepass ownership for player:", player.Name, err)
		return false
	end

	GamepassCache[player][gamepassId] = hasPass -- Store result in memory cache
	return hasPass
end

-- Checks if a world Vector3 coordinate is within a rectangular BasePart bounding box using CFrame matrix space transformation
local function IsPointInZone(point: Vector3, part: BasePart): boolean
	local localPoint = part.CFrame:PointToObjectSpace(point) -- Transform world position into Part local coordinate space
	local halfSize = part.Size * 0.5 -- Calculate bounding extents (radius per axis)
	-- Coordinate axis check evaluating if the point resides within all three dimensions
	return math.abs(localPoint.X) <= halfSize.X
		and math.abs(localPoint.Y) <= halfSize.Y
		and math.abs(localPoint.Z) <= halfSize.Z
end

--------------------------------------------------------------------------------
-- // CLASS METHODS (DATA SERVER ENGINE)
--------------------------------------------------------------------------------

-- Retrieves a player's current XP as an InfiniteMath Number object from their active ProfileService session
function DataServer:GetXP(player: Player)
	if not player then return InfiniteMath.new(0) end
	local profile = DataService:getProfile(player) -- Read active profile data table from DataService wrapper
	if not profile or not profile.Data or profile.Data.XP == nil then
		return InfiniteMath.new(0)
	end
	return SafeInfiniteMath(profile.Data.XP)
end

-- Dynamically updates the Humanoid WalkSpeed property based on player's current XP level
function DataServer:UpdateWalkspeed(player: Player)
	if not player then return end
	local character = player.Character
	local humanoid = character and character:FindFirstChild("Humanoid") -- Locate character Humanoid component
	if not humanoid then return end

	local ok, currentXP = pcall(function()
		return self:GetXP(player)
	end)
	if not ok then return end

	local level = LevelConfig.GetLevelFromXP(currentXP) -- Compute mathematical level scaling
	level = typeof(level) == "number" and level or 1
	humanoid.WalkSpeed = 16 + (2 * (level - 1)) -- Linear WalkSpeed formula scaling base 16 speed
end

-- Atomic commit method writing XP updates to profile memory, replicating attributes, and pushing to DataStore
function DataServer:CommitXP(player: Player, newXP: InfiniteMath.Number, previousXP: InfiniteMath.Number, forceSync: boolean?)
	-- Validation guard ensuring array components are valid numbers and non-NaN
	if typeof(newXP.first) ~= "number" or typeof(newXP.second) ~= "number"
		or newXP.first ~= newXP.first or newXP.second ~= newXP.second then
		warn("[DataServer] CommitXP: Refusing to save malformed result for " .. player.Name, newXP)
		return false
	end

	local profile = DataService:getProfile(player)
	if profile and profile.Data then
		profile.Data.XP = {newXP.first, newXP.second} -- Persist serializable table structure to ProfileService session
	end

	local levelChanged = LevelConfig.GetLevelFromXP(previousXP) ~= LevelConfig.GetLevelFromXP(newXP)
	local now = os.clock()

	-- Evaluate whether networked attribute sync should fire based on level change or interval throttles
	local shouldPushAttributes = forceSync
		or levelChanged
		or ATTRIBUTE_PUSH_INTERVAL <= 0
		or not lastAttributePush[player]
		or (now - lastAttributePush[player]) >= ATTRIBUTE_PUSH_INTERVAL

	if shouldPushAttributes then
		player:SetAttribute("XPFirst", newXP.first) -- Set network-replicated attribute for UI bindings
		player:SetAttribute("XPSecond", newXP.second) -- Set second scientific floating component
		lastAttributePush[player] = now
	end

	self:UpdateWalkspeed(player) -- Apply updated movement metrics

	-- Throttled sync operation writing session data directly down to DataService persistence pipeline
	if forceSync or not lastSyncTime[player] or (now - lastSyncTime[player]) >= 3 then
		lastSyncTime[player] = now
		DataService:set(player, "XP", {newXP.first, newXP.second})
	end

	return true
end

-- Primary API entry point to award XP to a player safely
function DataServer:AddXP(player: Player, amount: any, forceSync: boolean?)
	if not player or not player.Parent then return end
	local currentXP = self:GetXP(player)
	local addAmount = SafeInfiniteMath(amount)

	local ok, newXP = pcall(function()
		return currentXP + addAmount -- Perform BigNumber addition operator overload
	end)

	if not ok or newXP == nil then
		warn("[DataServer] AddXP: InfiniteMath addition failed for " .. player.Name, newXP)
		return
	end

	self:CommitXP(player, newXP, currentXP, forceSync)
end

-- Direct non-additive assignment method for XP (e.g. Admin commands, Rebirth resets)
function DataServer:SetXP(player: Player, amount: any)
	if not player or not player.Parent then return end
	local currentXP = self:GetXP(player)
	local newXP = SafeInfiniteMath(amount)
	self:CommitXP(player, newXP, currentXP, true)
end

-- Resets player XP back to base state
function DataServer:ResetXP(player: Player)
	self:SetXP(player, 0)
end

-- Aggregates speed multipliers present in player profile session data
function DataServer:GetTotalSpeedMultiplier(player: Player): number
	if not player or not player.Parent then return 1 end
	local multipliers = DataService:get(player, "SpeedMultipliers") or {}
	local totalMultiplier = 1
	for _, value in pairs(multipliers) do -- Iterate through multiplier list
		if typeof(value) == "number" then
			totalMultiplier *= value -- Accumulate geometric product of multipliers
		end
	end
	return totalMultiplier
end

--------------------------------------------------------------------------------
-- // MAP & ENVIRONMENT MANAGEMENT
--------------------------------------------------------------------------------

-- Constructs dynamic physical interactive keyboard zones in Workspace
function DataServer:CreateZone(ZoneNumber: number)
	local zone = workspace.Zones:FindFirstChild(ZoneNumber)
	if not zone then return end
	local zoneData = KeyboardConfig.Zones[ZoneNumber]
	if not zoneData then return end

	for _, key in zone:GetChildren() do -- Loop through every physical part inside zone model
		if not key:IsA("BasePart") then continue end
		-- Apply randomized configuration characters and colors to SurfaceGui visual instances
		key:FindFirstChildOfClass("SurfaceGui"):FindFirstChildOfClass("TextLabel").Text = KeyboardConfig.Keys[Randomizer:NextInteger(1, TotalCharacters)]
		key.Color = zoneData.Colors[Randomizer:NextInteger(1, #zoneData.Colors)]
	end
end

-- Initializes Workspace Treadmill billboards with live multipliers and requirement text
function DataServer:SetupTreadmills()
	local treadmillsFolder = workspace:WaitForChild("Treadmills")
	for _, treadmill in treadmillsFolder:GetChildren() do -- Iterate through all physical treadmill workspace models
		local treadmillData = TreadmillConfig.Treadmills[tonumber(treadmill.Name)]
		if not treadmillData then continue end

		local billboard = treadmill:WaitForChild("Billboard"):WaitForChild("Title")
		billboard.Main.Title.Text = `{treadmillData.XPMultiplier}x XP`
		billboard.Main.Title.Color.Text = `{treadmillData.XPMultiplier}x XP`

		if treadmillData.RequiresGamepass then
			billboard.Requirement.Title.Text = "Req: GAMEPASS"
			billboard.Requirement.Title.Color.Text = "Req: GAMEPASS"
		else
			billboard.Requirement.Title.Text = treadmillData.Requirement > 0 and `Req: {InfiniteMath.new(treadmillData.Requirement):GetSuffix()} XP` or "Req: FREE"
			billboard.Requirement.Title.Color.Text = billboard.Requirement.Title.Text
		end
	end
end

--------------------------------------------------------------------------------
-- // NETWORKING & LIFECYCLE HANDLERS
--------------------------------------------------------------------------------

-- Session setup method triggered when a player enters the experience
function DataServer:OnPlayerAdded(player: Player)
	DataService:waitForData(player) -- Yield thread until DataService loads profile from DataStore backend
	if not player.Parent then return end

	local currentXP = self:GetXP(player)
	player:SetAttribute("XPFirst", currentXP.first) -- Initialize networked UI attributes
	player:SetAttribute("XPSecond", currentXP.second)
	lastAttributePush[player] = os.clock()

	player.CharacterAdded:Connect(function() -- Attach spawn handler for character respawns
		self:UpdateWalkspeed(player)
	end)

	if player.Character then
		self:UpdateWalkspeed(player)
	end
end

-- Cleanup memory arrays when player leaves to prevent memory leaks
function DataServer:OnPlayerRemoving(player: Player)
	WalkingPlayers[player] = nil
	TreadmillPlayers[player] = nil
	GamepassCache[player] = nil
	lastSyncTime[player] = nil
	lastAttributePush[player] = nil
end

-- Binds network RemoteFunctions for client communication
function DataServer:SetupRemotes()
	-- Listens to client toggle requests for open-world walking state
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

	-- Listens to client requests to step onto/off treadmills
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
			return false -- Requirement guard: player lacks necessary XP level
		end

		if treadmillData.RequiresGamepass then
			if not HasGamepass(player, treadmillData.GamepassId) then
				if treadmillData.GamepassId > 0 then
					MarketplaceService:PromptGamePassPurchase(player, treadmillData.GamepassId) -- Open native purchase modal
				end
				return false
			end
		end

		TreadmillPlayers[player] = tonumber(treadmillName)
		return true
	end
end

--------------------------------------------------------------------------------
-- // CONCURRENT LOOP THREADS
--------------------------------------------------------------------------------

-- Asynchronous tick loop rewarding XP for open-world walking state
function DataServer:StartWalkingLoop()
	task.spawn(function()
		while true do
			task.wait(LevelConfig.Cooldown) -- Yield execution per global loop delay cycle
			for player, _ in WalkingPlayers do -- Loop through every player registered in active walking state
				if TreadmillPlayers[player] then continue end -- Skip player if currently training on a treadmill

				local currentXP = self:GetXP(player)
				local level = LevelConfig.GetLevelFromXP(currentXP)
				local speedMultiplier = self:GetTotalSpeedMultiplier(player)
				local xpGained = InfiniteMath.new(level) * LevelConfig.XPIncrement * speedMultiplier

				self:AddXP(player, xpGained) -- Award calculated reward
			end
		end
	end)
end

-- Asynchronous tick loop evaluating spatial physical contact and awarding boosted treadmill XP
function DataServer:StartTreadmillLoop()
	local treadmillsFolder = workspace:WaitForChild("Treadmills")
	task.spawn(function()
		while true do
			task.wait(TreadmillConfig.Cooldown) -- Yield execution based on treadmill cycle speed
			for player, treadmillIndex in TreadmillPlayers do -- Loop through every player currently on a treadmill
				local treadmill = TreadmillConfig.Treadmills[treadmillIndex]
				if not treadmill then
					TreadmillPlayers[player] = nil
					continue
				end

				local character = player.Character
				local hrp = character and character:FindFirstChild("HumanoidRootPart")
				local treadmillModel = treadmillsFolder:FindFirstChild(tostring(treadmillIndex))
				local hitbox = treadmillModel and treadmillModel:FindFirstChild("Hitbox")

				-- Verify continuous physical presence inside bounding hitbox via vector transformation
				if not hrp or not hitbox or not IsPointInZone(hrp.Position, hitbox) then
					TreadmillPlayers[player] = nil -- Evict player from state tracker if they stepped outside bounding region
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

--------------------------------------------------------------------------------
-- // MODULE BOOTSTRAP INITIALIZER
--------------------------------------------------------------------------------

-- Single entry point initializing DataService, event signals, workspace models, and background loops
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
		useMock = false -- Set to true for local Studio testing without live DataStores
	})

	-- Attach Player Lifecycle Events
	Players.PlayerAdded:Connect(function(player)
		self:OnPlayerAdded(player)
	end)

	-- Handle players who loaded before server script execution completed
	for _, existingPlayer in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:OnPlayerAdded(existingPlayer)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		self:OnPlayerRemoving(player)
	end)

	-- Component Setup
	self:SetupRemotes()
	self:SetupTreadmills()

	for i, _ in KeyboardConfig.Zones do -- Loop through configured keyboard zones to generate initial map elements
		self:CreateZone(i)
	end

	-- Fire concurrent thread loops
	self:StartWalkingLoop()
	self:StartTreadmillLoop()
end

return DataServer
