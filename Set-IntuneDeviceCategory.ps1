<#
.DESCRIPTION
This script will get the member of a specified Azure AD group, check those devices in Intune to ensure that they have a device category assigned, and assign the category if it is missing or incorrect.
All actions are logged in the runbook output.
Authentication is done using an Azure App registration.
Required cmdlets and modules:
    Get-MgBetaDevice - Microsoft.Graph.Beta.Identity.DirectoryManagement
    Get-MgBetaGroup - Microsoft.Graph.Beta.Groups
    Get-MgBetaDeviceManagementManagedDevice - Microsoft.Graph.Beta.DeviceManagement
    Get-MgBetaDeviceManagementDeviceCategory - Microsoft.Graph.Beta.DeviceManagement
    Invoke-MgGraphRequest - Microsoft.Graph.Authentication
Required Azure AD App permissions:
    Microsoft Graph Group.Read.All
    Microsoft Graph GroupMember.Read.All
    Microsoft Graph Device.ReadWrite.All
    Microsoft Graph DeviceManagementManagedDevices.ReadWrite.All
References:
    Authentication module cmdlets in Microsoft Graph PowerShell:
    https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands?view=graph-powershell-1.0#use-delegated-access-with-a-custom-application-for-microsoft-graph-powershell
PJM - 10/31/2025
#>
######## Begin Setting Required Variables ########
$Timestamp = get-date -f yyyy-MM-dd-HH-mm-ss
Write-Output "Script began at $Timestamp"
# Connecto Managed Identity
Connect-AzAccount -Identity
# Credentials from Key Vault
$TenantId = Get-AzKeyVaultSecret -VaultName '<YOUR VAULT NAME HERE>' -Name 'tenantid' -AsPlainText
$ClientId = Get-AzKeyVaultSecret -VaultName '<YOUR VAULT NAME HERE>' -Name 'clientid' -AsPlainText
$ClientSecretCredential = Get-AzKeyVaultSecret -VaultName '<YOUR VAULT NAME HERE>' -Name 'clientsecret' -AsPlainText
$Creds = [System.Management.Automation.PSCredential]::new($ClientId, (ConvertTo-SecureString $ClientSecretCredential -AsPlainText -Force))
# Device Catergory and Group Names
$CategoryName = '<YOUR DEVICE CATEGORY NAME HERE>'
$GroupName = '<YOUR AZURE AD GROUP NAME HERE>'
# Get the current UTC time as a [datetime] instance and subtract 1 hour.
$CurrentTime = [DateTime]::UtcNow
$M1Time = $CurrentTime.AddHours(-1)
$D7Time = $CurrentTime.AddDays(-7)
# Base URL for the beta endpoint
[string]$baseUrl = "https://graph.microsoft.com/beta"
# Added to work around an error
$MaximumFunctionCount = 8192
$MaximumVariableCount = 8192
######## End Setting Required Variables ########
######## Begin Functions ########
####################################################
# Get device info from Intune
function Get-DeviceInfo {
    Get-MgBetaDeviceManagementManagedDevice -Filter "AzureAdDeviceId eq '$ComputerID'" -all `
    | Select-Object DeviceName, DeviceCategoryDisplayName, id
}
####################################################
# Set the device category
function Set-DeviceCategory {
[CmdletBinding()]
    param (
[parameter(Mandatory)][string] $DeviceID,
[parameter(Mandatory)][string] $CategoryID
    )
    Write-Output "Updating device category for $Computer"
    $requestBody = @{
        "@odata.id" = "$baseUrl/deviceManagement/deviceCategories/$CategoryID"
    }
    $uri = "$baseUrl/deviceManagement/managedDevices/$DeviceID/deviceCategory/`$ref"
    Write-Output "request-url: $uri"
    Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $requestBody
    Write-Output "Device category for $Computer updated"
}
####################################################
# Check to see if the group has changed in the last hour - iF no changes in the last hour let's loop for 10 min before continuing!
function Get-GroupChanges {
    $url = "https://graph.microsoft.com/Beta/groups/$($objid)?`$select=membershipRuleProcessingStatus"
    $LastChange = (Invoke-MgGraphRequest -Method GET -Uri $url).membershipRuleProcessingStatus
    $Updated = $LastChange.lastMembershipUpdated
    Write-Output "Last update to the group was $Updated"
}
######## End Functions ########
######## Script entry point  ########
# Connect to MgGraph
Write-Output "connecting to: MgGraph"
Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $creds -NoWelcome
# Get the object ID of the target group
$Group = (Get-MgBetaGroup -Filter "DisplayName eq '$GroupName'" ) | Select -ExpandProperty DisplayName
if ($Group) {
    $objid = (Get-MgBetaGroup -Filter "DisplayName eq '$Group'" ) | Select -ExpandProperty id
    Write-Output "Found $GroupName group having ID: $objid"
    # Get the last time the group membership changed. If no changes in the last hour loop for 10 minutes waiting for changes.
    Get-GroupChanges
    if ($Updated -ge $M1Time) {
        Write-Output 'No changes in the last hour, checking 10 more times (once every minute)'
        1..10 | foreach {
            Get-GroupChanges
            #$Updated = $LastChange.lastMembershipUpdated
            If ($Updated -ge $M1Time) {
                Write-Output "Still no changes, keep looping."
            }
            else {
                Exit
            }
            Sleep 60
        }
    }
    else {
        Write-Output 'Recent changes need to be processed!'
    }
    # Get the members of the group
    $Computers = Get-MgBetaGroupMember -GroupId $objid -All | ForEach { Get-MgBetaDevice -DeviceId $_.Id | Select DisplayName, DeviceID, ApproximateLastSignInDateTime }
    Write-Output "Found $($Computers.Count) computers in $Group"
    # Check each group member for the proper category and change if needed.
    if ($Computers) {
        # Set Device Category
        if ($CategoryName) {
            # Validate category name is valid
            Write-Output "validating requested category: $CategoryName"
            Write-Output "Getting List of Categories from Intune"
            $Categories = Get-MgBetaDeviceManagementDeviceCategory -All
            $CatNames = $Categories.DisplayName
            Write-Output "Found $($Categories.Count) Categories in Intune"
            $Category = $Categories | Where-Object { $_.displayName -eq $CategoryName }
            if (!($Category)) {
                Write-Output  "Invalid category name specified. Exiting with making any changes!"
                $Timestamp = get-date -f yyyy-MM-dd-HH-mm-ss
                Write-Output "Script ended at $Timestamp"
                Exit 1
            }
            $CategoryID = $Category.id
            Write-Output "$CategoryName category has ID: $CategoryID"
        }
        else {
            Write-Error "No category name was specified. Exiting with making any changes!"
            $Timestamp = get-date -f yyyy-MM-dd-HH-mm-ss
            Write-Output "Script ended at $Timestamp"
            Exit 0
        }
        # Set the device categories
        foreach ($Computer in $Computers) {
            # Determine the last time the device signed in and skip it if more than 7 days to avoid working on stale devices.
            ##### THE LAST SIGNIN NEEDS TO BE TESTED TO ENSURE NEW AUTOPILOT DEVICES SHOW A SIGNIN DATE #####
            $LastSignin = $Computer.ApproximateLastSignInDateTime
            $ComputerID = $Computer.DeviceID
            $DisplayName = $Computer.DisplayName
            if ($LastSignin -gt $D7Time) {
                Write-Output "$Computer.DisplayName last signed in $LastSignin. Likely a valid device, let's work on it."
                $Device = Get-DeviceInfo
                Write-Output "Found $($Device.Count) devices in Intune"
                if (!($device)) {
                    Write-Error "$DisplayName not found in Intune"
                }
                else {
                    $DeviceID = $Device.id
                    if ($Device.deviceCategoryDisplayName -ne $CategoryName) {
                        Write-Progress -Status "Updating Device Category" -Activity "$DisplayName ($deviceId) --> $($device.deviceCategoryDisplayName)"
                        Write-Output "Device Name = $DisplayName"
                        Write-Output "Device ID = $DeviceID"
                        Write-Output "Current category is $($Device.deviceCategoryDisplayName)"
                        Write-Output "Setting category to $CategoryName"
                        Set-DeviceCategory -DeviceID $DeviceID -category $CategoryID
                    }
                    else {
                        Write-Output "$DisplayName is already in $CategoryName"
                    }
                }
            }
            Else {
                Write-Warning "$DisplayName last signed in $LastSignin. Likely an invalid device, let's skip it."
            }
        }
    }
    Else {
        Write-Output "No computers found in $Group. Exiting without any changes."
        $Timestamp = get-date -f yyyy-MM-dd-HH-mm-ss
        Write-Output "Script ended at $Timestamp"
        Exit 0
    }
}
else {
    Write-Error "You have specified an invalid group."
}
$Timestamp = get-date -f yyyy-MM-dd-HH-mm-ss
 Write-Output "Script ended at $Timestamp"
