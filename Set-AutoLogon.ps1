﻿#Requires -RunAsAdministrator
<#
**************************************************************************************************************************************
Name:               Set-Autologon
Author:             Kasper Johansen
Company:            edgemo
Contact:            kjo@edgemo.com
Version:            1.0            
Last modified by:   Kasper Johansen
Last modified Date: 11-12-2019

# Changes
11-12-2019 - Added taskkill command, on line 113, to force Excel, Word and Outlook to forcefully close, before log off.
23-12-2019 - Removed the above taskkill change. Added a dedicated job for killing processes before logoff. 
             The job is part of the ForEach loop starting on line 109.
             The job is implemented the make sure the auto logon user is properly logged off, 
             even when applications for some reason hangs or are waiting for input.
24-08-2021 - Fixed an issue with the randomly generated secure password not being configured correct in registry

******************************************************************************************************************************************

.SYNOPSIS
    This script creates a local user which is scheduled to logon automatically.

.DESCRIPTION
    This script is intended to be used on Citrix Provisioning target devices (VDAs). It enables a local user to logon automatically
    and start a range of applications defined in an XML file. A sample XML file is included as a reference. 
    
    !!Important!! The applications defined in the XML files must have processes ending in .exe, any other process types are not supported.
    
    The auto logon and startup of applications are done via 2 local scheduled tasks.

.PARAMETER $Username
    The name of the local user to auto logon to the VDA.

.PARAMETER $Password
    The password for the local user.

.PARAMETER $AutoLogonXML
    The full path to the XML file. If not defined, the script assumes that the XML file is located in the same folder, as this script.

.EXAMPLES
    Creates a local user named autlogon with a password:
            Set-Autologon -UserName -Password Password1

    Creates a local user named autlogon with a password and reading an XML file in another location:
            Set-Autologon -UserName -Password Password1 -AutoLogonXML "\\domain.local\myxmlfile.xml"



******************************************************************************************************************************************
#>
    param(
         [Parameter(Mandatory = $true)]
         [string]$Username,
         #[Parameter(Mandatory = $true)]
         #[string]$Password,
         [string]$AutoLogonXML = ".\AutoLogon.xml"
         )

function Create-ScheduledTask
    {
    param(
         [Parameter(Mandatory = $true)]
         [string]$TaskName,
         [Parameter(Mandatory = $true)]
         [string]$AppExecutable,
         [string]$AppArgument,
         [Parameter(Mandatory = $true)]
         [string]$User,
         [Parameter(Mandatory = $true)]
         [string]$LogonUser
         )
            # Check if $AppArgument is not defined/empty
            If (!([string]::IsNullOrWhiteSpace($AppArgument)))
            {
                $A = New-ScheduledTaskAction –Execute $AppExecutable -Argument $AppArgument
            }
            else
                {
                    $A = New-ScheduledTaskAction –Execute $AppExecutable    
                }

            $T = New-ScheduledTaskTrigger -AtLogon -User $LogonUser
            $P = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive
            $S = New-ScheduledTaskSettingsSet
            $D = New-ScheduledTask -Action $A -Principal $P -Trigger $T -Settings $S
            Register-ScheduledTask $TaskName -TaskPath \AutoLogon -InputObject $D    
    }

function New-RandomPassword {
    param(
        [Parameter()]
        [int]$MinimumPasswordLength = 5,
        [Parameter()]
        [int]$MaximumPasswordLength = 10,
        [Parameter()]
        [int]$NumberOfAlphaNumericCharacters = 5,
        [Parameter()]
        [switch]$ConvertToSecureString
    )
    
    Add-Type -AssemblyName 'System.Web'
    $length = Get-Random -Minimum $MinimumPasswordLength -Maximum $MaximumPasswordLength
    $password = [System.Web.Security.Membership]::GeneratePassword($length,$NumberOfAlphaNumericCharacters)
    if ($ConvertToSecureString.IsPresent) {
        ConvertTo-SecureString -String $password -AsPlainText -Force
    } else {
        $password
    }
}

function Set-AutoLogon
    {

# Create auto logon user
$LocalUserPwd = New-RandomPassword -MinimumPasswordLength 10 -MaximumPasswordLength 15 -NumberOfAlphaNumericCharacters 6 -ConvertToSecureString
New-LocalUser -Name $Username -Password $LocalUserPwd -Verbose
Add-LocalGroupMember -Group "Users" -Member $Username -Verbose

# Configure auto logon user
$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$SecurePasswordInMemory = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($LocalUserPwd)
$Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($SecurePasswordInMemory)
Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value "1" -type String  
Set-ItemProperty -Path $RegPath -Name "DefaultUsername" -Value "$Username" -type String  
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value "$Password" -type String
Set-ItemProperty -Path $RegPath -Name "AutoLogonCount" -Value "1" -type DWord

# Create Shceduled Task to delete auto logon user password information
Create-ScheduledTask -TaskName "Delete auto logon user password info" -User SYSTEM -LogonUser $Username -AppExecutable "%windir%\System32\reg.exe" -AppArgument "delete `"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon`" /v DefaultPassword /f"

# Get apps in Autologon.xml
[xml]$Configuration = Get-Content -Path .\AutoLogon.xml
$Apps = $Configuration.SelectNodes("//Apps/App")
$AppsPath = $Configuration.SelectNodes("//Apps/App").Path
$AppsExecutable = $Configuration.SelectNodes("//Apps/App").Executable

# Create scheduled task for each defined in Autologon.xml
ForEach ($App in $Apps)
{
    $AppPath = $App.Path
    $AppExec = $App.Executable
    Create-ScheduledTask -TaskName $App.Name -User $Username -LogonUser $Username -AppExecutable "$AppPath\$AppExec"
}

# Create scheduled task to kill processes before logoff
ForEach ($App in $AppsExecutable)
{
[array]$KillApps +=$App -replace ".exe",""
}
$KillApps = $KillApps -join ","
Create-ScheduledTask -TaskName "Log off auto logon user" -User $Username -LogonUser $Username -AppExecutable "%windir%\system32\WindowsPowerShell\v1.0\powershell.exe" -AppArgument "-WindowStyle Minimized -Command `"& {Start-Sleep -S 240; Stop-Process -Name $KillApps -Force; Start-Sleep -S 60; logoff}`""


# Create scheduled task to logoff the auto logon user
#Create-ScheduledTask -TaskName "Logoff auto logon user" -User $Username -LogonUser $Username -AppExecutable "%windir%\system32\cmd.exe" -AppArgument "/c `"timeout /t 300 && taskkill /IM excel.exe /F && taskkill /IM winword.exe /F && taskkill /IM outlook.exe /F && logoff`""
#Create-ScheduledTask -TaskName "Logoff auto logon user" -User $Username -LogonUser $Username -AppExecutable "%windir%\system32\cmd.exe" -AppArgument "/c `"timeout /t 300 && logoff`""

    }

Set-AutoLogon $Username $AutoLogonXML