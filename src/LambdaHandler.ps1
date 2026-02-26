# Lambda handler for Workday-GSuite sync (container image).
# Fetches workdayRptPwd and Configuration.psd1 from SSM Parameter Store at runtime,
# writes config to /config/Configuration.psd1, sets env, then runs sync.ps1.
#Requires -Modules @{ ModuleName = 'AWS.Tools.SimpleSystemsManagement'; ModuleVersion = '4.0.0' }

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Required: SSM parameter name for Workday report password (SecureString)
$workdayPwdParamName = $env:WORKDAY_RPT_PWD_PARAM_NAME
if (-not $workdayPwdParamName) {
    throw 'Environment variable WORKDAY_RPT_PWD_PARAM_NAME is required (SSM parameter name for workday report password).'
}

try {
    $pwdParam = Get-SSMParameter -Name $workdayPwdParamName -WithDecryption $true
    $env:workdayRptPwd = $pwdParam.Value
} catch {
    throw "Failed to retrieve Workday password from SSM parameter '$workdayPwdParamName': $_"
}

# SSM parameter containing PSGSuite Configuration.psd1 content (SecureString)
$configParamName = $env:PSGSUITE_CONFIG_PARAM_NAME
if (-not $configParamName) {
    throw 'Environment variable PSGSUITE_CONFIG_PARAM_NAME is required (SSM parameter name for Configuration.psd1 content).'
}

try {
    $configParam = Get-SSMParameter -Name $configParamName -WithDecryption $true
    $configDir = '/config'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $configParam.Value | Set-Content -Path (Join-Path $configDir 'Configuration.psd1') -Encoding utf8
} catch {
    throw "Failed to retrieve or write PSGSuite config from SSM parameter '$configParamName': $_"
}

# workdayRptUsr, workdayRptUri, failsafeRecordChangeLimit set via Lambda environment variables
if (-not $env:workdayRptUsr) { throw 'Environment variable workdayRptUsr is required.' }
if (-not $env:workdayRptUri) { throw 'Environment variable workdayRptUri is required.' }

# Run sync.ps1
$syncScript = Join-Path $scriptDir 'sync.ps1'
& $syncScript
exit $LASTEXITCODE
