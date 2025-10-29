--!strict

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
 
local effects = Workspace:WaitForChild("PathEffects") -- VFX folder
local templatePart = Workspace:WaitForChild("Part") :: BasePart 
local rig = Workspace:WaitForChild("Rig") :: Model -- agent
local humanoid = rig:FindFirstChildOfClass("Humanoid") :: Humanoid -- movement driver
local root = rig:WaitForChild("HumanoidRootPart") :: BasePart -- nav origin
local place = ReplicatedStorage:WaitForChild("place") :: RemoteEvent -- anchor requests
 
for _, inst in ipairs(rig:GetDescendants()) do
    if inst:IsA("BasePart") then
        inst:SetNetworkOwner(nil) -- server owns physics
    end
end
 
humanoid.WalkSpeed = ("place"):len() * 2 + 12 -- speed calc
humanoid.JumpPower = 0 -- no jumping
humanoid.JumpHeight = 0 -- no jumping
humanoid.MaxSlopeAngle = 89 -- max incline
humanoid.BreakJointsOnDeath = false -- keep parts
humanoid.RequiresNeck = false -- no neck
humanoid.AutoJumpEnabled = false -- no auto
humanoid.Sit = false -- no sitting
humanoid.UseJumpPower = true -- use JumpPower
humanoid.EvaluateStateMachine = true -- control movement
humanoid.PlatformStand = false -- keep control
humanoid.AutoRotate = true -- face travel dir
humanoid.PlatformStand = false -- keep control
 
local pointsCap = ("place"):len() * 2 -- max points
local segmentsCap = pointsCap - 1 -- beams = points-1
local MAX_DOWN = 256 -- ray depth
local MAX_STEPS = 512 -- guard caps
local RELINK_EVERY_HEARTBEAT = true -- keep beams attached live
 
local baseExclude = { effects, rig } -- ignore our VFX + the rig itself
local function makeParams(extra: { Instance }?): RaycastParams
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude -- exclude only
    if extra then
        local all = table.clone(baseExclude) -- keep base ignores
        for _, inst in ipairs(extra) do table.insert(all, inst) end -- extend ignores
        params.FilterDescendantsInstances = all
    else
        params.FilterDescendantsInstances = baseExclude
    end
    return params
end
 
local function isGround(inst: Instance, normalY: number): boolean
    if normalY < 0.8 then return false end -- reject steep slopes
    if inst == Workspace.Terrain then return true end -- terrain ok
    if not inst:IsA("BasePart") then return false end -- must be a part
    local part = inst :: BasePart
    if not part.Anchored then return false end -- no dynamic parts
    if not part.CanCollide then return false end -- must collide
    if part:IsDescendantOf(effects) then return false end -- ignore our parts
    if part.Parent and part.Parent:FindFirstChildOfClass("Humanoid") then return false end -- ignore characters
    return true -- passes all checks
end
 
local pointPool = table.create(pointsCap)
local segmentPool = table.create(segmentsCap)
 
for i = 1, pointsCap do
    local part = templatePart:Clone()
    part.Name = "part" -- pool member
    part.Anchored = true -- static
    part.Parent = effects -- live under VFX
    part.CFrame = CFrame.new(0, -1000 - i, 0) -- parked off-map
    local attach = Instance.new("Attachment")
    attach.Name = "attach" -- beam anchor
    attach.Parent = part
    pointPool[i] = { part = part, attach = attach, inUse = false, index = i } -- slot record
end
 
for i = 1, segmentsCap do
    local beam = Instance.new("Beam")
    beam.Name = "beam" -- pool member
    beam.Parent = effects -- lives with VFX
    beam.Width0 = 0.25 -- thin line
    beam.Width1 = 0.25 -- same tail width
    beam.Color = ColorSequence.new(Color3.new(1, 1, 1)) -- white
    beam.Transparency = NumberSequence.new(0) -- opaque
    beam.FaceCamera = true -- billboard look
    beam.Enabled = false -- disabled until linked
    segmentPool[i] = { beam = beam, inUse = false, index = i } -- slot record
end
 
local orderedPoints = table.create(pointsCap) -- 1..points
local orderedSegments = table.create(segmentsCap) -- 1..segments
local points = 0 -- active point count
local segments = 0 -- active segment count
local running = false -- path runner flag
local nextIndex = 1 -- next goal index
 
local function getPoint()
    for i = 1, pointsCap do
        local rec = pointPool[i]
        if not rec.inUse then
            rec.inUse = true -- mark taken
            return rec -- free record
        end
    end
    return nil -- none free
end
 
local function getSegment()
    for i = 1, segmentsCap do
        local rec = segmentPool[i]
        if not rec.inUse then
            rec.inUse = true -- mark taken
            return rec -- free record
        end
    end
    return nil -- none free
end
 
local function releasePoint(rec)
    rec.inUse = false -- free
    rec.part.CFrame = CFrame.new(0, -1000 - rec.index, 0) -- park off-map
