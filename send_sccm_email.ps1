# Example PowerShell script to send an email after an SCCM Task Sequence completes.
# Adjust the SMTP server and addresses for your environment.

$computerName = $env:COMPUTERNAME
$adapter = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | Select-Object -First 1
$ipAddress = $adapter.IPAddress[0]
$macAddress = $adapter.MACAddress

$emailBody = @"
SCCM Task Sequence Completed

Computer Name: $computerName
IP Address   : $ipAddress
MAC Address  : $macAddress
"@

# Customize these values
$smtpServer = "smtp.example.com"
$toAddress  = "admin@example.com"
$fromAddress = "$computerName@example.com"
$subject = "Task Sequence Completed on $computerName"

Send-MailMessage -SmtpServer $smtpServer -To $toAddress -From $fromAddress -Subject $subject -Body $emailBody

