# Lambda handler for Workday-GSuite sync (container image).
# Fetches workdayRptPwd from SSM, Configuration.psd1 from Secrets Manager (64KB limit vs SSM 8KB).
#
# Handler format for aws-lambda-powershell-runtime: script.ps1::handler
#Requires -Modules @{ ModuleName = 'AWS.Tools.SimpleSystemsManagement'; ModuleVersion = '4.0.0' }
#Requires -Modules @{ ModuleName = 'AWS.Tools.SecretsManager'; ModuleVersion = '4.0.0' }

$ErrorActionPreference = 'Stop'
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function handler {
    param(
        [Parameter(Mandatory = $false)]
        $LambdaInput,

        [Parameter(Mandatory = $false)]
        $LambdaContext
    )

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

    # Secrets Manager secret containing PSGSuite Configuration.psd1 content (supports up to 64KB)
    $configSecretName = $env:PSGSUITE_CONFIG_SECRET_NAME
    if (-not $configSecretName) {
        throw 'Environment variable PSGSUITE_CONFIG_SECRET_NAME is required (Secrets Manager secret name for Configuration.psd1 content).'
    }

    try {
        $secret = Get-SECSecretValue -SecretId $configSecretName
        $configDir = '/tmp/config'
        $psgsuiteHome = '/tmp/.config/powershell/SCRT HQ/PSGSuite'
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        New-Item -ItemType Directory -Path $psgsuiteHome -Force | Out-Null
        $configContent = $secret.SecretString
        # Force-rewrite path-bearing fields regardless of spacing/quote style.
        $configContent = [regex]::Replace(
            $configContent,
            '(?m)^\s*ConfigPath\s*=.*$',
            "    ConfigPath = '$psgsuiteHome/Configuration.psd1'"
        )
        # Empty ClientSecrets can be interpreted as a file path by PSGSuite 2.x internals.
        # Force to $null so no file path resolution is attempted.
        $configContent = [regex]::Replace(
            $configContent,
            '(?m)^\s*ClientSecrets\s*=.*$',
            '    ClientSecrets = $null'
        )
        $p12KeyPath = Join-Path $configDir 'service-account.p12'
        if ($configContent -match '(?s)P12Key\s*=\s*@\((?<bytes>.*?)\)') {
            $p12Bytes = $Matches['bytes'] -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne '' } |
                ForEach-Object { [byte]$_ }
            [System.IO.File]::WriteAllBytes($p12KeyPath, $p12Bytes)
            $configContent = [regex]::Replace(
                $configContent,
                '(?m)^\s*P12KeyPath\s*=.*$',
                "    P12KeyPath = '$p12KeyPath'"
            )
            if ($configContent -notmatch '(?m)^\s*P12KeyPath\s*=') {
                $configContent = $configContent -replace '(?m)^\s*P12Key\s*=.*$', ("    P12KeyPath = '{0}'`n`$0" -f $p12KeyPath)
            }
        } else {
            throw 'Configuration secret is missing P12Key byte array and no P12KeyPath was set.'
        }
        $stagedConfigPath = Join-Path $configDir 'Configuration.psd1'
        $resolvedConfigPath = Join-Path $psgsuiteHome 'Configuration.psd1'
        $configContent | Set-Content -Path $stagedConfigPath -Encoding utf8
        $configContent | Set-Content -Path $resolvedConfigPath -Encoding utf8
        $env:PSGSUITE_CONFIG_DIR = $configDir
        $env:PSGSUITE_HOME = $psgsuiteHome
        $env:HOME = '/tmp'
        $env:USERPROFILE = '/tmp'
        $env:XDG_CONFIG_HOME = '/tmp/.config'
        $env:XDG_CONFIG_DIRS = '/tmp/.config:/etc/xdg'
        # Configuration module uses automatic $HOME during import; set it explicitly for this runspace.
        Set-Variable -Name HOME -Value '/tmp' -Scope Global -Force
        New-Item -ItemType Directory -Path '/tmp/.config' -Force | Out-Null
        New-Item -ItemType Directory -Path '/tmp/.local/share' -Force | Out-Null
        # PSGSuite uses "~" paths during module import; ensure FileSystem provider home is set.
        (Get-PSProvider 'FileSystem').Home = '/tmp'
        Set-Location -Path '/tmp'
    } catch {
        throw "Failed to retrieve or write PSGSuite config from Secrets Manager secret '$configSecretName': $_"
    }

    # workdayRptUsr, workdayRptUri, failsafeRecordChangeLimit set via Lambda environment variables
    if (-not $env:workdayRptUsr) { throw 'Environment variable workdayRptUsr is required.' }
    if (-not $env:workdayRptUri) { throw 'Environment variable workdayRptUri is required.' }

    # Preload PSGSuite and config so downstream commands run cleanly.
    try {
        Import-Module PSGSuite -ErrorAction Stop
        $resolvedConfigPath = Join-Path $env:PSGSUITE_HOME 'Configuration.psd1'
        if (-not (Test-Path $resolvedConfigPath)) {
            throw "Expected PSGSuite config file not found: $resolvedConfigPath"
        }
        Get-PSGSuiteConfig | Out-Null
    } catch {
        throw "Failed to initialize PSGSuite: $($_.Exception.Message)"
    }

    # Run sync.ps1
    $syncScript = Join-Path $scriptDir 'sync.ps1'
    # Prevent sync pipeline objects from becoming Lambda response payload (can trigger JSON depth warnings).
    & $syncScript | Out-Host
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }

    return @{ ExitCode = $exitCode }
}
