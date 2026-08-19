$ErrorActionPreference = 'Stop'
# 1. 验证 translation.json 合法
try {
  $json = Get-Content D:\workspace\venera\assets\translation.json -Raw | ConvertFrom-Json
  Write-Output "JSON OK, locales: $($json.PSObject.Properties.Name -join ', ')"
  Write-Output "zh_CN Smart Grip = '$($json.zh_CN.'Smart Grip')'"
  Write-Output "zh_CN subtitle    = '$($json.zh_CN.'Switch sidebar side by holding hand')'"
  Write-Output "zh_TW Smart Grip = '$($json.zh_TW.'Smart Grip')'"
  Write-Output "zh_TW subtitle    = '$($json.zh_TW.'Switch sidebar side by holding hand')'"
} catch { Write-Output "JSON ERROR: $($_.Exception.Message)"; exit 1 }