end
 
local function releaseSegment(rec)
    rec.inUse = false -- free
    rec.beam.Attachment0 = nil -- clear a
    rec.beam.Attachment1 = nil -- clear b
    rec.beam.Enabled = false -- hide
end
 
local function stop(worldPos: Vector3): Vector3?
    local origin = worldPos + Vector3.yAxis * 10 -- raise start a bit
    local dir = Vector3.new(0, -MAX_DOWN, 0) -- cast down
    local ignores: { Instance } = {} -- dynamic excludes
    for _ = 1, 5 do -- few passes
        local cast = Workspace:Raycast(origin, dir, makeParams(ignores)) -- try
        if not cast then return nil end -- nothing below
        if isGround(cast.Instance, cast.Normal.Y) then
            return cast.Position -- grounded hit
        end
        table.insert(ignores, cast.Instance) -- skip this blocker
        origin = cast.Position + Vector3.yAxis * 0.05 -- nudge under
    end
    return nil -- gave up
end
 
local function target(): Vector3?
    if nextIndex <= points then
        return orderedPoints[nextIndex].part.Position -- current goal
    end
    return nil -- no goals
end
 
local function buildPath(fromPos: Vector3, toPos: Vector3): { PathWaypoint }?
    local pf = PathfindingService:CreatePath({ WaypointSpacing = 4, AgentCanJump = false }) -- tight mesh
    pf:ComputeAsync(fromPos, toPos) -- solve
    if pf.Status ~= Enum.PathStatus.Success then return nil end -- failed
    return pf:GetWaypoints() -- steps
end
 
local function moveAlong(waypoints: { PathWaypoint }): boolean
    local count = math.min(#waypoints, MAX_STEPS) -- clamp hops
    for i = 1, count do
        humanoid:MoveTo(waypoints[i].Position) -- step
        local reached = humanoid.MoveToFinished:Wait() -- wait finish
        if not reached then
            return false -- aborted
        end
    end
    return true -- arrived
end
 
local function relink()
    for i = 1, segments do
        local seg = orderedSegments[i] -- beam slot i
        local a = orderedPoints[i] -- point i
        local b = orderedPoints[i + 1] -- point i+1
        if seg and a and b then
            if seg.beam.Attachment0 ~= a.attach then seg.beam.Attachment0 = a.attach end -- set a
            if seg.beam.Attachment1 ~= b.attach then seg.beam.Attachment1 = b.attach end -- set b
            if not seg.beam.Enabled then seg.beam.Enabled = true end -- show
        end
    end
end
 
if RELINK_EVERY_HEARTBEAT then
    RunService.Heartbeat:Connect(relink) -- keep links fresh
end
 
local function pop()
    if points == 0 then return end -- nothing to pop
 
    local firstPoint = orderedPoints[1] -- head
    if firstPoint then releasePoint(firstPoint) end -- free head point
 
    if segments > 0 then
        local firstSeg = orderedSegments[1] -- head beam
        if firstSeg then releaseSegment(firstSeg) end -- free head beam
        if segments > 1 then table.move(orderedSegments, 2, segments, 1) end -- shift left
        orderedSegments[segments] = nil -- trim tail
        segments -= 1 -- dec count
    end
 
    if points > 1 then table.move(orderedPoints, 2, points, 1) end -- shift left
    orderedPoints[points] = nil -- trim tail
    points -= 1 -- dec count
    nextIndex = 1 -- restart goal
end
 
local function start()
    if running then return end -- already running
    running = true -- mark
 
    task.spawn(function()
        local guard = 0 -- iteration cap
        while running do
            guard += 1 -- step
            if guard > MAX_STEPS then break end -- bail if too long
 
            local goalPos = target() -- next goal
            if not goalPos then break end -- done
 
            local path = buildPath(root.Position, goalPos) -- plan
            if not path then pop(); continue end -- drop invalid goal
 
            if moveAlong(path) then pop() else pop() end -- consume head either way
            task.wait(0.02) -- tiny pacing
        end
        running = false -- finished
    end)
end
 
local function anchor(pos: Vector3)
    if points >= pointsCap then return end -- pool full
 
    local grounded = stop(pos) -- validate ground
    if not grounded then return end -- reject air
 
    local rec = getPoint() -- take a point
    if not rec then return end -- no free points
 
    rec.part.CFrame = CFrame.new(grounded) -- place point
    points += 1 -- inc count
    orderedPoints[points] = rec -- push order
 
    if points >= 2 and segments < segmentsCap then
        local segRec = getSegment() -- take a beam
        if segRec then
            segments += 1 -- inc beams
            orderedSegments[segments] = segRec -- push order
        end
    end
 
    if not running and points == pointsCap then start() end -- kick runner at full queue
end
 
place.OnServerEvent:Connect(function(_, worldPos: Vector3)
    if typeof(worldPos) ~= "Vector3" then return end -- type gate
    anchor(worldPos) -- try anchor
end)
