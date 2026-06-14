"=== C:\ISOs ==="; Get-ChildItem C:\ISOs -ErrorAction SilentlyContinue | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,2)}} | Format-Table -AutoSize | Out-String
"=== C:\rhl ==="; Get-ChildItem C:\rhl -ErrorAction SilentlyContinue | Select-Object Name, @{n='KB';e={[math]::Round($_.Length/1KB,1)}} | Format-Table -AutoSize | Out-String
