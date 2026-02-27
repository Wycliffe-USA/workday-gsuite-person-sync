#!/usr/bin/pwsh -noprofile
[CmdletBinding(SupportsShouldProcess=$true)]
param (
  [string]$scriptVersion = '1.7',
  [string]$workdayRptUsr,
  [string]$workdayRptPwd,
  [string]$workdayRptUri,
  [int]$failsafeRecordChangeLimit = 5,
  [string]$emailIDFieldName       = 'WycliffeUSAEmailID'
)

write-host "Script Version: $scriptVersion"

## Notes
# Purpose : Sync Workday user attributes to gSuite
# -workdayRptUsr : User account to access workday report containing workday user information.
# -workdayRptPwd : Password for workdayRptUsr.
# -workdayRptUri : Uri location of workday report.dir
# -failsafeRecordChangeLimit : Sets a limit of changes to user's accounts. Each change to any record is counted.  The script exists at the end of processing a user and when it has reached this threshold.
#
# Also supports -Confirm:$true to confirm each action.
# This script uses powershell core.

#####################################################
###VVVVVVVVV Initial Variable Assignment VVVVVVVVV###
#Check for variable assignment via system environment variables.  This allows the operator to use docker environment vars.
if ($env:workdayRptUsr){$workdayRptUsr = $env:workdayRptUsr}
if ($env:workdayRptPwd){$workdayRptPwd = $env:workdayRptPwd}
if ($env:workdayRptUri){$workdayRptUri = $env:workdayRptUri}
if ($env:failsafeRecordChangeLimit){$failsafeRecordChangeLimit = $env:failsafeRecordChangeLimit}

$recordChanges = 0
$errors = @()
$runTimeStart = Get-Date
$global:ProgressPreference = "SilentlyContinue"
$gSuiteUsers = @{}
$workdayUsers = @{}

########################################################
###VVVVVVVVV Initial PSGSuite Configuration VVVVVVVVV###
# The PSGSuite module requires a configuration file to be set up.
#  This is setup with the p12 file from Google and some configuration variables, then exported into json so we can import it.
#  Here, you can mount the json file inside the container at /config or take a pre-configured Configuration.psd1 file available inside the same folder
#  and place it inside the /config file instead. Lambda uses /tmp/config (writable); set PSGSUITE_CONFIG_DIR to override.
#  See https://github.com/scrthq/PSGSuite/wiki/Set-PSGSuiteConfig for more information.
$configDir = if ($env:PSGSUITE_CONFIG_DIR) { $env:PSGSUITE_CONFIG_DIR } else { '/config' }
$psgsuiteHome = if ($env:PSGSUITE_HOME) { $env:PSGSUITE_HOME } else { '/root/.config/powershell/SCRT HQ/PSGSuite' }
If(Get-Item "$configDir/Configuration.json" -ErrorAction SilentlyContinue){
  If (!(Get-Item $psgsuiteHome -ErrorAction SilentlyContinue)){mkdir -p $psgsuiteHome}
  import-psgsuiteconfig -Path "$configDir/Configuration.json"
}ElseIf(Get-Item "$configDir/Configuration.psd1" -ErrorAction SilentlyContinue){
  If (!(Get-Item $psgsuiteHome -ErrorAction SilentlyContinue)){mkdir -p $psgsuiteHome}
  cp "$configDir/Configuration.psd1" (Join-Path $psgsuiteHome 'Configuration.psd1')
  # Explicitly load default PSGSuite config before any PSGSuite cmdlet.
  # Using -Path here can load the root psd1 container instead of the default named config.
  Get-PSGSuiteConfig | Out-Null
}

#[Console]::Out.Flush()
#write-host "PSGsuite config:"
#$test = get-content $configDir/Configuration.psd1
#write-host $test
#[Console]::Out.Flush()

