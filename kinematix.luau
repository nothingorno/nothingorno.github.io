--!strict
--[[
	 _________________.            __                    __                   ___________________  
	╱  _____╱__ _╲_ │__   _______╱  │_____________ _╱  │_  ____╲_  _____╱╲   ╲╱  ╱
	╲_____  ╲│  │  ╲ __ ╲ ╱  ___╱╲   __╲_  __ ╲__  ╲╲   __╲╱ __ ╲│   __)   ╲   _╱  
	╱      ╲  │  ╱ ╲_╲ ╲╲___ ╲  │  │  │  │ ╲╱╱ __ ╲│  │ ╲  ___╱│   ╲    ╱     ╲  
	╱_______  ╱____╱│___  ____  > │__│  │__│  (____  ╱__│  ╲___  >___  ╱   ╱___╱╲  ╲
	        ╲╱      ╲╱     ╲╱                 ╲╱          ╲╱    ╲╱           ╲_╱
	
	SubstrateFX is made by NothingOrNo Labs. 
--]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local SubstrateFX = {}
SubstrateFX.__index = SubstrateFX

-- Engine Constants & Unit Conversion Factors
SubstrateFX.KG_PER_RMU = 0.45359237 -- Fixed RMU to KG ratio
SubstrateFX.STUDS_PER_METER = 0.28
SubstrateFX.METERS_PER_STUD = 1 / 0.28
SubstrateFX.DEFAULT_DENSITY = 0.7
SubstrateFX.AIR_DENSITY_KG_M3 = 1.225
SubstrateFX.GRAVITY_ACCEL_MS2 = 9.81
SubstrateFX.CHARACTER_DENSITY_SCALER = 0.32
SubstrateFX.BASELINE_WEIGHT_KG = 70.0
SubstrateFX.DEFAULT_WALKSPEED = 16.0
SubstrateFX.DEFAULT_JUMP_HEIGHT = 7.2
SubstrateFX.MIN_HUMAN_MASS_KG = 30.0
SubstrateFX.MAX_HUMAN_MASS_KG = 350.0
SubstrateFX.MIN_WALKSPEED = 4.0
SubstrateFX.MAX_WALKSPEED = 36.0
SubstrateFX.MIN_JUMP_HEIGHT = 1.5
SubstrateFX.MAX_JUMP_HEIGHT = 22.0
SubstrateFX.HPC_UPDATE_INTERVAL = 1 / 30
SubstrateFX.HPC_GRAVITY_MULTIPLIER = 10.0
SubstrateFX.WS_STRESS_THRESHOLD = 0.05
SubstrateFX.ATMOSPHERE_SCALE_HEIGHT = 8500
SubstrateFX.SEA_LEVEL_PRESSURE = 101325
SubstrateFX.MOLAR_MASS_AIR = 0.0289644
SubstrateFX.UNIVERSAL_GAS_CONSTANT = 8.31447

-- Safe Mode State Property
SubstrateFX.SafeModeActive = false

local weightCache = {}
local comIndicatorCache = {}
local materialYieldStrengths = {
	[Enum.Material.Wood] = 40,
	[Enum.Material.WoodPlanks] = 35,
	[Enum.Material.Concrete] = 120,
	[Enum.Material.Brick] = 80,
	[Enum.Material.CorrodedMetal] = 150,
	[Enum.Material.DiamondPlate] = 250,
	[Enum.Material.Glass] = 15,
	[Enum.Material.Ice] = 5,
	[Enum.Material.Plastic] = 50,
	[Enum.Material.SmoothPlastic] = 50,
	[Enum.Material.Metal] = 200,
}

local materialDensities = {
	[Enum.Material.Wood] = 700,
	[Enum.Material.Concrete] = 2400,
	[Enum.Material.Brick] = 1900,
	[Enum.Material.Metal] = 7850,
	[Enum.Material.Glass] = 2500,
	[Enum.Material.Plastic] = 900,
}

export type WSNode = {
	Part: BasePart,
	Vertices: { Vector3 },
	Normals: { Vector3 },
	StressFactor: number,
	DominantAxis: Vector3,
	CenterOfMassOffset: Vector3,
	MassKg: number,
	AccruedFatigue: number,
	TemperatureCelsius: number,
	IsSubmerged: boolean,
	BuoyancyForce: Vector3,
	ThermodynamicConductionRate: number,
	AerodynamicCenter: Vector3,
	StructuralHealth: number,
	JointConstraints: { Constraint },
}

export type HPCController = {
	Model: Model,
	Active: boolean,
	Nodes: { [BasePart]: WSNode },
	HeartbeatConn: RBXScriptConnection?,
	WindVector: Vector3,
	GlobalTemperature: number,
	FluidLevelY: number,
	EnableDestruction: boolean,
	OnPartFractured: BindableEvent?,
}

-- =========================================================================
-- SAFE MODE UTILITIES
-- =========================================================================

function SubstrateFX.SetSafeMode(active: boolean)
	SubstrateFX.SafeModeActive = active
end

-- Automatically bind window focus loss on the client to trigger Safe Mode
if RunService:IsClient() then
	UserInputService.WindowFocusReleased:Connect(function()
		SubstrateFX.SetSafeMode(true)
	end)
	UserInputService.WindowFocused:Connect(function()
		SubstrateFX.SetSafeMode(false)
	end)
end

-- =========================================================================
-- CORE MASS & CONVERSION UTILITIES (FIXED)
-- =========================================================================

function SubstrateFX.getRawRobloxMass(model: Model): number
	if not model or not model:IsA("Model") then return 0 end
	local totalMass = 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not part.Massless then
			local isAccessory = part:FindFirstAncestorOfClass("Accessory") ~= nil
			local mass = part:GetMass()
			if mass <= 0 then
				local volume = math.min(part.Size.X * part.Size.Y * part.Size.Z, 4.0)
				local density = part.CustomPhysicalProperties and part.CustomPhysicalProperties.Density or SubstrateFX.DEFAULT_DENSITY
				mass = volume * density
			end
			if isAccessory then mass = math.clamp(mass, 0.01, 0.25) end
			totalMass += mass
		end
	end
	return totalMass
end

function SubstrateFX.getWeightInKg(model: Model): number
	if not model or not model:IsA("Model") then return 0 end
	if weightCache[model] and weightCache[model] > 0 then return weightCache[model] end
	local rawRMU = SubstrateFX.getRawRobloxMass(model)
	local rawKg = rawRMU * SubstrateFX.KG_PER_RMU
	if model:FindFirstChildOfClass("Humanoid") then
		rawKg = math.clamp(rawKg * SubstrateFX.CHARACTER_DENSITY_SCALER, SubstrateFX.MIN_HUMAN_MASS_KG, SubstrateFX.MAX_HUMAN_MASS_KG)
	end
	local finalKg = math.floor(rawKg * 100 + 0.5) / 100
	if finalKg > 0 then
		weightCache[model] = finalKg
		model.Destroying:Once(function()
			weightCache[model] = nil
			SubstrateFX.clearCoMIndicator(model)
		end)
	end
	return finalKg
end

SubstrateFX.getWeightKg = SubstrateFX.getWeightInKg

function SubstrateFX.invalidateCache(model: Model)
	weightCache[model] = nil
end

-- =========================================================================
-- MATERIAL-DRIVEN CENTER OF MASS (COM) ENGINE
-- =========================================================================

function SubstrateFX.getCenterOfMass(model: Model): (Vector3, Vector3)
	if not model or not model:IsA("Model") then return Vector3.zero, Vector3.zero end
	local totalWeightedPos, totalMass = Vector3.zero, 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not part.Massless then
			local densityVal = materialDensities[part.Material] or 700
			local volume = part.Size.X * part.Size.Y * part.Size.Z
			local mass = volume * (densityVal / 1000)
			
			part.CustomPhysicalProperties = PhysicalProperties.new(
				densityVal / 1000, 0.3, 0.5, 1, 1
			)
			
			totalWeightedPos += (part.Position * mass)
			totalMass += mass
		end
	end
	if totalMass == 0 then return Vector3.zero, Vector3.zero end
	local worldCoM = totalWeightedPos / totalMass
	local primary = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
	if primary then primary.CenterOfMass = worldCoM end
	return worldCoM, primary and primary.CFrame:PointToObjectSpace(worldCoM) or Vector3.zero
end

function SubstrateFX.getInertiaTensor(model: Model): Vector3
	local worldCoM = SubstrateFX.getCenterOfMass(model)
	local Ix, Iy, Iz = 0, 0, 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not part.Massless then
			local m = part:GetMass()
			if m <= 0 then m = 0.05 end
			local r = part.Position - worldCoM
			Ix += m * (r.Y^2 + r.Z^2)
			Iy += m * (r.X^2 + r.Z^2)
			Iz += m * (r.X^2 + r.Y^2)
		end
	end
	return Vector3.new(Ix, Iy, Iz)
end

function SubstrateFX.renderCoMIndicator(model: Model, parentFolder: Instance?)
	local worldCoM = SubstrateFX.getCenterOfMass(model)
	local primary = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
	if not primary then return end
	local sphere = comIndicatorCache[model]
	if not sphere then
		sphere = Instance.new("Part")
		sphere.Name = "SubstrateCoM_" .. model.Name
		sphere.Shape = Enum.PartType.Ball
		sphere.Size = Vector3.new(0.6, 0.6, 0.6)
		sphere.Color = Color3.fromRGB(0, 229, 255)
		sphere.Material = Enum.Material.Neon
		sphere.CanCollide, sphere.Anchored = false, true
		sphere.Parent = parentFolder or Workspace
		comIndicatorCache[model] = sphere
	end
	sphere.Position = worldCoM
end

function SubstrateFX.clearCoMIndicator(model: Model)
	if comIndicatorCache[model] then
		comIndicatorCache[model]:Destroy()
		comIndicatorCache[model] = nil
	end
end

-- =========================================================================
-- KINEMATICS, AERODYNAMICS & DYNAMICS
-- =========================================================================

function SubstrateFX.getVelocityMS(partOrModel: Instance): Vector3
	local basePart: BasePart? = nil
	if partOrModel:IsA("BasePart") then
		basePart = partOrModel
	elseif partOrModel:IsA("Model") then
		basePart = partOrModel.PrimaryPart or partOrModel:FindFirstChild("HumanoidRootPart") or partOrModel:FindFirstChildWhichIsA("BasePart")
	end
	return basePart and (basePart.AssemblyLinearVelocity * SubstrateFX.STUDS_PER_METER) or Vector3.zero
end

function SubstrateFX.getMomentum(model: Model): Vector3
	return SubstrateFX.getVelocityMS(model) * SubstrateFX.getWeightInKg(model)
end

function SubstrateFX.getKineticEnergy(model: Model): number
	local speed = SubstrateFX.getVelocityMS(model).Magnitude
	return 0.5 * SubstrateFX.getWeightInKg(model) * (speed ^ 2)
end

function SubstrateFX.getCrossSectionalArea(model: Model, moveDirection: Vector3): number
	local _, size = model:GetBoundingBox()
	local sizeMeters = size * SubstrateFX.STUDS_PER_METER
	if moveDirection.Magnitude < 0.001 then return sizeMeters.X * sizeMeters.Y end
	local dir = moveDirection.Unit
	return (math.abs(dir.X) * (sizeMeters.Y * sizeMeters.Z)) + (math.abs(dir.Y) * (sizeMeters.X * sizeMeters.Z)) + (math.abs(dir.Z) * (sizeMeters.X * sizeMeters.Y))
end

function SubstrateFX.calculateAerodynamicDrag(model: Model, dragCoefficient: number?): Vector3
	local cd = dragCoefficient or 1.05
	local velocityMS = SubstrateFX.getVelocityMS(model)
	local speed = velocityMS.Magnitude
	if speed < 0.1 then return Vector3.zero end
	local area = SubstrateFX.getCrossSectionalArea(model, velocityMS)
	return -velocityMS.Unit * (0.5 * SubstrateFX.AIR_DENSITY_KG_M3 * (speed ^ 2) * cd * area)
end

function SubstrateFX.getAtmosphericDensityAtAltitude(altitudeStuds: number): number
	local altitudeMeters = altitudeStuds * SubstrateFX.STUDS_PER_METER
	return SubstrateFX.AIR_DENSITY_KG_M3 * math.exp(-altitudeMeters / SubstrateFX.ATMOSPHERE_SCALE_HEIGHT)
end

function SubstrateFX.calculateLiftAndMagnus(part: BasePart): (Vector3, Vector3)
	local vel = part.AssemblyLinearVelocity * SubstrateFX.STUDS_PER_METER
	local angVel = part.AssemblyAngularVelocity
	local speed = vel.Magnitude
	if speed < 0.5 then return Vector3.zero, Vector3.zero end
	local density = SubstrateFX.getAtmosphericDensityAtAltitude(part.Position.Y)
	local crossArea = (part.Size.X * part.Size.Z) * (SubstrateFX.STUDS_PER_METER ^ 2)
	local angleOfAttack = math.rad(part.Orientation.X)
	local liftMagnitude = 0.5 * density * (speed ^ 2) * crossArea * math.sin(2 * angleOfAttack)
	local liftVector = part.CFrame.UpVector * liftMagnitude
	local magnusVector = vel.Unit:Cross(angVel) * (0.5 * density * crossArea * part.Size.Y * SubstrateFX.STUDS_PER_METER)
	return liftVector, magnusVector
end

function SubstrateFX.applyImpulse(targetModel: Model, directionVector: Vector3, forceMagnitudeNewtons: number)
	local primary = targetModel.PrimaryPart or targetModel:FindFirstChild("HumanoidRootPart") or targetModel:FindFirstChildWhichIsA("BasePart")
	if not primary then return end
	local massKg = SubstrateFX.getWeightInKg(targetModel)
	primary:ApplyImpulse(directionVector.Unit * ((forceMagnitudeNewtons / massKg) * primary:GetMass()))
end

function SubstrateFX.calculateCollisionImpulse(modelA: Model, modelB: Model, restitution: number?): (Vector3, Vector3)
	local e = math.clamp(restitution or 0.5, 0, 1)
	local mA, mB = SubstrateFX.getWeightInKg(modelA), SubstrateFX.getWeightInKg(modelB)
	local vA, vB = SubstrateFX.getVelocityMS(modelA), SubstrateFX.getVelocityMS(modelB)
	if (mA + mB) == 0 then return Vector3.zero, Vector3.zero end
	return ((mA - e * mB) * vA + (1 + e) * mB * vB) / (mA + mB), ((mB - e * mA) * vB + (1 + e) * mA * vA) / (mA + mB)
end

function SubstrateFX.applyMovementForces(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid.UseJumpPower = false
	local ratio = SubstrateFX.BASELINE_WEIGHT_KG / math.max(SubstrateFX.getWeightInKg(character), 1)
	local scaleFactor = math.pow(ratio, 0.35)
	humanoid.WalkSpeed = math.clamp(SubstrateFX.DEFAULT_WALKSPEED * scaleFactor, SubstrateFX.MIN_WALKSPEED, SubstrateFX.MAX_WALKSPEED)
	humanoid.JumpHeight = math.clamp(SubstrateFX.DEFAULT_JUMP_HEIGHT * scaleFactor, SubstrateFX.MIN_JUMP_HEIGHT, SubstrateFX.MAX_JUMP_HEIGHT)
end

function SubstrateFX.bindFallDamage(character: Model, onDamageCallback: ((damage: number, impactEnergy: number) -> ())?)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart
	local maxFreefallVelocityMS = 0
	humanoid.StateChanged:Connect(function(_, newState)
		if newState == Enum.HumanoidStateType.Freefall then
			maxFreefallVelocityMS = 0
			task.spawn(function()
				while humanoid:GetState() == Enum.HumanoidStateType.Freefall do
					local currentVelMS = math.abs(rootPart.AssemblyLinearVelocity.Y) * SubstrateFX.STUDS_PER_METER
					if currentVelMS > maxFreefallVelocityMS then maxFreefallVelocityMS = currentVelMS end
					task.wait(0.05)
				end
			end)
		elseif newState == Enum.HumanoidStateType.Landed then
			if maxFreefallVelocityMS > 14.0 then
				local massKg = SubstrateFX.getWeightInKg(character)
				local excessEnergy = math.max(0, (0.5 * massKg * (maxFreefallVelocityMS ^ 2)) - (0.5 * massKg * (196.0)))
				local damage = math.clamp(excessEnergy * 0.008, 5, 100)
				if onDamageCallback then onDamageCallback(damage, excessEnergy) else humanoid:TakeDamage(damage) end
			end
			maxFreefallVelocityMS = 0
		end
	end)
end

function SubstrateFX.createScalePart(cframe: CFrame, parent: Instance?): (Part, SurfaceGui)
	local scaleBase = Instance.new("Part")
	scaleBase.Name, scaleBase.Size, scaleBase.CFrame, scaleBase.Anchored = "SubstrateFX_WeightScale", Vector3.new(6, 0.6, 6), cframe, true
	scaleBase.Material, scaleBase.Color, scaleBase.TopSurface = Enum.Material.SmoothPlastic, Color3.fromRGB(25, 28, 35), Enum.SurfaceType.Smooth
	scaleBase.Parent = parent or Workspace

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name, surfaceGui.Face, surfaceGui.SizingMode, surfaceGui.PixelsPerStud = "DisplayGui", Enum.NormalId.Top, Enum.SurfaceGuiSizingMode.PixelsPerStud, 50
	surfaceGui.Parent = scaleBase

	local readLabel = Instance.new("TextLabel")
	readLabel.Name, readLabel.Size, readLabel.BackgroundTransparency = "Readout", UDim2.new(1, 0, 1, 0), 1
	readLabel.FontFace, readLabel.TextSize, readLabel.TextColor3 = Font.fromEnum(Enum.Font.Code), 28, Color3.fromRGB(0, 229, 255)
	readLabel.Text, readLabel.Parent = "SUBSTRATE-FX READY\\nSTEP ON SCALE", surfaceGui

	task.spawn(function()
		while scaleBase and scaleBase.Parent do
			local detectedModels, totalKg = {}, 0
			for _, p in workspace:GetPartsInPart(scaleBase) do
				local model = p:FindFirstAncestorOfClass("Model")
				if model and not detectedModels[model] then
					detectedModels[model] = true
					totalKg += SubstrateFX.getWeightInKg(model)
				end
			end
			readLabel.Text = totalKg > 0 and string.format("DETECTED MASS:\\n%.2f KG\\n%.2f RMU", totalKg, totalKg / SubstrateFX.KG_PER_RMU) or "SUBSTRATE-FX READY\\nSTEP ON SCALE"
			task.wait(0.1)
		end
	end)
	return scaleBase, surfaceGui
end

-- =========================================================================
-- HEAVY PRIORITIES CYCLE (HPC) & STRESS NODE SIMULATION
-- =========================================================================

function SubstrateFX.buildPartStressNode(part: BasePart): WSNode
	local size = part.Size / 2
	local joints = {}
	for _, joint in ipairs(part:GetJoints()) do
		if joint:IsA("Constraint") or joint:IsA("Weld") or joint:IsA("Motor6D") then
			table.insert(joints, joint)
		end
	end
	return {
		Part = part,
		Vertices = {
			Vector3.new(-size.X, -size.Y, -size.Z), Vector3.new(size.X, -size.Y, -size.Z),
			Vector3.new(-size.X, size.Y, -size.Z), Vector3.new(size.X, size.Y, -size.Z),
			Vector3.new(-size.X, -size.Y, size.Z), Vector3.new(size.X, -size.Y, size.Z),
			Vector3.new(-size.X, size.Y, size.Z), Vector3.new(size.X, size.Y, size.Z),
		},
		Normals = {
			Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 1, 0),
			Vector3.new(0, -1, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1)
		},
		StressFactor = 0,
		DominantAxis = Vector3.zero,
		CenterOfMassOffset = Vector3.zero,
		MassKg = part:GetMass() * SubstrateFX.KG_PER_RMU,
		AccruedFatigue = 0,
		TemperatureCelsius = 20,
		IsSubmerged = false,
		BuoyancyForce = Vector3.zero,
		ThermodynamicConductionRate = 0.05,
		AerodynamicCenter = Vector3.zero,
		StructuralHealth = materialYieldStrengths[part.Material] or 50,
		JointConstraints = joints,
	}
end

function SubstrateFX.computeWeightStress(node: WSNode): (number, Vector3, Vector3)
	local part = node.Part
	local cf = part.CFrame
	local mass = part:GetMass()
	local highestStress, targetVertex, dominantNormal = 0, node.Vertices[1], node.Normals[1]
	local downVector = Vector3.new(0, -1, 0)

	for _, norm in ipairs(node.Normals) do
		local alignment = math.abs(cf:VectorToWorldSpace(norm):Dot(downVector))
		local shear = (1 - alignment) * mass
		if shear > highestStress then
			highestStress = shear
			dominantNormal = norm
		end
	end

	local maxProj = -math.huge
	for _, vert in ipairs(node.Vertices) do
		local proj = vert:Dot(dominantNormal)
		if proj > maxProj then
			maxProj = proj
			targetVertex = vert
		end
	end

	return highestStress, dominantNormal, targetVertex * (highestStress / (mass + 0.001))
end

function SubstrateFX.calculateHydrodynamics(node: WSNode, fluidLevelY: number): Vector3
	local part = node.Part
	local partBottomY = part.Position.Y - (part.Size.Y / 2)
	local partTopY = part.Position.Y + (part.Size.Y / 2)
	if partTopY <= fluidLevelY then
		node.IsSubmerged = true
		local submergedVolume = (part.Size.X * part.Size.Y * part.Size.Z) * (SubstrateFX.STUDS_PER_METER ^ 3)
		return Vector3.new(0, 1000 * submergedVolume * SubstrateFX.GRAVITY_ACCEL_MS2, 0)
	elseif partBottomY < fluidLevelY then
		node.IsSubmerged = true
		local submRatio = (fluidLevelY - partBottomY) / part.Size.Y
		local submergedVolume = (part.Size.X * part.Size.Y * part.Size.Z * submRatio) * (SubstrateFX.STUDS_PER_METER ^ 3)
		return Vector3.new(0, 1000 * submergedVolume * SubstrateFX.GRAVITY_ACCEL_MS2, 0)
	end
	node.IsSubmerged = false
	return Vector3.zero
end

function SubstrateFX.processThermalExchange(node: WSNode, ambientTemp: number, dt: number)
	local tempDiff = ambientTemp - node.TemperatureCelsius
	node.TemperatureCelsius += tempDiff * node.ThermodynamicConductionRate * dt
	if node.TemperatureCelsius > 500 then
		node.StructuralHealth -= (node.TemperatureCelsius - 500) * 0.1 * dt
	end
end

function SubstrateFX.evaluateStructuralFracture(node: WSNode, controller: HPCController)
	if not controller.EnableDestruction then return end
	if node.AccruedFatigue >= node.StructuralHealth or node.StructuralHealth <= 0 then
		for _, constraint in ipairs(node.JointConstraints) do
			if constraint and constraint.Parent then constraint:Destroy() end
		end
		node.Part:BreakJoints()
		node.Part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.5, 1, 1)
		if controller.OnPartFractured then
			controller.OnPartFractured:Fire(node.Part, node.AccruedFatigue)
		end
	end
