
# Used for AWS Windows AMI Userdata.
#
# Two main functions:
#  1. Remap drives based on the EC2 tags "DriveLetter" and "DriveLabel".  These
#     tags are expected on EBS volumes, and "DriveLetter" should end in ":".
#     For this to work, the instance must be launched with the "readonlyEC2"
#     role, so it can get the volume tags.
#  2. Run any scripts (in lexical sort order) that are in C:\Scripts\Startup
#     and have a ".ps1" extension.  That way your custom AMI, based on an 
#     Amazon Windows AMI, can define scripts in that directory and run them 
#     on boot.
#
#  This script will enable policy to allow the AWS Powershell tools to run,
#   and will install those tools as well.  It also sets disk policy to bring
#   all disks online by default, and sets the EC2Config setting such that 
#   userdata (i.e. this script) is run on every boot.

function Init-Log() {
    if ($global:logfile) {
        $datestamp = Get-Date -format u
        $l = "${datestamp}: "
        if ( test-path $global:logfile ) {
            write-output "${l}Restarting log" | out-file -append $global:logfile
        } else {
            write-output "${l}Starting log" | out-file $global:logfile
        }
    }
}

function Log-ToFile($logstr) {
    if ($global:logfile) {
        $datestamp = Get-Date -format u
        $l = "${datestamp}: ${logstr}"
        write-output $l | out-file -append $global:logfile
    }
}

function Get-DeviceMappings($BlockDeviceMappings) {
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2-windows-volumes.html#windows-list-disks
    # List the Windows disks

    # Create a hash table that maps each device to a SCSI target
    $Map = @{"0" = '/dev/sda1'} 
    for($x = 1; $x -le 25; $x++) {$Map.add($x.ToString(), [String]::Format("xvd{0}",[char](97 + $x)))}
    for($x = 26; $x -le 51; $x++) {$Map.add($x.ToString(), [String]::Format("xvda{0}",[char](71 + $x)))}
    for($x = 52; $x -le 77; $x++) {$Map.add($x.ToString(), [String]::Format("xvdb{0}",[char](45 + $x)))}
    for($x = 78; $x -le 103; $x++) {$Map.add($x.ToString(), [String]::Format("xvdc{0}",[char](19 + $x)))}
    for($x = 104; $x -le 129; $x++) {$Map.add($x.ToString(), [String]::Format("xvdd{0}",[char]($x - 7)))}

    Get-WmiObject -Class Win32_DiskDrive | % {
        $Drive = $_
        # Find the partitions for this drive
        Get-WmiObject -Class Win32_DiskDriveToDiskPartition |  Where-Object {$_.Antecedent -eq $Drive.Path.Path} | %{
            $D2P = $_
            # Get details about each partition
            $Partition = Get-WmiObject -Class Win32_DiskPartition |  Where-Object {$_.Path.Path -eq $D2P.Dependent}
            # Find the drive that this partition is linked to
            $Disk = Get-WmiObject -Class Win32_LogicalDiskToPartition | Where-Object {$_.Antecedent -in $D2P.Dependent} | %{ 
                $L2P = $_
                #Get the drive letter for this partition, if there is one
                Get-WmiObject -Class Win32_LogicalDisk | Where-Object {$_.Path.Path -in $L2P.Dependent}
            }
            $BlockDeviceMapping = $BlockDeviceMappings | Where-Object {$_.DeviceName -eq $Map[$Drive.SCSITargetId.ToString()]}
           
            # Display the information in a table
            New-Object PSObject -Property @{
                Device = $Map[$Drive.SCSITargetId.ToString()];
                Disk = [Int]::Parse($Partition.Name.Split(",")[0].Replace("Disk #",""));
                Boot = $Partition.BootPartition;
                Partition = [Int]::Parse($Partition.Name.Split(",")[1].Replace(" Partition #",""));
                SCSITarget = $Drive.SCSITargetId;
                DriveLetter = If($Disk -eq $NULL) {""} else {$Disk.DeviceID};
                VolumeName = If($Disk -eq $NULL) {""} else {$Disk.VolumeName};
                VolumeId = If($BlockDeviceMapping -eq $NULL) {"NA"} else {$BlockDeviceMapping.Ebs.VolumeId}
            }
        }
    } | Sort-Object Disk, Partition | Select-Object
}