###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################
###VVVVVVVVVVVVVV Functions VVVVVVVVVVVVV###
function finalStatusReport(){
  if ($errors.Count -ge 1){
    #There were errors during the process.  Report the error and exit with a status 1
    $output = "Workday-GSuite-Person-Sync completed with error(s) in " + [math]::Round(((Get-Date) - $runTimeSTart).TotalMinutes,2) + " minutes."
    Write-Error $output
    exit 1
  }else{
    #No errors during the process.  Exit with status 0
    $output = "Workday-GSuite-Person-Sync completed successfully with no errors in " + [math]::Round(((Get-Date) - $runTimeSTart).TotalMinutes,2) + " minutes."
    Write-Output $output
    exit 0
  }
}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###

#####################################################
###VVVVVVVVV Get User Data From Workday VVVVVVVVVV###
#Get Workday Report containing user list.
$secWorkdayPwd = $workdayRptPwd| ConvertTo-SecureString -AsPlainText -Force
$workdayCreds = New-Object System.Management.Automation.PSCredential ($workdayRptUsr, $secWorkdayPwd)
$workdayRestResponse = Invoke-RestMethod -Credential $workdayCreds -Uri $workdayRptUri -ErrorVariable errorOutput

#Error handling in case the workday response is blank or has too few entries.
if (($errorOutput) -Or !($workdayRestResponse) -Or (($workdayRestResponse.Report_Entry|Measure-Object).Count -lt 1000)){Write-Error "Workday-GSuite-Person-Sync Error: Got less than 1000 results from Workday or an error occurred.  Possible source data issue." ; exit 1}

###
#Save workdayresponse entries into workdayUsers array.
ForEach ($user in $workdayRestResponse.Report_Entry){
  #As we take the report response and add user entries into the $workdayUsers variable, we will first make sure each account has required values.
  # These issues sometimes arrise temporarily as workday staff add details to the user's account.
  if (!($user.staffID)){
    #Missing a staffID.  This could happen when a person's record is first created.
    $output = "Workday user missing staffID: || username: '" + $user.userName + "', displayname: '" + $user.displayName +"', email: '" + $user.email +"'. Not including this user in this run."
    Write-Warning $output 
  }elseif (!($user.userName)){
    #Missing a userName.  This could happen when a person's record is first created.
    $output = "Workday user missing userName: || staffID: '" + $user.staffID + "', displayname: '" + $user.displayName +"', email: '" + $user.email +"'. Not including this user in this run."
    Write-Warning $output 
  # }elseif (!($user.wycliffe_email)){
  #     #Missing a wycliffe_email assignment.
  #     $output = "Workday user missing wycliffe Email assignment field.: || staffID: '" + $user.staffID + "', displayname: '" + $user.displayName +"', email: '" + $user.email +"'. Not including this user in this run."
  #     Write-Warning $output 
  }elseif ($user.staffID -like '[A-Z]*'){
    #staffIDs should not contain letters.  However, they have sometimes briefly been created or modified to contain letters.
    $output = "Workday user's staffID contains a letter: || staffID: '" + $user.staffID + "',  username: '" + $user.userName + "', displayname: '" + $user.displayName +"', email: '" + $user.email +"'. Not including this user in this run."
    Write-Warning $output 
  }else{
    $workdayUsers[$user.staffID] = $user
  }
}

$result = $workdayUsers.keys|Measure-Object
$output = "Beginning sync for "+$result.Count+ " users."; Write-Output $output
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################

