Function ExecCommand($command) {
    $r = [regex]::match($command, "([^\s]+)\s+(.+)")
    if ($r.Success) {    
        $filename = $r.Groups[1].Value
        $arguments = $r.Groups[2].Value
    }
    else {
        $filename = $command
        $arguments = $null
    }
    Write-Host "Filename: $filename"
    Write-Host "Arguments: $arguments"

    $process = New-Object System.Diagnostics.Process;
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.FileName = $filename
    $process.StartInfo.Arguments = $arguments
    $started = $process.Start()
    
    $out = $process.StandardOutput.ReadToEnd()
    $err = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    
    return ($process.ExitCode, $out, $err)
}


function postState(){
  Param(
    [string]$uri,
    [string]$key,
    [string]$name,
    [string]$state
  )
  $user, $pass = $key.Split(':')
  $passConv = ConvertTo-SecureString -String $pass -AsPlainText -Force
  $credentials = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $user,$passConv

  Invoke-WebRequest -Uri "$uri/crowbar/crowbar/1.0/transition/default" -Credential $credentials -ContentType 'application/json' -Method Post -OutFile "c:\Crowbar\Logs\$name-$state.json" -Body "{`"name`": `"$name`", `"state`": `"$state`"}"

  if($?){
    Add-Content -Path "c:\Crowbar\Logs\$name-$state.log" -Value "$(Get-Date): $cmd returned with code $?."
  }else{
    Add-Content -Path "c:\Crowbar\Logs\$name-$state.log" -Value "$(Get-Date): $cmd returned with code $?. Error was: $error[0]"
  }
}

function syncTime(){
  Param(
    [string]$address
  )
  # See http://support.microsoft.com/kb/816042
  w32tm /register
  $s = Get-Service w32time
  if ($s.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
  {
    $s.Stop()
  }

  net start w32time 
  w32tm /config "/manualpeerlist:$address,0x8" /syncfromflags:MANUAL /reliable:yes /update
  w32tm /resync
}



$CrowbarKey=(Get-ItemProperty "HKLM:\SOFTWARE\Crowbar" -Name Key).Key 
$CrowbarIP=(Get-ItemProperty "HKLM:\SOFTWARE\Crowbar" -Name Address).Address 
$CrowbarUri= "http://"+$CrowbarIP+":3000"
$CrowbarMain="C:\Crowbar"
$CrowbarLogsFolder="$CrowbarMain\Logs"
$CrowbarLogFile="$CrowbarLogsFolder\crowbar.log"

$ChefClientMSI="chef-client-11.4.4-2.windows.msi"
$ChefFolder="C:/chef"

$ChefServerURL="`'http://"+$CrowbarIP+":4000`'"
$ChefServerCertificate="$ChefFolder/validation.pem"
$ChefClientCertificate="$ChefFolder/client.pem"
$ChefConfigFile="$ChefFolder/client.rb"
$ChefCacheLocation="$ChefFolder/cache"
$ChefBackupLocation="$ChefFolder/backup"
$ChefExec="C:\opscode\chef\bin\chef-client.bat"

if (!(Test-Path -path $CrowbarMain)) {New-Item $CrowbarMain -Type Directory}
if (!(Test-Path -path $CrowbarLogsFolder)) {New-Item $CrowbarLogsFolder -Type Directory}
if (!(Test-Path -path $ChefFolder)) {New-Item $ChefFolder -Type Directory}
$hostname=hostname

$s = Get-Service chef-client -ErrorAction SilentlyContinue
if ($s)
{
  if ($s.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running)
  {
    $s.Stop()
  }
}
Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Syncing time."
syncTime $CrowbarIP

Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Setting crowbar state to readying"
postState $CrowbarUri $CrowbarKey "$hostname" "readying"
$finalState="ready"

# for chef 10.18.2-2: $chef_reg_key="HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{A6ED465C-9C62-4EC2-A9A0-C133C67AC5FC}"
# for chef 11.4.4-2
Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Checking if chef-client is installed"
$chef_reg_key="HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{FCC87F22-4EE4-4D12-BBCC-E17ACCD47A81}"
if (-not (Test-Path -Path $chef_reg_key))
{
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Starting chef-client installation"
  # Start-Process -FilePath msiexec -ArgumentList "/i `"$CrowbarMain\$ChefClientMSI`" /qn /l*v `"$CrowbarLogsFolder\chef_install.log`" ADDLOCAL=ChefClientFeature,ChefServiceFeature" -wait
  Start-Process -FilePath msiexec -ArgumentList "/i `"$CrowbarMain\$ChefClientMSI`" /qn /l*v `"$CrowbarLogsFolder\chef_install.log`"" -wait
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Setting the service state to manual"
  Set-Service -Name chef-client -StartupType Manual
}
Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Checking if validation certificate is available"
if (-not (Test-Path -Path $ChefServerCertificate))
{
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Download validation certificate from the chef server"
  Invoke-WebRequest -Uri ("http://"+$CrowbarIP+":8091/validation.pem").ToString() -OutFile ($ChefServerCertificate+"get").ToString()
  Get-Content ($ChefServerCertificate+"get").ToString() | Set-Content $ChefServerCertificate
  Remove-Item ($ChefServerCertificate+"get").ToString()
}

Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Checking if chef config file is created"
if (-not (Test-Path -Path $ChefConfigFile))
{
  $hostname = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName
  $domain = (Get-ItemProperty "HKLM:\SOFTWARE\Crowbar" -Name Domain).Domain
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Creating chef config file"
  Add-Content $ChefConfigFile "log_level :debug"
  Add-Content $ChefConfigFile "node_name `"$hostname.$domain`""
  Add-Content $ChefConfigFile ("log_location `""+$CrowbarLogsFolder.Replace("\","/")+"/chef_client.log`"").ToString()
  Add-Content $ChefConfigFile "chef_server_url $ChefServerURL"
  Add-Content $ChefConfigFile "validation_key `"$ChefServerCertificate`""
  Add-Content $ChefConfigFile "client_key `"$ChefClientCertificate`""
  Add-Content $ChefConfigFile "file_cache_path `"$ChefCacheLocation`""
  Add-Content $ChefConfigFile "file_backup_path `"$ChefBackupLocation`""
  Add-Content $ChefConfigFile "cache_options ({:path=>`"$ChefCacheLocation/checksums`", :skip_expires=>true})"
}

Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Syncing time"
syncTime $CrowbarIP
Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Executing chef-client"
$ret=ExecCommand "$ChefExec"
Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value "$(Get-Date): $ChefExec finished first run with exitcode $exitcode"
Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value $ret[1]
Add-Content -Path "$CrowbarLogsFolder\chef_err.log" -Value $ret[2]
Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Executing chef-client"
$ret=ExecCommand "$ChefExec"
$exitcode=$ret[0]
Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value "$(Get-Date): $ChefExec finished second run with exitcode $exitcode"
Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value $ret[1]
Add-Content -Path "$CrowbarLogsFolder\chef_err.log" -Value $ret[2]
if ($exitcode -ne "0")
{
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Setting crowbar state to recovering"
  postState $CrowbarUri $CrowbarKey "$hostname" "recovering"
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Syncing time"
  syncTime $CrowbarIP
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Removing chef cache"
  Remove-Item "$ChefCacheLocation/*" -Recurse
  Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Executing chef-client"
  $ret=ExecCommand "$ChefExec"
  $exitcode=$ret[0]
  Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value "$(Get-Date): $ChefExec finished third run with exitcode $exitcode"
  Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value $ret[1]
  Add-Content -Path "$CrowbarLogsFolder\chef_err.log" -Value $ret[2]
  if ($exitcode -ne "0")
  {
    Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Syncing time"
    syncTime $CrowbarIP
    Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Removing chef cache"
    Remove-Item "$ChefCacheLocation/*" -Recurse
    Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Removing chef-client certificate"
    Remove-Item $ChefClientCertificate
    Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Setting crowbar state to installed"
    postState $CrowbarUri $CrowbarKey "$hostname" "installed"
    Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Executing chef-client"
    $ret=ExecCommand "$ChefExec"
    $exitcode=$ret[0]
    Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value "$(Get-Date): $ChefExec finished fourth run with exitcode $exitcode"
    Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value $ret[1]
    Add-Content -Path "$CrowbarLogsFolder\chef_err.log" -Value $ret[2]
    if ($exitcode -ne "0")
    {
      Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value "$(Get-Date):  System set in `"problem`" state."
      $finalState="problem"
    }
    else
    {
      Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Setting crowbar state to $finalState"
      postState $CrowbarUri $CrowbarKey "$hostname" "$finalState"
      Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Executing chef-client"
      $ret=ExecCommand "$ChefExec"
      $exitcode=$ret[0]
      Add-Content -Path "$CrowbarLogsFolder\chef.log" -Value "$(Get-Date): $ChefExec finished fifth run with exitcode $exitcode"
      Add-Content -Path "$CrowbarLogsFolder\chef_err.log" -Value $ret[2]
    }
  }
}

Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Setting crowbar state to $finalState"
postState $CrowbarUri $CrowbarKey "$hostname" "$finalState"

# If chef-client also registers as service, the part below is required:
#if ($finalState -eq "ready")
#{
  #Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Checking if the chef-client service is not running"
  #$s = Get-Service chef-client
  #if ($s.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running)
  #{
    #Add-Content -Path "$CrowbarLogFile" -Value "$(Get-Date): Starting the chef-client service"
    #$s.Start()
  #}
#}
