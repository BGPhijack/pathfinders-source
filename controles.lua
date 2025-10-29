local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
 
local place = ReplicatedStorage:WaitForChild("place") :: RemoteEvent -- server endpoint
local effects = Workspace:WaitForChild("PathEffects") -- VFX folder
local camera = Workspace.CurrentCamera -- active cam
 
local baseExclude = { effects } -- ignore our VFX
local MAX_CAST = 2048 -- forward ray length
local MAX_DOWN = 256 -- ground probe
 
local function makeParams(): RaycastParams
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude -- exclude list
    params.FilterDescendantsInstances = baseExclude -- only these
    return params
end
 
local function isGroundHit(hit: RaycastResult): boolean
    if hit.Normal.Y < 0.8 then return false end -- reject steep slopes
    local inst = hit.Instance -- surface
    if inst == Workspace.Terrain then return true end -- terrain ok
    if not inst:IsA("BasePart") then return false end -- must be part
    local part = inst :: BasePart
    if not part.Anchored then return false end -- no moving parts
    if not part.CanCollide then return false end -- must collide
    if part:IsDescendantOf(effects) then return false end -- ignore our VFX
    if part.Parent and part.Parent:FindFirstChildOfClass("Humanoid") then return false end -- ignore characters
    return true -- valid ground
end
 
local function projectToGround(worldPos: Vector3): Vector3?
    local origin = worldPos + Vector3.yAxis * 10 -- small lift
    local down = Vector3.new(0, -MAX_DOWN, 0) -- probe
    local cast = Workspace:Raycast(origin, down, makeParams()) -- downcast
    if cast and isGroundHit(cast) then
        return cast.Position -- grounded spot
    end
    return nil -- not grounded
end
 
local function getHitPosition(screenPosition: Vector2): Vector3?
    local cam = Workspace.CurrentCamera -- refresh cam
    if not cam then return nil end -- no camera
 
    local ray = cam:ViewportPointToRay(screenPosition.X, screenPosition.Y, 0) -- screen→ray
    local cast = Workspace:Raycast(ray.Origin, ray.Direction * MAX_CAST, makeParams()) -- forward
    if not cast then return nil end -- hit nothing
 
    if not isGroundHit(cast) then -- bad surface
        return projectToGround(cast.Position) -- try ground below
    end
    return cast.Position -- good surface
end
 
local function tryPlaceAtScreen(screenPosition: Vector2)
    local worldPosition = getHitPosition(screenPosition) -- pick world point
    if worldPosition then
        place:FireServer(worldPosition) -- send to server
    end
end
 
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if gameProcessed then return end -- ignore UI-consumed input
 
    if input.UserInputType == Enum.UserInputType.MouseButton1 then -- LMB click
        tryPlaceAtScreen(UserInputService:GetMouseLocation()) -- place from mouse
    elseif input.UserInputType == Enum.UserInputType.Touch then -- inputs when touching
        local touchPos = input.Position -- touch screen-space
        tryPlaceAtScreen(Vector2.new(touchPos.X, touchPos.Y)) -- adds touch support for X & Y
    end
end)