#####################################################
###VVVVVVVVV Get User Data From gSuite VVVVVVVVVV###
ForEach ($gSuiteUser in (Get-GSUser -Filter * -Fields 'id,name,primaryEmail,externalIds,suspended,SuspensionReason,user,FullName,OrgUnitPath,CustomSchemas,LastLoginTime' -ErrorVariable errorOutput)){
#ForEach ($gSuiteUser in (Get-GSUser -Filter * -Fields '*' -ErrorVariable errorOutput)){
  #Build a Hashtable of GSuite Users.  This will help to save time later by calling up the workdayUser's staffID in the table rather than cycle through the GS user list in each and every nested for loop.  

  #Find the user's Staff ID / employee number and add the user to our gSuiteUsers array.
  # Users without an 'organization' externalid (employee number) will be skipped.
  ForEach ($gSuiteExternalID in $gSuiteUser.ExternalIds){
    If (($gSuiteExternalID.Type -eq 'organization') -And ($gSuiteExternalID.Value -ne '')){
      #Re-Map the data from the gSuite API into a more flat format so it's easier to compare values.
      $gSuiteUsers[$gSuiteExternalID.Value] = @{
        'employeeID' = $gSuiteExternalID.Value;
        'id' = $gSuiteUser.Id;
        'suspended' = $gSuiteUser.Suspended;
        'SuspensionReason' = $gSuiteUser.SuspensionReason;
        'primaryEmail' = $gSuiteUser.PrimaryEmail;
        'fullName' = $gSuiteUser.Name.FullName;
        'givenName' = $gSuiteUser.Name.GivenName;
        'familyName' = $gSuiteUser.Name.FamilyName;
        'user' = $gSuiteUser.User;
        'orgUnitPath' = $gSuiteUser.OrgUnitPath;
        'CustomSchemas' = $gSuiteUser.CustomSchemas;
        'LastLoginTime' = $gSuiteUser.LastLoginTime
      }
    }
  }
}
if ($errorOutput){Write-Error "An error occurred getting data from gSuite." ; exit 1}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################

#####################################################
###VVVVVVVVVVVVVVVV Main Logic VVVVVVVVVVVVVVVVVVV###