function Install-AWSpackage {
    # Try the import
    $junk=(Import-Module AWSPowerShell)
    $m=(Get-Module -Name "AWSPowerShell")
    if ($m) {
        # Already installed.
        return
    }
    Log-ToFile "Installing AWS Tools"
    $awsurl="http://sdk-for-net.amazonwebservices.com/latest/AWSToolsAndSDKForNet.msi"
    $outdir="C:\Downloads"
    $isoutdir=Test-Path -path $outdir
    if (! $isoutdir) {
        $junk=(New-Item -type directory $outdir)
    }
    $output=$outdir + "\awssdk.msi"
    $wc=New-Object System.Net.WebClient
    $wc.DownloadFile($awsurl,$output)
    msiexec /qn /i $output
    Import-Module AWSPowerShell
    # Clean up
    Remove-Item $output 
    if (! $isoutdir) {
        Remove-Item -recurse $outdir
    }
}

function Enable-UserData {
    # This path is always constant for an Amazon Windows AMI
    $path="C:\Program Files\Amazon\Ec2ConfigService\Settings\config.xml"
    $xml=[xml](Get-Content $path) 
    $node=($xml.Ec2ConfigurationSettings.Plugins.Plugin | where {$_.Name -eq "Ec2HandleUserData"})
    if ($node.State -ne "Enabled") {
        Log-ToFile "Enabling User Data for each boot"
        $node.State="Enabled"
        $xml.Save($path)
    }    
}

function Remap-Drives {
    Set-StorageSetting -NewDiskPolicy OnlineAll
    $diskset=Get-NonBootDisks
    ForceReadWrite-Disks($diskset)
    Online-AllDisks($diskset)
    # Get mapping
    $map=RelabelAndMapDrives
    $tempdrive=Get-FreeDriveLetter
    Fix-DriveLetters $tempdrive $map
}

function Get-NonBootDisks {
    # Rescan disks
    Update-HostStorageCache
    get-Disk | ?{$_.Number -gt 0}  
}

function ForceReadWrite-Disks($diskset) {
    # All non-boot disks become read-write 
    $diskset | % { set-Disk -number $_.Number -isReadOnly $false}
}

function Online-AllDisks($diskset) {    
    # Detach, then reattach, disks in presented diskset
    $update=$false
    foreach ($d in $diskset) {
        if ( $d.OperationalStatus -eq "Offline" ) {
            $dnum=$d.Number
            Log-ToFile "Bringing disk $dnum online"
            set-Disk -number $dnum -isOffline $false
            $update=$true
        }
    }
    if ($update) {
        Update-HostStorageCache
    }
}

function RelabelAndMapDrives {
    # Get the AZ, which lets us derive the region
    $az=Get-EC2Metadata("/placement/availability-zone")
    $region=$az.Substring(0,$az.Length-1)
    # Get session creds (need to launch instance with role with 
    #  policy to allow getting instance details)
    $role=Get-EC2Metadata("/iam/security-credentials")
    $creds=(Get-EC2Metadata("/iam/security-credentials/$role")| ConvertFrom-Json)
    $id=Get-EC2Metadata("/instance-id")
    $aki=($creds.AccessKeyId)
    $sak=($creds.SecretAccessKey)
    $tok=($creds.Token)
    $inst=(get-ec2instance -region $region -accesskey $aki -secretkey $sak -sessiontoken $tok -instanceid $id).Instances
    $bdm=$inst.BlockDeviceMappings | ?{$_.DeviceName -ne "/dev/sda1"}
    $map=@{}
    # Get list of logical disks to match EC2 devices
    $ldisks = Get-DeviceMappings $inst.BlockDeviceMappings
    $lstr=$ldisks | out-string
    Log-ToFile "Device Mappings: $lstr"
    $lindex=$bdm.Length # Initialize
    $refresh=$false
    foreach ($b in $bdm) {  
        $volid=$b.Ebs.VolumeId
        if ($volid -eq "NA") {
            # Not an EBS volume.
            continue
        }
        $driveletter=(get-ec2Tag -region $region -accesskey $aki -secretkey $sak -sessiontoken $tok -Filter @{ Name="resource-id";Values="$volid"},@{ Name="key";Values="DriveLetter"}).Value
        $drivelabel=(get-ec2Tag -region $region -accesskey $aki -secretkey $sak -sessiontoken $tok -Filter @{ Name="resource-id";Values="$volid"},@{ Name="key";Values="DriveLabel"}).Value
        Log-ToFile "Volid: $volid / Driveletter: $driveletter / Drivelabel $drivelabel" 
        $match=($ldisks | where {$_.VolumeId -eq $volid})
        $mstr=$match | out-string
        Log-Tofile "Match: $mstr"
        if ($match) {
            $ntfslbl=$match.VolumeName
            $dlett=$match.DriveLetter
            Log-ToFile "Volid $volid (Label $drivelabel / Driveletter $driveletter) maps to -> (Label $ntfslbl / Driveletter $dlett)" 
            if ($ntfslbl -ne $drivelabel) {
                Log-ToFile "Relabelling $ntfslbl to $drivelabel" 
                # Relabel disk to match EC2 Tag for drive label
                if ($ntfslbl) {
                    $disk=Get-WMIObject win32_volume | Where {$_.Label -eq $ntfslbl}
                } else {
                    $disk=Get-WMIObject win32_volume | where {$_.DriveLetter -eq $dlett}
                }
                if ($disk) {
                    $disk.Label=$drivelabel
                    $junk=$disk.Put()
                    $refresh=$true
                }
            }
        }
        if (($driveletter) -and ($drivelabel)) {
            # Make sure it ends in a colon.
            if ($driveletter.Substring(($driveletter.Length) - 1) -ne ':') {
                $driveletter=$driveletter+':'
            }
            $map.Add($drivelabel,$driveletter)
        }
    }
    if ($refresh) {
        Update-HostStorageCache
    }
    # Return the label-to-letter map
    $map
}

