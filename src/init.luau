--!nonstrict

-- natsuki
-- src/init.luau
-- (C) Shellworks Development, All rights reserved, 2025
-- Refer to LICENSE.md for license information.

local PathfindingService = game:GetService("PathfindingService")
local _RunService = game:GetService("RunService")

local natsuki = {}

-- Types
export type EnemyAnimations = {
    Idle: AnimationTrack?,
    Walk: AnimationTrack?,
    Run: AnimationTrack?,
    Shoot: AnimationTrack?,
    Reload: AnimationTrack?,
    Death: AnimationTrack?,
    Alert: AnimationTrack?
}

export type EnemyConfig = {
    DetectionRange: number?,
    AttackRange: number?,
    FireRate: number?,
    Accuracy: number?,
    WalkSpeed: number?,
    RunSpeed: number?,
    WanderRadius: number?,
    ReactionTime: number?,
    Damage: number?,
    HeadshotDamage: number?
}

export type Enemy = {
    Character: Model,
    Humanoid: Humanoid,
    Animator: Animator,
    RootPart: BasePart,
    Weapon: Tool?,
    Health: number,
    Aggro: number,
    Target: Model?,
    State: string,
    DetectionRange: number,
    AttackRange: number,
    LastShot: number,
    FireRate: number,
    Accuracy: number,
    Path: Path?,
    CurrentWaypoint: number,
    WanderOrigin: Vector3,
    WanderRadius: number,
    LastStateChange: number,
    ReactionTime: number,
    Damage: number,
    HeadshotDamage: number,
    Animations: EnemyAnimations,
    Update: (self: Enemy, dt: number) -> (),
    TakeDamage: (self: Enemy, amount: number, attacker: Model?) -> (),
    Shoot: (self: Enemy, target: BasePart) -> (),
    Wander: () -> (),
    PlayAnimation: (self: Enemy, animName: string) -> (),
    StopAllAnimations: () -> (),
    Destroy: () -> ()
}

-- Raycast params setup
local function createRaycastParams(character: Model)
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {character}
    params.FilterType = Enum.RaycastFilterType.Exclude
    return params
end

-- Line of sight check with distance
local function hasLineOfSight(from: BasePart, to: BasePart): (boolean, number)
    local direction = (to.Position - from.Position)
    local distance = direction.Magnitude
    local parent = from.Parent
    if not parent or not parent:IsA("Model") then return false, distance end
    local ray = workspace:Raycast(from.Position, direction, createRaycastParams(parent))
    
    if ray then
        local hit = ray.Instance:IsDescendantOf(to.Parent)
        return hit, distance
    end
    return false, distance
end