#Add new users & sync current user data.  We'll handle disabling users separately.
###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
#After getting a list of users from workday, we process each against AD user information, looking for differences and rectifying them.
ForEach ($key in $workdayUsers.keys){
  $workdayUser = $workdayUsers[$key]
  #Syncronize data on existing accounts (including those existing in the disabled users OU.)
  ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###

  If ($gSuiteUsers.Keys -Contains $workdayUser.staffID){
    $gSuiteUser = $gSuiteUsers[$workdayUser.staffID]

    #If the user has the 'workday_managed = no' attribute, we won't manage the account.
    if ($gSuiteUser.CustomSchemas.wusa_custom_attributes.workday_managed -ne $False){

      #Synchronize fields between workday and gSuite.
      # For some fields we'll have to take special care.  For others we'll just compare the fields.
      ForEach ($field in @('accountLocked', 'displayName', 'email', 'givenName', 'lastName', 'staffID', 'userName')){
        #Special care fields - We need to take special care where certain feild types or methods do not align cleanly.  Then we'll just compare the rest.
        if ($field -eq 'accountLocked'){
          #Field - Account Locked
          ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
          if ($workdayUser.accountLocked -eq 'True'){
            #The workday account is locked. The gSuite user should be suspended if not already.
            if (!($gSuiteUser.Suspended)){
              #Sometimes we want to keep an account open for a period of time even if they are locked in Workday. (IDP needs to be disabled, but manager needs to access email, etc.)
              #In these instances, we set an account_expire_date to set when the account should stay open until.  Conversely however, we could have set an account_expire_date for other reasons such as a contractor with a hard contract end-date.
              #We don't necessarily want to keep these accounts from locking just because they have an account_expire_date.
              #To keep an account open even though they are locked, set the account expire date AND set the wusa_custom_attribute - force_account_active_until_expire to 'yes', or True.
              if ($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date -And ((Get-Date) -lt ([datetime]::parseexact($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date, 'yyyy-MM-dd', $null)))){
                #The account_expire_date is set and the current date is less than the expire date.

                #Determine if force_account_active_until_expire is set.
                if ($gSuiteUser.CustomSchemas.wusa_custom_attributes.force_account_active_until_expire){
                  #force_account_active_until_expire is set, so we should NOT deactivate this account.
                }else{
                  #force_account_active_until_expire is not set and since the account is locked in workday, it should be locked here.
                  #This user isn't suspended in gSuite, but should be.
                  $output = "Suspend: Workday User " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ") matching gSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite due to their Workday account being locked, but is not."
                  Write-Output $output

                  $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$true'
                  If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
                    $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$true -Confirm:$false -ErrorVariable errorOutput
                    if($errorOutput){$errors += $errorOutput}
                    $recordChanges += 1
                  }
                }
 
              }elseif($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date -And ((Get-Date) -ge ([datetime]::parseexact($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date, 'yyyy-MM-dd', $null)))){
                #The account_expire_date is set and the current date is greater than or equal to the expire date.
                #We should disable the account now.
                #This user isn't suspended in gSuite, but should be.
                $output = "Suspend: Workday User " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ") matching gSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite due to their Workday account being locked, but is not."
                Write-Output $output

                $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$true'
                If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
                  $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$true -Confirm:$false -ErrorVariable errorOutput
                  if($errorOutput){$errors += $errorOutput}
                  $recordChanges += 1
                }
              }else{
                #The account_expire_date is not set.
                #This user isn't suspended in gSuite, but should be.
                $output = "Suspend: Workday User " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ") matching gSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite due to their Workday account being locked, but is not."
                Write-Output $output

                $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$true'
                If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
                  $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$true -Confirm:$false -ErrorVariable errorOutput
                  if($errorOutput){$errors += $errorOutput}
                  $recordChanges += 1
                }
              }
            }
          }Else{
            #The workday account is not locked. The gSuite user should be not be suspended if it is unless the
            #account_expire_date is passed
            If (($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date) -And ((Get-Date) -gt ([datetime]::parseexact($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date, 'yyyy-MM-dd', $null)))){
              #Determine if account deactivation is necessary.
              if (!($gSuiteUser.Suspended)){
                #The gSuite account not locked, but it should be.
                $output = "Disable - Suspend: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite, but is not. Reason: Account expire date set in Google."
                Write-Output $output
      
                $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$true'
                If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
                  $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$true -Confirm:$false -ErrorVariable errorOutput
                  if($errorOutput){$errors += $errorOutput}
                  $recordChanges += 1
                }
              }
            }else{
              if ($gSuiteUser.Suspended){
                #This user is suspended in gSuite, but should not be.
                
                #Sometimes Google will suspend an account for suspicious activity.  Unfortunately they don't put any detail of that in the account's `SuspensionReason` field which is blank in that senario.
                # However, normally the `SuspensionReason` field would say 'ADMIN' if it were suspended by this script or another admin.
                # If the `SuspensionReason` is blank, we will NOT proceed with unlocking the account due to the suspicious activity but instead warn.
                if (!($gSuiteUser.SuspensionReason)){
                  $output = "Cannot Enable: Workday User " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ")'s account is suspended, but shouldn't be.  However, there is no suspension reason given.  This can be indicative of an automatic suspension by google for suspicious activity."
                  Write-Warning $output
                }else{
                  $output = "Enable: Workday User " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ") matching gSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should not be suspended in gSuite, but it is."
                  Write-Output $output
  
                  $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$false'
                  If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
                    $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$false -Confirm:$false -ErrorVariable errorOutput
                    if($errorOutput){$errors += $errorOutput}
                    $recordChanges += 1
                  }
                }
              }
            }
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }elseif($field -eq 'email'){
          #Field - email
          # In this section, we update the primary email address (username) of the person.  This comes from a custom field in workday called 'WycliffeUSAEmailID'.
          ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
          if ($gSuiteUser.primaryEmail -ne $workdayUser.($emailIDFieldName)){
            $output = "Update Primary Email (Username): Workday User " + $workdayUser.staffID + " (" + $workdayUser.displayName + ")'s Wycliffe USA Email ID '" + $workdayUser.($emailIDFieldName) + "' does not match gSuite user " + $gSuiteUser.employeeID + " (" + $gSuiteUser.givenName + ")'s Primary Email '"+ $gSuiteUser.primaryEmail +"'. Updating."
            Write-Output $output

            $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -PrimaryEmail ' + $workdayUser.($emailIDFieldName)
            If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
              $returnObj = Update-GSUser -User $gSuiteUser.User -PrimaryEmail $workdayUser.($emailIDFieldName) -Confirm:$false -ErrorVariable errorOutput
              if($errorOutput){
                $errors += $errorOutput
              }
            }
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }elseif(($field -eq 'givenName')-Or($field -eq 'lastName')-Or($field -eq 'displayName')){
          #Field - givenName
          #Field - lastName
          #Field - displayName - Skip: gSuite's 'FullName' doesn't seem to be setable.  Instead, it is a combination of given and family name.
          ##vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
          if (($workdayUser.givenName -ne $gSuiteUser.givenName) -Or ($workdayUser.lastName -ne $gSuiteUser.familyName)){
            $output = "Update Given and/or Family Name: Workday User " + $workdayUser.staffID + "'s givenName '" + $workdayUser.givenName + "' or lastName '" + $workdayUser.lastName + "' does not match gSuite user " + $gSuiteUser.employeeID + " (ID: " + $gSuiteUser.id + ")'s givenName '" + $gSuiteUser.givenName + "' or lastName '"+ $gSuiteUser.familyName +"'. Updating."
            Write-Output $output

            $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -givenName ' + $workdayUser.givenName + ' -lastName ' + $workdayUser.lastName
            If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {

              $givenName = $workdayUser.givenName
              $lastName = $workdayUser.lastName
              $returnObj = Update-GSUser -User $gSuiteUser.User -GivenName "$givenName" -FamilyName "$lastName" -Confirm:$false -ErrorVariable errorOutput
              if($errorOutput){
                $errors += $errorOutput
              }else{
                #Update the gSuiteUser values so that we don't iterate over this multiple times.
                $gSuiteUser.givenName = $workdayUser.givenName
                $gSuiteUser.familyName = $workdayUser.lastName
              }
              $recordChanges += 1
            }
          }
          ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
        }elseif($field -eq 'staffID'){
          #Field - StaffID - Skip
        }elseif($field -eq 'userName'){
          #Field - userName - Skip: We use the Workday WycliffeUSAEmailID field as the username for gSuite.  The 'userName' field from workday is unused in this case.
        }
      }

      #Determine account target OU.
      if (($workdayUser.WUSAAssigned -eq 1) -Or ($workdayUser.WUSAAssigned -eq 'True')){
        $targetOU = '/wusa users'
      }else{
        $targetOU = '/users'
      }

      #Determine if account move is necessary.
      if ($gSuiteUser.orgUnitPath -notlike "$targetOU*"){
        $output = "Enable - Move: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be moved from '" + $gSuiteUser.orgUnitPath +"' to '$targetOU' OU in gSuite. Reason: Account found in Workday but in the wrong gSuite OU."
        Write-Output $output

        $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + " -OrgUnitPath: '" + $targetOU + "'"
        If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {

          $returnObj = Update-GSUser -User $gSuiteUser.User -OrgUnitPath $targetOU -Confirm:$false -ErrorVariable errorOutput
          if($errorOutput){$errors += $errorOutput}
          $recordChanges += 1
        }
      }
    }
  }Else{
    #Account Creation
    ###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
    #Did not find a matching user among the active or disabled users.
    # Create a new account.
    $output = "Account Creation: Create an acccount for " + $workdayUser.staffID + " (" +  $workdayUser.displayName + ")"
    Write-Output $output

    $rndPassword = ([char[]]([char]33..[char]95) + ([char[]]([char]97..[char]126)) + 0..9| Sort-Object {get-random}  )[0..99] -join ''|convertto-securestring -AsPlainText -Force

    #Create an external ID object to store the staffID.  Used at account creation.
    $externalId = Add-GSUserExternalId -Type 'organization' -Value $workdayUser.staffID

    #Determine account target OU.
    if (($workdayUser.WUSAAssigned -eq 1) -Or ($workdayUser.WUSAAssigned -eq 'True')){
      $targetOU = '/wusa users'
    }else{
      $targetOU = '/users'
    }

    #Get accunt lock status
    If ($workdayUser.accountLocked -eq 'True'){$suspend = $True}else{$suspend = $False}

    #Check for valid email (WycliffeUSAEmailID) from workday
    if ($workdayUser.($emailIDFieldName)|select-string '@'){
      #Create the account.
      $confirmOutput = 'New-GSUser -User ' + $workdayUser.($emailIDFieldName).ToLower() + ' -ExternalIds ' + $externalId.Value + ' -GivenName ' + $workdayUser.givenName + ' -FamilyName ' + $workdayUser.lastName + " -OrgUnitPath '$targetOU' -Suspended:$suspend" + ' -IncludeInGlobalAddressList:$false -Password <Hidden>'
      If ($PSCmdlet.ShouldProcess($workdayUser.staffID,$confirmOutput)) {
        $returnObj = New-GSUser -PrimaryEmail $workdayUser.($emailIDFieldName).ToLower() -ExternalIds $externalId -GivenName $workdayUser.givenName -FamilyName $workdayUser.lastName -OrgUnitPath $targetOU -Suspended:$suspend -IncludeInGlobalAddressList:$false -Password $rndPassword -ErrorVariable errorOutput
        if($errorOutput){$errors += $errorOutput}
        $recordChanges += 1
      }
    }else{
      $output = 'Workday User ' + $workdayUser.staffID + ' (' + $workdayUser.displayName + ') has an invalid or missing WycliffeUSAEmailID (' + $workdayUser.($emailIDFieldName) + ') from Workday.'
      Write-Error $output
      $errors += $output
    }

    Remove-Variable rndPassword -Confirm:$false
    $recordChanges += 1
    ###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
  }

  #Test to see how many changes we're making.  Exit if it exceeds a limit.
  if ($recordChanges -gt $failsafeRecordChangeLimit){
    $output = "Exiting due to reaching falesafe record change limit of " + $failsafeRecordChangeLimit + "."
    Write-Error $output
    $errors += $output
    finalStatusReport
  } 
}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###