function Get-EC2Metadata($item) {
    $md="http://169.254.169.254/latest/meta-data"
    if ($item.Substring(0,1) -ne '/') {
        # Prepend a slash if it doesn't start with one.
        $item = '/' + $item
    }   
    $uri=$md + $item
    (Invoke-WebRequest -uri $uri -UseBasicParsing).Content
}

function Get-FreeDriveLetter {
    # Pick out all single-letter drives
    $used=Get-PSDrive | Select-Object -Expand Name | Where-Object { $_.Length -eq 1 }
    # Start at D: (char 68)
    $dr=(68..90 | ForEach-Object { [string][char]$_ } | where { $used -notcontains $_} | select-object -first 1)
    $dr + ":"
}

function Fix-DriveLetters($tempdrive,$map) {
    # For each label/letter mapping, if the drive isn't already mapped there:
    #  If there is some drive mapped there, move that drive to the tempdrive (which is the first free drive letter).
    #  Then move the labelled drive to the right letter.
    #  If you had to move a drive out of the way, move it to the labelled drive's original letter.
    foreach($h in $map.GetEnumerator()) {
        $driveletter=$h.Value
        $label=$h.Name   
        Log-ToFile "Label $label / Letter $driveletter"
        $lqry="Label = '$label'"
        $drive=Get-WMIObject win32_volume -filter "$lqry"
        if ($drive) {
            $dl=$drive.DriveLetter
            if ( $dl -ne $driveletter) {
                Log-ToFile " - Currently mounted at $dl"     
                $dlqry="DriveLetter = '$driveletter'"
                $movedrive=Get-WMIObject win32_volume -filter "$dlqry"
                if ($movedrive) {
                    if (! $tempdrive) {
                        Throw 'Could not get free drive letter; cannot swap disks.'
                        return # Not reached
                    }
                    Log-ToFile  " -- Move $driveletter -> $tempdrive"                      
                    $movedrive.DriveLetter=$tempdrive
                    $junk=$movedrive.Put()
                }
                Log-ToFile " - Move $dl -> $driveletter"                                   
                $drive.DriveLetter=$driveletter
                $junk=$drive.Put()
                if ($movedrive) {
                    Log-Tofile " -- Move $tempdrive -> $dl"                               
                    $movedrive.DriveLetter=$dl
                    $junk=$movedrive.Put()
                }
            }
        }
    }   
}

function Run-StartupScripts {
    Log-ToFile "Running Startup Scripts"
    $startscriptpath="C:\Scripts\Startup"
    Run-Scripts($startscriptpath)
}

function Run-Scripts($path) {
    if ( ! ($path -and ( Test-Path $path ) ) ) {
        # No script directory
        return
    }
    $scripts=(Get-ChildItem -Path $path | Where { $_.Extension -eq ".ps1" } | Sort).Name
    foreach ($s in $scripts) {
        $spath=$path + '\' + $s
        Log-ToFile "Running script $spath"
        Invoke-Expression $spath
        Log-ToFile "Ran script $spath"
    }
}

function main {
    # It's actually run as unrestricted anyway
    Set-ExecutionPolicy RemoteSigned -force    
    $global:logfile="C:\userdata-log.txt" # Comment out to turn off logs
    Init-Log
    Install-AWSPackage
    Enable-UserData
    Remap-Drives
    Run-StartupScripts
}

main
