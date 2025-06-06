Add-Type -AssemblyName System.Collections

# Config
$Folder = "<FOLDER>"
$SourceRoot = "<DRIVE>:\$Folder"
$DestRoot = "\\<DESTINATION PATH>\$Folder"
$MaxThreads = 1000 #Put the # of Threads here which should be the number of simulatneous Robocopies running at once.
$LogDir = "\\<DESTINATION LOGGGING PATH>\Robocopy_logs\$Folder\$(Get-Date -Format yyyy-MM-dd_HH-mm)"
# Create the directory if it doesn't exist
if (-not (Test-Path -Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

# Get all first-level directories
$SubDirs = Get-ChildItem -Path $SourceRoot -Directory

# Create runspace pool
$SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads, $SessionState, $Host)
$RunspacePool.Open()

# Create a resizable list
$Runspaces = New-Object System.Collections.Generic.List[object]

foreach ($SubDir in $SubDirs) {
    $PowerShell = [powershell]::Create()
    $PowerShell.RunspacePool = $RunspacePool

    $SourcePath = $SubDir.FullName
    $DestPath = Join-Path -Path $DestRoot -ChildPath $SubDir.Name
    $LogFile = "$LogDir\RobocopyLog_$($SubDir.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

    $Script = {
        param($src, $dst, $log)
        #robocopy $src $dst /MIR /R:0 /W:0 /COPYALL /DCOPY:T /LOG:$log /TEE /MT:24
        robocopy $src $dst /E /xx /xo /R:0 /W:0 /COPYALL /DCOPY:T /LOG:$log /TEE /MT:24
    }

    $PowerShell.AddScript($Script).AddArgument($SourcePath).AddArgument($DestPath).AddArgument($LogFile)

    $AsyncResult = $PowerShell.BeginInvoke()
    $Runspaces.Add(@{ Pipe = $PowerShell; Handle = $AsyncResult })

    # Throttle if needed
    while ($Runspaces.Count -ge $MaxThreads) {
        for ($i = $Runspaces.Count - 1; $i -ge 0; $i--) {
            $r = $Runspaces[$i]
            if ($r.Handle.IsCompleted) {
                $r.Pipe.EndInvoke($r.Handle)
                $r.Pipe.Dispose()
                $Runspaces.RemoveAt($i)
            }
        }
        Start-Sleep -Milliseconds 500
    }
}

# Wait for all remaining threads to complete
foreach ($r in $Runspaces) {
    $r.Pipe.EndInvoke($r.Handle)
    $r.Pipe.Dispose()
}

# Cleanup
$RunspacePool.Close()
$RunspacePool.Dispose()

Write-Host "✅ All Robocopy operations completed using runspaces."