#Disable old accounts
###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
ForEach ($key in $gSuiteUsers.keys){
  $gsuiteUser = $gSuiteUsers[$key]
  If (($workdayUsers.keys -NotContains $gsuiteUser.employeeID) -And ($workdayUsers.keys.Count -gt 1000)){ #Count for sanity check.
    #User found in gSuite that that does not match any user from Workday.  Disable, and move it if necessary.

    #If the user has the 'workday_managed = no' attribute, we won't manage the account.
    if ($gSuiteUser.CustomSchemas.wusa_custom_attributes.workday_managed -ne $False){


      #Determine if the account expire date is set.  For surviving spouces or other reasons, We may want to keep the account open for a period of time even if the user no longer shows up in the workday report.
      # If not set than continue Or if set and the expire date has passed, continue.
      if ($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date -And ((Get-Date) -lt ([datetime]::parseexact($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date, 'yyyy-MM-dd', $null)))){
        #The account_expire_date is set and the current date is less than the expire date.

        #Determine if force_account_active_until_expire is set.
        if ($gSuiteUser.CustomSchemas.wusa_custom_attributes.force_account_active_until_expire){
          #force_account_active_until_expire is set, so we should NOT deactivate this account.
        }else{
          #force_account_active_until_expire is not set and since the account is not present in workday, it should be suspended/moved here.

          #Determine if account deactivation is necessary.
          if (!($gSuiteUser.Suspended)){
            #The gSuite account not locked, but it should be.
            $output = "Disable - Suspend: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite, but is not. Reason: Account not found in Workday."
            Write-Output $output

            $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$true'
            If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
              $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$true -Confirm:$false -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              $recordChanges += 1
            }
          }

          #Determine if account move is necessary.
          if (!($gSuiteUser.orgUnitPath -like "/disabled users*")){
            $output = "Disable - Move: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be moved to '/disabled users' OU in gSuite. Reason: Account not found in workday."
            Write-Output $output

            $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + " -OrgUnitPath: '/disabled users'"
            If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
              $returnObj = Update-GSUser -User $gSuiteUser.User -OrgUnitPath '/disabled users' -Confirm:$false -ErrorVariable errorOutput
              if($errorOutput){$errors += $errorOutput}
              $recordChanges += 1
            }
          }
        }
      }elseif($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date -And ((Get-Date) -ge ([datetime]::parseexact($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date, 'yyyy-MM-dd', $null)))){
        #The account_expire_date is set and the current date is greater than or equal to the expire date.

        #Determine if account deactivation is necessary.
        if (!($gSuiteUser.Suspended)){
          #The gSuite account not locked, but it should be.
          $output = "Disable - Suspend: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite, but is not. Reason: Account not found in Workday."
          Write-Output $output

          $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$true'
          If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
            $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$true -Confirm:$false -ErrorVariable errorOutput
            if($errorOutput){$errors += $errorOutput}
            $recordChanges += 1
          }
        }

        #Determine if account move is necessary.
        if (!($gSuiteUser.orgUnitPath -like "/disabled users*")){
          $output = "Disable - Move: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be moved to '/disabled users' OU in gSuite. Reason: Account not found in workday."
          Write-Output $output

          $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + " -OrgUnitPath: '/disabled users'"
          If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
            $returnObj = Update-GSUser -User $gSuiteUser.User -OrgUnitPath '/disabled users' -Confirm:$false -ErrorVariable errorOutput
            if($errorOutput){$errors += $errorOutput}
            $recordChanges += 1
          }
        }
      }else{
        #The account_expire_date is not set.
        #Determine if account deactivation is necessary.
        if (!($gSuiteUser.Suspended)){
          #The gSuite account not locked, but it should be.
          $output = "Disable - Suspend: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite, but is not. Reason: Account not found in Workday."
          Write-Output $output

          $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + ' -Suspended:$true'
          If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
            $returnObj = Update-GSUser -User $gSuiteUser.User -Suspended:$true -Confirm:$false -ErrorVariable errorOutput
            if($errorOutput){$errors += $errorOutput}
            $recordChanges += 1
          }
        }

        #Determine if account move is necessary.
        if (!($gSuiteUser.orgUnitPath -like "/disabled users*")){
          $output = "Disable - Move: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be moved to '/disabled users' OU in gSuite. Reason: Account not found in workday."
          Write-Output $output

          $confirmOutput = 'Update-GSUser -User ' + $gSuiteUser.user + " -OrgUnitPath: '/disabled users'"
          If ($PSCmdlet.ShouldProcess($gSuiteUser.User,$confirmOutput)) {
            $returnObj = Update-GSUser -User $gSuiteUser.User -OrgUnitPath '/disabled users' -Confirm:$false -ErrorVariable errorOutput
            if($errorOutput){$errors += $errorOutput}
            $recordChanges += 1
          }
        }
      }
    }else{
      #The user has the 'workday_managed' field set no, or False so we won't manage it.
      #However, we still want to warn about accounts that are past their expiration date.
      if (($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date) -And ((Get-Date) -gt ([datetime]::parseexact($gSuiteUser.CustomSchemas.wusa_custom_attributes.account_expire_date, 'yyyy-MM-dd', $null)))){
        $output = "Warning: GSuite user " + $gSuiteUser.employeeID + " (Display Name: " + $gSuiteUser.fullName + ", ID: " + $gSuiteUser.id + ") should be suspended in gSuite based on their account_expire_date, but will NOT be, because their account's workday_managed field is set to No."
        Write-Output $output
      }
    }
  }

  #Test to see how many changes we're making.  Exit if it exceeds a falesafe change limit.
  if ($recordChanges -gt $failsafeRecordChangeLimit){
    $output = "Exiting due to reaching falesafe record change limit of " + $failsafeRecordChangeLimit + "."
    Write-Error $output
    $errors += $output
    finalStatusReport
  }
}
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###

#Final error handling
###vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv###
finalStatusReport
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
###^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^###
#####################################################