-- Create a new enemy NPC
-- @param character: The character model (must have Humanoid, Animator, HumanoidRootPart)
-- @param animations: Table of AnimationTracks {Idle, Walk, Run, Shoot, Reload, Death, Alert}
-- @param weapon: Optional weapon tool (must have Handle for muzzle position)
-- @param config: Optional config table for customizing behavior
natsuki.newEnemy = function(
    character: Model, 
    animations: EnemyAnimations,
    weapon: Tool?,
    config: EnemyConfig?
): Enemy
    
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local animator = character:FindFirstChildOfClass("Animator") or (humanoid and humanoid:FindFirstChildOfClass("Animator"))
    local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
    
    assert(humanoid, "Character must have a Humanoid")
    assert(animator, "Character must have an Animator")
    assert(rootPart, "Character must have a HumanoidRootPart or PrimaryPart")
    
    -- Default config values
    local cfg = config or {}
    local detectionRange = cfg.DetectionRange or 80
    local attackRange = cfg.AttackRange or 50
    local fireRate = cfg.FireRate or 0.4
    local accuracy = cfg.Accuracy or 0.75
    local walkSpeed = cfg.WalkSpeed or 16
    local runSpeed = cfg.RunSpeed or 20
    local wanderRadius = cfg.WanderRadius or 30
    local reactionTime = cfg.ReactionTime or (math.random(3, 8) / 10)
    local damage = cfg.Damage or 12
    local headshotDamage = cfg.HeadshotDamage or 40
    
    local enemy = {
        Character = character,
        Humanoid = humanoid,
        Animator = animator,
        RootPart = rootPart,
        Weapon = weapon,
        Health = humanoid.Health,
        Aggro = 0,
        Target = nil,
        State = "Idle",
        DetectionRange = detectionRange,
        AttackRange = attackRange,
        LastShot = 0,
        FireRate = fireRate,
        Accuracy = accuracy,
        Path = nil,
        CurrentWaypoint = 1,
        WanderOrigin = rootPart.Position,
        WanderRadius = wanderRadius,
        LastStateChange = tick(),
        ReactionTime = reactionTime,
        Damage = damage,
        HeadshotDamage = headshotDamage,
        Animations = animations
    }
    
    -- Set initial walk speed
    humanoid.WalkSpeed = walkSpeed
    
    -- Start with idle animation
    if enemy.Animations.Idle then
        enemy.Animations.Idle:Play()
    end
    
    function enemy:StopAllAnimations()
        for _, track in pairs(self.Animations) do
            if track and track.IsPlaying then
                track:Stop()
            end
        end
    end
    
    function enemy:PlayAnimation(animName: string)
        local anim = self.Animations[animName]
        if not anim then return end
        
        -- Movement animation priority
        if animName == "Walk" or animName == "Run" then
            if self.Animations.Idle then self.Animations.Idle:Stop() end
            if animName == "Walk" and self.Animations.Run then self.Animations.Run:Stop() end
            if animName == "Run" and self.Animations.Walk then self.Animations.Walk:Stop() end
        elseif animName == "Idle" then
            if self.Animations.Walk then self.Animations.Walk:Stop() end
            if self.Animations.Run then self.Animations.Run:Stop() end
        end
        
        if not anim.IsPlaying then
            anim:Play()
        end
    end
    
    -- Wander behavior
    function enemy:Wander()
        if self.State ~= "Patrol" and self.State ~= "Idle" then return end
        
        -- Pick random point within wander radius
        local randomAngle = math.random() * math.pi * 2
        local randomDist = math.random() * self.WanderRadius
        
        local wanderPoint = self.WanderOrigin + Vector3.new(
            math.cos(randomAngle) * randomDist,
            0,
            math.sin(randomAngle) * randomDist
        )
        
        -- Create path to wander point
        local path = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true
        })
        
        local success = pcall(function()
            path:ComputeAsync(self.RootPart.Position, wanderPoint)
        end)
        
        if success and path.Status == Enum.PathStatus.Success then
            local waypoints = path:GetWaypoints()
            
            for i, waypoint in ipairs(waypoints) do
                if self.State ~= "Patrol" and self.State ~= "Idle" then 
                    self:StopAllAnimations()
                    break 
                end
                
                self:PlayAnimation("Walk")
                self.Humanoid:MoveTo(waypoint.Position)
                
                local moveFinished = self.Humanoid.MoveToFinished:Wait()
                if not moveFinished then break end
            end
            
            -- Reached destination, idle for a bit
            self:PlayAnimation("Idle")
            task.wait(math.random(2, 5))
        end
        
        path:Destroy()
    end
    
    -- Pathfinding chase
    local function followPath(path: Path)
        if enemy.State == "Dead" then return end
        
        local waypoints = path:GetWaypoints()
        
        for i, waypoint in ipairs(waypoints) do
            if enemy.State ~= "Chasing" and enemy.State ~= "Flanking" then 
                break 
            end
            
            -- Sprint if far from target
            local distToTarget = enemy.Target and enemy.Target:FindFirstChild("HumanoidRootPart") 
                and (enemy.Target.HumanoidRootPart.Position - enemy.RootPart.Position).Magnitude or 0
            
            if distToTarget > 30 then
                enemy:PlayAnimation("Run")
                enemy.Humanoid.WalkSpeed = runSpeed
            else
                enemy:PlayAnimation("Walk")
                enemy.Humanoid.WalkSpeed = walkSpeed
            end
            
            enemy.Humanoid:MoveTo(waypoint.Position)
            
            local timeout = enemy.Humanoid.MoveToFinished:Wait()
            if not timeout then
                break
            end
        end
    end
    
    function enemy:Update(dt: number)
        if self.State == "Dead" then return end
        
        -- Scan for players
        local closestPlayer = nil
        local closestDistance = math.huge
        
        for _, player in ipairs(game.Players:GetPlayers()) do
            if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
                local playerRoot = player.Character.HumanoidRootPart
                local distance = (playerRoot.Position - self.RootPart.Position).Magnitude
                
                if distance < self.DetectionRange and distance < closestDistance then
                    -- Check if player is in front (FOV check)
                    local toPlayer = (playerRoot.Position - self.RootPart.Position).Unit
                    local lookDir = self.RootPart.CFrame.LookVector
                    local dot = toPlayer:Dot(lookDir)
                    
                    -- 180 degree FOV when patrolling, 360 when alerted
                    local fovThreshold = (self.State == "Patrol" or self.State == "Idle") and 0 or -1
                    
                    if dot > fovThreshold then
                        closestPlayer = player.Character
                        closestDistance = distance
                    end
                end
            end
        end
        
        -- STATE MACHINE
        if closestPlayer then
            local targetRoot = closestPlayer:FindFirstChild("HumanoidRootPart")
            
            if targetRoot then
                local hasLOS, distance = hasLineOfSight(self.RootPart, targetRoot)
                
                -- First detection - reaction time delay
                if not self.Target then
                    if tick() - self.LastStateChange < self.ReactionTime then
                        return -- Still processing threat
                    end
                    
                    self:PlayAnimation("Alert")
                    task.wait(0.3) -- Alert pause
                end
                
                self.Target = closestPlayer
                
                -- ATTACKING STATE - Has LOS and in range
                if distance < self.AttackRange and hasLOS then
                    if self.State ~= "Attacking" then
                        self.State = "Attacking"
                        self.LastStateChange = tick()
                        self.Humanoid:MoveTo(self.RootPart.Position) -- Stop
                    end
                    
                    -- Face target
                    local lookVector = (targetRoot.Position - self.RootPart.Position).Unit
                    self.RootPart.CFrame = CFrame.new(
                        self.RootPart.Position, 
                        self.RootPart.Position + Vector3.new(lookVector.X, 0, lookVector.Z)
                    )
                    
                    self:PlayAnimation("Idle") -- Standing shoot
                    self:Shoot(targetRoot)
                    
                    -- Randomly strafe
                    if math.random() < 0.01 then -- 1% chance per frame
                        local strafeDir = math.random() > 0.5 and 1 or -1
                        local strafePos = self.RootPart.Position + (self.RootPart.CFrame.RightVector * strafeDir * 5)
                        self.Humanoid:MoveTo(strafePos)
                    end
                    
                -- CHASING STATE - Lost LOS or too far
                else
                    if self.State ~= "Chasing" then
                        self.State = "Chasing"
                        self.LastStateChange = tick()
                    end
                    
                    -- Recreate path periodically
                    if not self.Path or (tick() - self.LastStateChange) % 1 < dt then
                        if self.Path then self.Path:Destroy() end
                        
                        self.Path = PathfindingService:CreatePath({
                            AgentRadius = 2,
                            AgentHeight = 5,
                            AgentCanJump = true,
                            AgentCanClimb = false,
                            Costs = {
                                Water = math.huge,
                                Danger = 5
                            }
                        })
                        
                        local success = pcall(function()
                            self.Path:ComputeAsync(self.RootPart.Position, targetRoot.Position)
                        end)
                        
                        if success and self.Path.Status == Enum.PathStatus.Success then
                            task.spawn(followPath, self.Path)
                        else
                            -- Fallback: direct move
                            self.Humanoid:MoveTo(targetRoot.Position)
                            self:PlayAnimation("Run")
                        end
                    end
                end
            end
            
        -- NO TARGET - Patrol/Wander
        else
            if self.State ~= "Patrol" and self.State ~= "Idle" then
                self.State = "Patrol"
                self.LastStateChange = tick()
                self.Target = nil
                self.Humanoid.WalkSpeed = walkSpeed
            end
            
            -- Wander when idle
            if tick() - self.LastStateChange > math.random(5, 10) then
                self.LastStateChange = tick()
                task.spawn(function()
                    self:Wander()
                end)
            else
                self:PlayAnimation("Idle")
            end
        end
    end
    
    function enemy:TakeDamage(amount: number, attacker: Model?)
        self.Health -= amount
        self.Humanoid.Health = self.Health
        self.Aggro += amount * 1.5
        
        -- Immediate aggro on attacker
        if attacker then
            self.Target = attacker
            self.State = "Chasing"
            self.LastStateChange = tick() - self.ReactionTime -- Skip reaction delay when shot
        end
    end
    
    function enemy:Shoot(target: BasePart)
        local currentTime = tick()
        if currentTime - self.LastShot < self.FireRate then return end
        
        if self.Weapon and self.Weapon:FindFirstChild("Handle") then
            local muzzle = self.Weapon.Handle
            
            -- Aim with some vertical offset for realism
            local aimOffset = Vector3.new(0, math.random(0, 2), 0)
            local targetPos = target.Position + aimOffset
            
            local direction = (targetPos - muzzle.Position).Unit
            
            -- Apply accuracy-based spread
            local spread = (1 - self.Accuracy) * 0.12
            direction = (direction + Vector3.new(
                (math.random() - 0.5) * spread,
                (math.random() - 0.5) * spread,
                (math.random() - 0.5) * spread
            )).Unit
            
            -- Raycast bullet
            local result = workspace:Raycast(muzzle.Position, direction * 400, createRaycastParams(self.Character))
            
            if result then
                -- Damage calculation
                local hitHumanoid = result.Instance.Parent:FindFirstChildOfClass("Humanoid")
                if hitHumanoid then
                    local dmg = self.Damage
                    if result.Instance.Name == "Head" then
                        dmg = self.HeadshotDamage
                    end
                    hitHumanoid:TakeDamage(dmg)
                end
                
                -- Impact effect
                local impact = Instance.new("Part")
                impact.Anchored = true
                impact.CanCollide = false
                impact.Size = Vector3.new(0.2, 0.2, 0.2)
                impact.Position = result.Position
                impact.BrickColor = BrickColor.new("Bright yellow")
                impact.Material = Enum.Material.Neon
                impact.Shape = Enum.PartType.Ball
                impact.Parent = workspace
                game:GetService("Debris"):AddItem(impact, 0.1)
            end
            
            -- Muzzle flash
            local flash = Instance.new("PointLight")
            flash.Brightness = 3
            flash.Range = 8
            flash.Color = Color3.new(1, 0.7, 0.2)
            flash.Parent = muzzle
            game:GetService("Debris"):AddItem(flash, 0.05)
            
            self.LastShot = currentTime
            
            -- Play shoot animation
            if self.Animations.Shoot and not self.Animations.Shoot.IsPlaying then
                self.Animations.Shoot:Play()
            end
        end
    end
    
    function enemy:Destroy()
        if self.Path then
            self.Path:Destroy()
        end
        for _, track in pairs(self.Animations) do
            if track then
                track:Stop()
                track:Destroy()
            end
        end
        self.Character:Destroy()
    end
    
    -- Death handler
    humanoid.Died:Connect(function()
        enemy.State = "Dead"
        enemy:StopAllAnimations()
        if enemy.Animations.Death then
            enemy.Animations.Death:Play()
        end
        task.wait(5)
        enemy:Destroy()
    end)
    
    return enemy
end

return natsuki

--[[
Why didn't you come read with me today? 
I was waiting for you. 
I was waiting for a long time. 
It was the only thing I had to look forward to today. 
Why did you ruin it? 
Do you like Yuri more? 
I think you're better off not associating with her. 
Are you listening to me? Yuri is a sick freak. 
That should be obvious by now. So just play with me instead. 
Okay? You don't hate me, do you? 
Do you hate me? 
Do you want to make me go home crying? 
The club is the only place I feel safe. 
Don't ruin that for me. 
Don't ruin it. Please. 
Just stop talking to Yuri. 
Play with me instead.
It's all I have... 
Play with me. PLAY WITH ME.
]]