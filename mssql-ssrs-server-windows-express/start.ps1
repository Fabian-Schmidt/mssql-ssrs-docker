# The script sets the sa password and start the SQL Service 
# Also it attaches additional database from the disk
# The format for attach_dbs

param(
[Parameter(Mandatory=$false)]
[string]$sa_password,

[Parameter(Mandatory=$false)]
[string]$ACCEPT_EULA,

[Parameter(Mandatory=$false)]
[string]$attach_dbs
)


if($ACCEPT_EULA -ne "Y" -And $ACCEPT_EULA -ne "y")
{
	Write-Verbose "ERROR: You must accept the End User License Agreement before this container can start."
	Write-Verbose "Set the environment variable ACCEPT_EULA to 'Y' if you accept the agreement."

    exit 1 
}

# start the service
Write-Verbose "Starting SQL Server"
Start-Service MSSQL`$SQLEXPRESS

if($sa_password -eq "_") {
    $secretPath = $env:sa_password_path
    if (Test-Path $secretPath) {
        $sa_password = Get-Content -Raw $secretPath
    }
    else {
        Write-Verbose "WARN: Using default SA password, secret file not found at: $secretPath"
    }
}

if($sa_password -ne "_")
{
    Write-Verbose "Changing SA login credentials"
    $sqlcmd = "ALTER LOGIN sa with password=" +"'" + $sa_password + "'" + ";ALTER LOGIN sa ENABLE;"
    & sqlcmd -Q $sqlcmd
}

$attach_dbs_cleaned = $attach_dbs.TrimStart('\\').TrimEnd('\\')

$dbs = $attach_dbs_cleaned | ConvertFrom-Json

if ($null -ne $dbs -And $dbs.Length -gt 0)
{
    Write-Verbose "Attaching $($dbs.Length) database(s)"
	    
    Foreach($db in $dbs) 
    {            
        $files = @();
        Foreach($file in $db.dbFiles)
        {
            $files += "(FILENAME = N'$($file)')";           
        }

        $files = $files -join ","
        $sqlcmd = "IF EXISTS (SELECT 1 FROM SYS.DATABASES WHERE NAME = '" + $($db.dbName) + "') BEGIN EXEC sp_detach_db [$($db.dbName)] END;CREATE DATABASE [$($db.dbName)] ON $($files) FOR ATTACH;"

        Write-Verbose "Invoke-Sqlcmd -Query $($sqlcmd)"
        & sqlcmd -Q $sqlcmd
    }
}

Write-Verbose "Started SQL Server"

Write-Verbose 'Create Login [ssrs_user]'
$ssrs_user_pwd = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_});
$sqlcmd = "CREATE LOGIN [ssrs_user] with password='" + $ssrs_user_pwd + "', CHECK_EXPIRATION=OFF, CHECK_POLICY=OFF;"
& sqlcmd -Q $sqlcmd
$sqlcmd = "ALTER SERVER ROLE [sysadmin] ADD MEMBER [ssrs_user];";# Temporary permission
& sqlcmd -Q $sqlcmd
$ssrs_user_pwd = $ssrs_user_pwd | ConvertTo-SecureString -asPlainText -Force;
$ssrs_user = New-Object System.Management.Automation.PSCredential('ssrs_user', $ssrs_user_pwd);

Write-Verbose 'Set-RsDatabase'
Set-RsDatabase -ReportServerVersion SQLServer2017 -ReportServerInstance 'SSRS' -DatabaseServerName 'localhost' -Name 'ReportServerDb' -DatabaseCredentialType SQL -DatabaseCredential $ssrs_user -Confirm:$false

#Write-Verbose 'Set-RsUrlReservation'
#Set-RsUrlReservation -ReportServerVersion SQLServer2017 -ReportServerInstance 'SSRS' -ReportServerVirtualDirectory 'ReportServer' -PortalVirtualDirectory 'Reports' -ListeningPort 80

Stop-Service SQLServerReportingServices

if($sa_password -ne "_")
{
    $ssrs_userName = "SSRS_SA";
    Write-Verbose "Create User $ssrs_userName"
    $ssrs_fullName = "SSRS Service Account";
    $ssrs_Password = $sa_password | ConvertTo-SecureString -asPlainText -Force;
    New-LocalUser $ssrs_userName -Password $ssrs_Password -FullName $ssrs_fullName -Description "Service Account for SSRS." -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword;
    Add-LocalGroupMember -Group 'Administrators' -Member $ssrs_userName
}
$ssrs_ops_userName = 'SSRSOperations';
Write-Verbose "Create User $ssrs_ops_userName"
$ssrs_ops_fullName = 'SSRS Operations Account';
$ssrs_ops_password = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object {[char]$_}) | ConvertTo-SecureString -asPlainText -Force;
$ssrs_ops = New-Object System.Management.Automation.PSCredential($ssrs_ops_userName, $ssrs_ops_password);
New-LocalUser $ssrs_ops_userName -Password $ssrs_ops_password -FullName $ssrs_ops_fullName -Description "Service Account for SSRS." -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword;
Add-LocalGroupMember -Group 'Administrators' -Member $ssrs_ops_userName

#Initialize-Rs -ReportServerVersion SQLServer2017 -ReportServerInstance 'SSRS'

Write-Verbose "Remove Temporary permission"
$sqlcmd = @"
ALTER DATABASE [ReportServerDb] SET AUTO_CLOSE OFF WITH NO_WAIT;
GO
ALTER DATABASE [ReportServerDbTempDB] SET AUTO_CLOSE OFF WITH NO_WAIT;
GO
ALTER SERVER ROLE [sysadmin] DROP MEMBER [ssrs_user];
GO
USE [ReportServerDb]
GO
CREATE USER [ssrs_user] FOR LOGIN [ssrs_user]
GO
ALTER ROLE [RSExecRole] ADD MEMBER [ssrs_user]
GO
USE [ReportServerDbTempDB]
GO
CREATE USER [ssrs_user] FOR LOGIN [ssrs_user]
GO
ALTER ROLE [RSExecRole] ADD MEMBER [ssrs_user]
GO
"@
& sqlcmd -Q $sqlcmd

Write-Verbose "Starting SSRS Server"

Start-Service SQLServerReportingServices

Write-Verbose "Started SSRS Server"

$sqlcmd_IndexOptimize = @"
EXECUTE dbo.IndexOptimize
@Databases = 'USER_DATABASES',
@FragmentationLow = NULL,
@FragmentationMedium = 'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
@FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
@FragmentationLevel1 = 5,
@FragmentationLevel2 = 30,
@UpdateStatistics = 'ALL',
@OnlyModifiedStatistics = 'Y'
"@

$lastCheck = (Get-Date).AddSeconds(-2);
$nextCheckSSRS = (Get-Date).AddSeconds(30);
$nextCheckSQLIndex = (Get-Date).AddSeconds(120);
while ($true) 
{ 
    # Get MSSQL log
    Get-EventLog -LogName Application -Source "MSSQL*", 'Report Server *' -After $lastCheck | Select-Object TimeGenerated, Source, EntryType, Message;
    $lastCheck = Get-Date;

    # Check SSRS health
    if ($nextCheckSSRS -lt $lastCheck)
    {
        $data = Invoke-WebRequest -Uri 'http://localhost/ReportServer/' -Credential $ssrs_ops -TimeoutSec 30 -UseBasicParsing;
        $nextCheckSSRS = (Get-Date).AddSeconds(30);
    }

    # TODO: Copy SSRS logs

    # SQL Maintenance tasks
    if ($nextCheckSQLIndex -lt $lastCheck) {
        Start-Process -Wait -FilePath sqlcmd -ArgumentList '-Q', $sqlcmd_IndexOptimize, '-b', '-o', 'C:\Log\IndexOptimize.txt';
        $nextCheckSQLIndex = (Get-Date).AddMinutes(30);
    }

    # TODO: SQL Backup
    # TODO: New SSRS reports from Storage / Notification
    
    Start-Sleep -Seconds 5;
}