end

function SubstrateFX.createHPCController(model: Model): HPCController
	local nodes: { [BasePart]: WSNode } = {}
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") and not desc.Anchored then
			nodes[desc] = SubstrateFX.buildPartStressNode(desc)
		end
	end
	return {
		Model = model,
		Active = false,
		Nodes = nodes,
		HeartbeatConn = nil,
		WindVector = Vector3.zero,
		GlobalTemperature = 20,
		FluidLevelY = -math.huge,
		EnableDestruction = true,
		OnPartFractured = Instance.new("BindableEvent"),
	}
end

function SubstrateFX.startHPC(controller: HPCController)
	if controller.Active then return end
	controller.Active = true
	local accumulator = 0
	controller.HeartbeatConn = RunService.Heartbeat:Connect(function(dt)
		-- Safe Mode Throttling: Skip or reduce cycle frequency if Safe Mode is engaged
		if SubstrateFX.SafeModeActive then
			accumulator += (dt * 0.25) -- Slow down processing rate by 75% in Safe Mode
		else
			accumulator += dt
		end

		if accumulator < SubstrateFX.HPC_UPDATE_INTERVAL then return end
		local stepDt = accumulator
		accumulator = 0

		for part, node in pairs(controller.Nodes) do
			if not part:IsDescendantOf(Workspace) or part.Anchored then
				controller.Nodes[part] = nil
				continue
			end

			local stress, normalAxis, comOffset = SubstrateFX.computeWeightStress(node)
			node.StressFactor = stress
			node.DominantAxis = normalAxis
			node.CenterOfMassOffset = comOffset

			SubstrateFX.processThermalExchange(node, controller.GlobalTemperature, stepDt)

			local buoyancy = SubstrateFX.calculateHydrodynamics(node, controller.FluidLevelY)
			node.BuoyancyForce = buoyancy

			if node.IsSubmerged then
				local damping = -part.AssemblyLinearVelocity * 2.5 * part:GetMass() * stepDt
				part:ApplyCentralImpulse(buoyancy * stepDt + damping)
			end

			if controller.WindVector.Magnitude > 0 then
				local relativeWind = controller.WindVector - (part.AssemblyLinearVelocity * SubstrateFX.STUDS_PER_METER)
				local windForce = 0.5 * SubstrateFX.AIR_DENSITY_KG_M3 * relativeWind.Magnitude * relativeWind
				part:ApplyCentralImpulse(windForce * stepDt)
			end

			if stress > SubstrateFX.WS_STRESS_THRESHOLD then
				local worldOffset = part.CFrame:VectorToWorldSpace(comOffset)
				local gravitationalImpulse = Vector3.new(0, -Workspace.Gravity * (SubstrateFX.HPC_GRAVITY_MULTIPLIER - 1) * part:GetMass() * stepDt, 0)
				local rotationalTorque = worldOffset:Cross(gravitationalImpulse)

				node.AccruedFatigue += (stress * stepDt)
				SubstrateFX.evaluateStructuralFracture(node, controller)

				part:ApplyCentralImpulse(gravitationalImpulse)
				part:ApplyAngularImpulse(rotationalTorque)
			end
		end
	end)
end

function SubstrateFX.stopHPC(controller: HPCController)
	controller.Active = false
	if controller.HeartbeatConn then
		controller.HeartbeatConn:Disconnect()
		controller.HeartbeatConn = nil
	end
end

function SubstrateFX.castStressRay(origin: Vector3, direction: Vector3, ignoreList: {Instance}?): (RaycastResult?, number)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList or {}
	local result = Workspace:Raycast(origin, direction, params)
	if result and result.Instance then
		local yield = materialYieldStrengths[result.Instance.Material] or 50
		return result, yield
	end
	return result, 0
end

return SubstrateFX
