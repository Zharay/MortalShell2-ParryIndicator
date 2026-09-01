local Config = {}

-- Completely disables parry indicators for all enemies, but not rumble or danger indicators
Config.disableParryIndicators = false

-- Disables parry indicators for the lock-on target only, but other enemies will retain theirs
Config.disbaleParryIndicatorsOnLockOnly = false

-- Disables the additional unparryable indicator (Note: The in game's warning indicator will still appear)
Config.disableDangerIndicators = false

-- Disables rumble indicators. Note: Rumble only occurs when the player is locked on to the target and the enemy is in a parryable state.
Config.disableRumbleIndicators = false

-- Rumble Settings
Config.rumbleDuration = 1.0                 -- The duration of the rumble, in seconds
Config.rumbleStrength = 0.1                 -- The strength of the rumble, from 0.0 to 1.0 (Recommend 0.1 to 0.3 for a subtle effect)
Config.rumbleUseLeftLargeMotor = true       -- Whether to use the left large motor for rumble
Config.rumbleUseLeftSmallMotor = true       -- Whether to use the left small motor for rumble
Config.rumbleUseRightLargeMotor = true      -- Whether to use the right large motor for rumble
Config.rumbleUseRightSmallMotor = true      -- Whether to use the right small motor for rumble

return Config
